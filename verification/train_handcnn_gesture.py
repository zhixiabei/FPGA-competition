"""Train a moderately larger gesture CNN on verified hand crops, without a teacher.

Only train/validation are decoded for model selection. Test inference belongs
to separate held-out evaluation after weights and decision rules are frozen.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import time

import numpy as np
from PIL import ImageDraw
import torch.nn.functional as F

from handcnn_model import (
    ROOT, CAPACITY_ARCHITECTURE, CAPACITY_VARIANTS, CLASSES, DISPLAY_CLASSES,
    PREPROCESS, CapacityGestureCNN, Image, complexity, image_tensor,
    load_model, normalize, torch,
)
from handcnn_training_utils import benchmark, calibrate, infer, metrics, save_json, sha


def augment(images, generator):
    """Training-only jitter of pose, framing, illumination and camera sharpness."""
    x = images.float()/255
    n = len(x)
    rand = lambda *shape: torch.rand(*shape, generator=generator)
    angles = (rand(n)*2-1)*math.radians(25)
    scale = .90+.20*rand(n)
    flip = torch.where(rand(n)<.5, -1., 1.)
    theta = torch.zeros(n, 2, 3)
    theta[:, 0, 0] = torch.cos(angles)*scale*flip
    theta[:, 0, 1] = -torch.sin(angles)*scale
    theta[:, 1, 0] = torch.sin(angles)*scale*flip
    theta[:, 1, 1] = torch.cos(angles)*scale
    theta[:, :, 2] = (rand(n, 2)*2-1)*.04
    fill = torch.tensor(PREPROCESS['fill']).reshape(1, 3, 1, 1)/255
    x = F.grid_sample(x-fill, F.affine_grid(theta, x.shape, align_corners=False),
                      align_corners=False, padding_mode='zeros')+fill
    gray = (x*torch.tensor([.299, .587, .114]).reshape(1, 3, 1, 1)).sum(1, keepdim=True)
    saturation = .55+.90*rand(n, 1, 1, 1)
    saturation[rand(n, 1, 1, 1)<.12] = 0
    x = gray+(x-gray)*saturation
    x = (x-.5)*(.7+.6*rand(n, 1, 1, 1))+.5
    x = x*(.70+.60*rand(n, 1, 1, 1))*(.88+.24*rand(n, 3, 1, 1))
    blurred = F.avg_pool2d(F.pad(x, (1, 1, 1, 1), mode='replicate'), 3, stride=1)
    x = torch.where(rand(n, 1, 1, 1)<.12, blurred, x)
    x += torch.randn(x.shape, generator=generator)*.006
    return (x.clamp(0, 1)*255).round().to(torch.uint8)


def prepare(manifest_path, output):
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    audit_path = manifest_path.parent/'audit.json'
    audit = json.loads(audit_path.read_text(encoding='utf-8'))
    if manifest['classes'] != CLASSES or manifest['probe_only'] or not audit['passed']:
        raise ValueError('Expected a complete audited three-class hand-crop dataset')
    for row in manifest['samples']:
        if sha(Path(row['path'])) != row['sha256'] or sha(Path(row['source_path'])) != row['source_sha256']:
            raise ValueError('Source/crop hash changed: '+row['path'])
    parts, tensors = {}, {}
    # No test image tensor is created during selection.
    for split in ['train', 'validation']:
        rows = [r for r in manifest['samples'] if r['split'] == split]
        images = []
        for row in rows:
            with Image.open(row['path']) as image:
                pixels = image_tensor(image)
            assert hashlib.sha256(pixels.numpy().tobytes()).hexdigest() == row['input_sha256']
            images.append(pixels)
        parts[split] = rows
        tensors[split] = (torch.stack(images), torch.tensor([r['target'] for r in rows]))
    copied = copy.deepcopy(manifest)
    copied.update(parent_manifest=str(manifest_path.resolve()), parent_manifest_sha256=sha(manifest_path),
                  preprocess=PREPROCESS, training_input='hand_crop', nothing_is_trained=False)
    save_json(output/'data_manifest.json', copied)
    return manifest, parts, tensors


def augmentation_preview(images, labels, output, seed):
    ids = [int(torch.where(labels == c)[0][0]) for c in range(3)]
    originals = images[ids]
    augmented = augment(originals.repeat_interleave(5, dim=0), torch.Generator().manual_seed(seed+1000))
    sheet = Image.new('RGB', (6*96, 3*120), '#20242c')
    draw = ImageDraw.Draw(sheet)
    for c in range(3):
        draw.text((3, c*120+4), CLASSES[c]+' | original + training augmentations', fill='white')
        for j in range(6):
            pixels = originals[c] if j == 0 else augmented[c*5+j-1]
            sheet.paste(Image.fromarray(pixels.permute(1, 2, 0).numpy()), (j*96, c*120+24))
    sheet.save(output/'training_augmentations.jpg', quality=94)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=ROOT/'build/gesture/data/data_manifest.json')
    parser.add_argument('--output', type=Path, default=ROOT/'build/gesture/new_training')
    parser.add_argument('--variant', choices=['hand7'], default='hand7')
    parser.add_argument('--epochs', type=int, default=220)
    parser.add_argument('--batch', type=int, default=48)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--seed', type=int, default=20261022)
    parser.add_argument('--lr', type=float, default=.002)
    args = parser.parse_args()
    if min(args.epochs, args.batch, args.threads) < 1 or args.lr <= 0:
        parser.error('Counts and learning rate must be positive')
    args.output.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    torch.use_deterministic_algorithms(True)
    started = time.monotonic()
    manifest, parts, tensors = prepare(args.manifest, args.output)
    train_x, train_y = tensors['train']
    valid_x, valid_y = tensors['validation']
    generator = torch.Generator().manual_seed(args.seed+1)
    augmentation_preview(train_x, train_y, args.output, args.seed)
    model = CapacityGestureCNN(args.variant, pool_size=2)
    crop_config = dict(parameters=manifest['preprocessing'],
                       assets=manifest['model_provenance'],
                       provenance_manifest_sha256=sha(args.manifest))
    config = dict(architecture=CAPACITY_ARCHITECTURE, variant=args.variant, pool_size=2,
                  capacity_spec=CAPACITY_VARIANTS[args.variant], classes=CLASSES,
                  display_classes=DISPLAY_CLASSES, preprocess=PREPROCESS,
                  input_mode='localized_hand_crop', hand_crop=crop_config,
                  comparison='greater_equal', threshold=.65, temperature=1.,
                  nothing_is_trained=False, teacher={'used': False}, complexity=complexity(model),
                  manifest_sha256=sha(args.output/'data_manifest.json'),
                  selection='validation_macro_top1_then_nll; no_test_inference',
                  training={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                  optimizer='AdamW', weight_decay=.001, label_smoothing=.03,
                  augmentation='online_affine25deg_flip_brightness_contrast_saturation_grayscale_blur_noise_v1',
                  class_weight_policy='inverse_train_frequency_normalized',
                  script_sha256=sha(Path(__file__)),
                  model_source_sha256=sha(Path(__file__).with_name('handcnn_model.py')),
                  torch_version=str(torch.__version__), device='cpu', fpga_deployed=False)
    save_json(args.output/'run_config.json', config)
    print('CONFIG '+json.dumps({'complexity': config['complexity'],
          'train': len(train_y), 'validation': len(valid_y), 'teacher': False}), flush=True)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=.001)
    weight = len(train_y)/(3*torch.bincount(train_y, minlength=3).float())
    best, stale, history = (-1., -float('inf')), 0, []
    with (args.output/'training.log').open('w', encoding='utf-8', buffering=1) as log:
        for epoch in range(1, args.epochs+1):
            # Five warmup epochs followed by a cosine decay.
            factor = min(epoch/5, 1.) if epoch <= 5 else .02+.98*(1+math.cos(math.pi*(epoch-5)/max(1, args.epochs-5)))/2
            for group in optimizer.param_groups:
                group['lr'] = args.lr*factor
            model.train()
            total, correct = 0., 0
            order = torch.randperm(len(train_y), generator=generator)
            for ids in order.split(args.batch):
                x, target = augment(train_x[ids], generator), train_y[ids]
                optimizer.zero_grad(set_to_none=True)
                logits = model(normalize(x))
                loss = F.cross_entropy(logits, target, weight=weight, label_smoothing=.03)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 5.)
                optimizer.step()
                total += float(loss.detach())*len(ids)
                correct += int((logits.argmax(1) == target).sum())
            logits = infer(model, valid_x, args.batch)
            result = metrics(logits, valid_y, 1., .65)[0]
            nll = float(F.cross_entropy(logits, valid_y))
            key = (result['macro_top1'], -nll)
            improved = key > best
            if improved:
                best, stale = key, 0
                torch.save({**config, 'best_epoch': epoch,
                            'model': {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}},
                           args.output/'model.pt')
            else:
                stale += 1
            row = dict(epoch=epoch, loss=total/len(train_y), augmented_train_accuracy=correct/len(train_y),
                       validation_top1=result['top1_accuracy'], validation_macro_top1=result['macro_top1'],
                       validation_nll=nll, best=improved, elapsed_seconds=time.monotonic()-started)
            history.append(row)
            log.write(json.dumps(row)+'\n')
            save_json(args.output/'history.json', history)
            if improved or epoch % 10 == 0:
                print(json.dumps(row), flush=True)
            if epoch >= 100 and stale >= 55:
                print('EARLY_STOP validation plateau', flush=True)
                break
    model, saved = load_model(args.output/'model.pt')
    logits = infer(model, valid_x, args.batch)
    temperature, calibration = calibrate(logits, valid_y)
    saved.update(temperature=temperature, calibration=calibration)
    torch.save(saved, args.output/'model.pt')
    selection = dict(best_epoch=saved['best_epoch'], epochs_completed=len(history),
                     validation=metrics(logits, valid_y, temperature, .65)[0],
                     train=metrics(infer(model, train_x, args.batch), train_y, temperature, .65)[0],
                     temperature=temperature, complexity=config['complexity'],
                     cpu_benchmark=benchmark(model, valid_x),
                     test_inference_performed=False, nothing_data_used=False,
                     checkpoint_sha256=sha(args.output/'model.pt'), elapsed_seconds=time.monotonic()-started)
    save_json(args.output/'selection.json', selection)
    print('SELECTION_COMPLETE '+json.dumps(selection), flush=True)


if __name__ == '__main__':
    main()
