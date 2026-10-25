"""Synthetic checks only: cleaning, feature learning, resume and inference export."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np
from PIL import Image
import torch

from clean_fruit_datasets import clean, describe, duplicate_groups, rgb_image
from fruitcnn128 import (ARCHITECTURE, CLASSES, PREPROCESS, FruitCNN128, descriptor_targets,
                         histogram_loss, image_tensor, load_model, model_budget, normalize)
from fruitcnn_training import load_manifest
from handcnn_model import image_tensor as audit_tensor
from handcnn_training_utils import sha
from train_fruitcnn128 import augment, foreground_masks, main, pair_loss

ROOT = Path(__file__).resolve().parents[1]


class Checks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(2)
        (ROOT/'build').mkdir(exist_ok=True)

    def setUp(self):
        torch.manual_seed(17)

    def temporary(self):
        temporary = tempfile.TemporaryDirectory(dir=ROOT/'build',prefix='fruit128_check_')
        # Verify the exact recursive-cleanup target is inside the workspace.
        self.assertTrue(Path(temporary.name).resolve().is_relative_to((ROOT/'build').resolve()))
        self.addCleanup(temporary.cleanup)
        return Path(temporary.name)

    def synthetic_manifest(self, folder):
        rows = []
        rng = np.random.default_rng(7)
        for label in CLASSES:
            for i,split in enumerate(('train','validation','test')):
                path = folder/f'{label}_{i}.png'
                Image.fromarray(rng.integers(0,256,(40,48,3),dtype=np.uint8)).save(path)
                with Image.open(path) as im:
                    fingerprint = hashlib.sha256(audit_tensor(im).numpy().tobytes()).hexdigest()
                rows.append(dict(path=str(path),label=label,target=CLASSES.index(label),split=split,
                                 group=f'{label}_{i}',source_sha256=sha(path),input_sha256=fingerprint))
        manifest = folder/'data_manifest.json'
        manifest.write_text(json.dumps(dict(root=str(folder),classes=CLASSES,samples=rows)))
        return manifest

    def test_fixed_filters_and_shared_export(self):
        model = FruitCNN128(auxiliary=True).train()
        x = torch.randint(0,256,(5,3,128,128),dtype=torch.uint8)
        original = model.features[0].weight[:6].detach().clone()
        learned = model.features[0].weight[6:].detach().clone()
        optimizer = torch.optim.AdamW(model.parameters(),lr=.01,weight_decay=.1)
        shape,texture,sv,tv = descriptor_targets(x,torch.ones(5,1,128,128,dtype=torch.bool))
        logits,sp,tp = model(normalize(x),auxiliary=True)
        loss = (torch.nn.functional.cross_entropy(logits,torch.arange(5))+
                .1*histogram_loss(sp,shape,sv)+.1*histogram_loss(tp,texture,tv)+
                .15*pair_loss(logits,torch.arange(5),CLASSES))
        loss.backward()
        self.assertEqual(float(model.features[0].weight.grad[:6].abs().sum()),0)
        self.assertGreater(float(model.shape_head.weight.grad.abs().sum()),0)
        self.assertGreater(float(model.texture_head.weight.grad.abs().sum()),0)
        optimizer.step()
        model.project_fixed_filters()
        self.assertTrue(torch.equal(original,model.features[0].weight[:6]))
        self.assertFalse(torch.equal(learned,model.features[0].weight[6:]))
        model.eval()
        out = self.temporary()/'model.pt'
        torch.save(dict(architecture=ARCHITECTURE,preprocess=PREPROCESS,classes=CLASSES,
                        model=model.inference_state_dict(),temperature=1.,threshold=.65),out)
        reloaded,_ = load_model(out)
        with torch.no_grad():
            self.assertTrue(torch.equal(model(normalize(x)),reloaded(normalize(x))))
        self.assertFalse(hasattr(reloaded,'texture_head'))
        with self.assertRaises(ValueError):
            reloaded(torch.zeros(1,3,96,96))
        budget = model_budget(model)
        self.assertEqual(budget['fpga_constraints']['max_slices'],19094)
        self.assertEqual([r['layer'] for r in budget['layers'] if r['needs_input_tiling']],[1,2,3])
        self.assertLessEqual(max(r['output_bytes'] for r in budget['layers']),131072)

    def test_edge_and_texture_are_not_color_histograms(self):
        uniform = torch.full((1,3,128,128),128,dtype=torch.uint8)
        textured = uniform.clone()
        yy,xx = torch.meshgrid(torch.arange(128),torch.arange(128),indexing='ij')
        textured[:] = torch.where((xx+yy)%2==0,64,192).to(torch.uint8)
        self.assertEqual(float(uniform.float().mean()),float(textured.float().mean()))
        fg = torch.ones(1,1,128,128,dtype=torch.bool)
        _,plain,_,_ = descriptor_targets(uniform,fg)
        _,detail,_,_ = descriptor_targets(textured,fg)
        self.assertGreater(float((plain-detail).abs().sum()),1)
        step = uniform.clone()
        step[:,:,:,64:] = 255
        model = FruitCNN128().eval()
        filters = model.features[0]
        with torch.no_grad():
            a = filters(normalize(uniform))[:,0:4,:,2:-2]
            b = filters(normalize(step))[:,0:4,:,2:-2]
        self.assertGreater(float((b-a).abs().sum()),1)

    @unittest.skipUnless(torch.cuda.is_available(),'CUDA unavailable')
    def test_cuda_amp_one_synthetic_step(self):
        model = FruitCNN128(auxiliary=True).cuda().train()
        optimizer = torch.optim.AdamW(model.parameters(),lr=.001)
        scaler = torch.amp.GradScaler('cuda')
        pixels = torch.randint(0,256,(5,3,128,128),dtype=torch.uint8,device='cuda')
        pixels,fg = augment(pixels,foreground_masks(pixels),
                            torch.Generator(device='cuda').manual_seed(4))
        shape,texture,sv,tv = descriptor_targets(pixels,fg)
        with torch.autocast('cuda',dtype=torch.float16):
            logits,sp,tp = model(normalize(pixels),auxiliary=True)
            loss = (torch.nn.functional.cross_entropy(logits,torch.arange(5,device='cuda'))+
                    .1*histogram_loss(sp,shape,sv)+.1*histogram_loss(tp,texture,tv))
        self.assertTrue(bool(torch.isfinite(loss)))
        scaler.scale(loss).backward()
        scaler.step(optimizer)
        scaler.update()
        model.project_fixed_filters()
        self.assertTrue(torch.equal(model.features[0].weight[:6],model._fixed_filters))

    def test_foreground_masks_device_and_pixels(self):
        # Cover both CPU connected components and tensor-based padding removal.
        images = torch.full((3,3,128,128),32,dtype=torch.uint8)
        images[0] = 255
        images[1] = images.new_tensor(PREPROCESS['fill'])[:,None,None]
        images[:2,:,24:104,24:104] = images.new_tensor([200,40,20])[None,:,None,None]
        expected = torch.ones(3,1,128,128,dtype=torch.bool)
        expected[:2] = False
        expected[:2,:,24:104,24:104] = True
        devices = ['cpu','cuda'] if torch.cuda.is_available() else ['cpu']
        for device in devices:
            with self.subTest(device=device):
                pixels = images.to(device)
                masks = foreground_masks(pixels)
                self.assertEqual(masks.device,pixels.device)
                self.assertEqual(masks.dtype,torch.bool)
                self.assertTrue(torch.equal(masks.cpu(),expected))

    @unittest.skipUnless(torch.cuda.is_available(),'CUDA unavailable')
    def test_cuda_training_entrypoint_synthetic(self):
        folder = self.temporary()
        manifest = self.synthetic_manifest(folder)
        out = folder/'cuda_run'
        with contextlib.redirect_stdout(io.StringIO()):
            main(['--manifest',str(manifest),'--output',str(out),'--device','cuda','--amp',
                  '--threads','2','--epochs','2','--batch','5','--repeats','1',
                  '--min-epochs','2','--stop-after','1'])
        checkpoint = torch.load(out/'last.pt',map_location='cpu',weights_only=True)
        self.assertEqual(checkpoint['device_type'],'cuda')
        self.assertTrue(checkpoint['config']['training']['amp'])
        self.assertEqual(checkpoint['epoch'],1)
        self.assertFalse(checkpoint['complete'])
        self.assertTrue(np.isfinite(checkpoint['history'][0]['loss']))
        self.assertFalse((out/'evaluation.json').exists())
        self.assertFalse((out/'completion.json').exists())

    def test_augmentation_mask_and_histogram_validity(self):
        x = torch.randint(0,256,(3,3,128,128),dtype=torch.uint8)
        fg = foreground_masks(x)
        augmented,mask = augment(x,fg,torch.Generator().manual_seed(1))
        self.assertEqual(augmented.shape,x.shape)
        self.assertEqual(mask.dtype,torch.bool)
        shape,texture,sv,tv = descriptor_targets(augmented,mask)
        self.assertTrue(torch.allclose(shape.sum(-1)[sv],torch.ones_like(shape.sum(-1)[sv])))
        self.assertTrue(torch.allclose(texture.sum(-1)[tv],torch.ones_like(texture.sum(-1)[tv])))
        _,_,sv,tv = descriptor_targets(x,torch.zeros_like(mask))
        self.assertFalse(bool(sv.any() or tv.any()))

    def test_cleaning_global_duplicates_quality_and_rgb(self):
        folder = self.temporary()
        sources = {s:folder/s for s in ('old','recognition')}
        rng = np.random.default_rng(81)
        for label in CLASSES:
            path = sources['old']/label
            path.mkdir(parents=True)
            for i in range(20):
                Image.fromarray(rng.integers(0,256,(48,48,3),dtype=np.uint8)).save(path/f'{i}.png')
        path = sources['recognition']/'Apple'
        path.mkdir(parents=True)
        for i in range(20):
            (path/f'{i}.png').write_bytes((sources['old']/'apple'/f'{i}.png').read_bytes())
        Image.new('RGB',(48,48),'white').save(sources['old']/'apple/blank.png')
        (sources['old']/'pear/broken.jpg').write_bytes(b'broken')
        (sources['old']/'pear/conflict.png').write_bytes((sources['old']/'grape/0.png').read_bytes())
        (sources['old']/'grape/review_duplicate.png').write_bytes((sources['old']/'grape/1.png').read_bytes())
        review = {'exclude':{'old:grape/1.png':'synthetic semantic exclusion'}}
        with contextlib.redirect_stdout(io.StringIO()):
            report = clean(sources,folder/'clean',review=review)
        self.assertEqual(len(report['invalid']),1)
        all_rows = report['samples']
        self.assertTrue(next(r for r in all_rows if r['key']=='old:apple/blank.png')['exclusion_reasons'])
        self.assertTrue(next(r for r in all_rows if r['key']=='old:pear/conflict.png')['exclusion_reasons'])
        self.assertTrue(next(r for r in all_rows if r['key']=='old:grape/review_duplicate.png')['exclusion_reasons'])
        classes,rows,pixels,_ = load_manifest(folder/'clean/combined/data_manifest.json')
        self.assertEqual(classes,CLASSES)
        self.assertEqual(pixels.shape[-2:],(96,96))
        split_by_group = {r['group']:r['split'] for r in rows}
        for dataset in sources:
            for row in json.loads((folder/f'clean/{dataset}/data_manifest.json').read_text())['samples']:
                self.assertEqual(split_by_group[row['group']],row['split'])
        Image.new('CMYK',(60,60),(10,20,30,40)).save(folder/'cmyk.jpg')
        self.assertEqual(rgb_image(folder/'cmyk.jpg').mode,'RGB')

    def test_resume_two_synthetic_steps_matches_uninterrupted(self):
        folder = self.temporary()
        manifest = self.synthetic_manifest(folder)
        options = ['--manifest',str(manifest),'--device','cpu','--threads','2','--epochs','2',
                   '--batch','5','--repeats','1','--min-epochs','2','--hardware-probability','0']
        with contextlib.redirect_stdout(io.StringIO()):
            main([*options,'--output',str(folder/'whole')])
            main([*options,'--output',str(folder/'resumed'),'--stop-after','1'])
            self.assertFalse((folder/'resumed/evaluation.json').exists())
            main(['--resume',str(folder/'resumed/last.pt'),'--device','cpu','--threads','2'])
        a = torch.load(folder/'whole/last.pt',weights_only=True)
        b = torch.load(folder/'resumed/last.pt',weights_only=True)
        for key in a['model']:
            self.assertTrue(torch.equal(a['model'][key],b['model'][key]),key)
        self.assertEqual(a['best_key'],b['best_key'])
        self.assertTrue((folder/'resumed/evaluation.json').is_file())
        self.assertFalse(json.loads((folder/'resumed/completion.json').read_text())['fpga_deployed'])


if __name__=='__main__':
    unittest.main(verbosity=2)
