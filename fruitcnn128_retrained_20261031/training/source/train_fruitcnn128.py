"""User-run RGB128 training; never invokes TD or programs hardware."""
import argparse
import csv
from datetime import datetime
import json
import math
from pathlib import Path
import shutil
import time

import cv2
import numpy as np
from PIL import Image, ImageOps
import torch
import torch.nn.functional as F

from fruitcnn import configure_training, cpu_state_dict
from fruitcnn128 import (ARCHITECTURE, PREPROCESS, FruitCNN128, descriptor_targets,
                         histogram_loss, image_tensor, load_model, model_budget, normalize)
from fruitcnn_training import (atomic_save, capture_rng, forward_outliers, load_manifest,
                               metrics, outlier_exposure_loss, restore_rng, white_background_masks)
from handcnn_training_utils import calibrate, infer, save_json, sha
from handfixed_math import resize_roi

ROOT = Path(__file__).resolve().parents[1]


def load_data(path):
    # Check source bytes, RGB96 audit hashes, class IDs and cross-split leakage.
    # RGB96 here is only the historical cleaning fingerprint, not model input.
    classes, rows, _, labels = load_manifest(path)
    images = []
    for row in rows:
        with Image.open(row['path']) as image:
            images.append(image_tensor(image))
    return classes, rows, torch.stack(images), labels


def hardware_images(rows):
    result = []
    for row in rows:
        with Image.open(row['path']) as image:
            roi = ImageOps.pad(ImageOps.exif_transpose(image).convert('RGB'), (480,480),
                               method=Image.Resampling.BILINEAR, color=tuple(PREPROCESS['fill']))
        pixels = resize_roi(np.asarray(roi), [0,0,480,480], 128, 128)
        result.append(torch.from_numpy(pixels.copy()).permute(2,0,1))
    return torch.stack(result)


def foreground_masks(images):
    """Return boolean masks on the input device, including CUDA inputs."""
    # OpenCV connected components returns CPU masks; align before combining.
    background = white_background_masks(images).to(device=images.device)
    fill = images.new_tensor(PREPROCESS['fill']).reshape(1,3,1,1).to(torch.int16)
    padding = (images.to(torch.int16)-fill).abs().amax(1, keepdim=True) <= 1
    return ~(background | padding)


@torch.no_grad()
def augment(images, foreground, generator):
    """Return aligned RGB and weak foreground masks for auxiliary supervision."""
    x = images.float()/255
    n = len(x)
    rand = lambda *shape: torch.rand(*shape, generator=generator, device=x.device)
    bg = .15+.7*rand(n,3,1,1)
    replace = ~foreground & (rand(n,1,1,1) < .35)
    x = torch.where(replace, bg, x)
    angle = (rand(n)*2-1)*math.radians(12)
    span = angle.cos().abs()+angle.sin().abs()
    scale = torch.maximum(1.02+.28*rand(n), span+.02)
    flip = torch.where(rand(n)<.5, -1., 1.)
    theta = torch.zeros(n,2,3,device=x.device)
    theta[:,0,0] = angle.cos()*scale*flip
    theta[:,0,1] = -angle.sin()*scale
    theta[:,1,0] = angle.sin()*scale*flip
    theta[:,1,1] = angle.cos()*scale
    margin = ((scale/span-1)*.5).clamp(0,.1)
    theta[:,:,2] = (rand(n,2)*2-1)*margin[:,None]
    grid = F.affine_grid(theta, x.shape, align_corners=False)
    fill = x.new_tensor(PREPROCESS['fill']).reshape(1,3,1,1)/255
    x = F.grid_sample(x-fill, grid, align_corners=False)+fill
    foreground = F.grid_sample(foreground.float(), grid, mode='nearest', align_corners=False) > .5
    r,g,b = x.unbind(1)
    y = .299*r+.587*g+.114*b
    u,v = -.14713*r-.28886*g+.436*b, .615*r-.51499*g-.10001*b
    hue = (rand(n,1,1)*2-1)*math.radians(8)
    ru,rv = u*hue.cos()-v*hue.sin(),u*hue.sin()+v*hue.cos()
    x = torch.stack([y+1.13983*rv,y-.39465*ru-.58060*rv,y+2.03211*ru],1)
    gray = (x*x.new_tensor([.25,.5,.25])[None,:,None,None]).sum(1,keepdim=True)
    x = gray+(x-gray)*(.65+.6*rand(n,1,1,1))
    x = torch.where(rand(n,1,1,1)<.25,gray.expand_as(x),x)
    x = ((x-.5)*(.8+.4*rand(n,1,1,1))+.5)*(.75+.5*rand(n,1,1,1))
    x *= .9+.2*rand(n,3,1,1)
    blur = F.avg_pool2d(F.pad(x,(1,1,1,1),mode='replicate'),3,1)
    x = torch.where(rand(n,1,1,1)<.08,blur,x)
    x += torch.randn(x.shape, generator=generator, device=x.device)*.004
    return (x.clamp(0,1)*255).round().to(torch.uint8),foreground


def pair_loss(logits, labels, classes):
    result = logits.float().sum()*0
    if 'apple' in classes and 'orange' in classes:
        a,b = classes.index('apple'),classes.index('orange')
        mask = (labels==a)|(labels==b)
        if mask.any():
            result = F.cross_entropy(logits[mask][:,[a,b]].float(), (labels[mask]==b).long())
    return result


def views(images, rows):
    gray = (images.float()*images.new_tensor([.25,.5,.25],dtype=torch.float32)[None,:,None,None]).sum(1,keepdim=True)
    return dict(original=images, hardware_resize=hardware_images(rows),
                grayscale=gray.round().to(torch.uint8).expand(-1,3,-1,-1).contiguous(),
                weak_light=(images.float()*.7).round().to(torch.uint8))


def evaluate(model, inputs, labels, classes, batch, temperature=1., threshold=.65):
    return {name:metrics(infer(model,x,batch),labels,classes,temperature,threshold)
            for name,x in inputs.items()}


def selection_key(results):
    core = [results['original'],results['hardware_resize']]
    macro = sum(r['macro_recall'] for r in core)/2
    worst = min(sum(r['per_class'][c]['recall'] for r in core)/2 for c in core[0]['classes'])
    focus = [r['per_class'][c]['recall'] for r in core for c in ('apple','orange') if c in r['per_class']]
    pair = sum(focus)/len(focus) if focus else macro
    score = .45*macro+.2*worst+.2*pair+.15*results['grayscale']['macro_recall']
    return score,macro,-sum(r['nll'] for r in core)/2


def solid_outliers(source, generator):
    color = torch.rand((len(source),3,1,1),generator=generator,device=source.device)*255
    return color.round().to(torch.uint8).expand_as(source).contiguous()


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest',type=Path,default=ROOT.parent/'fruits5_strawberry_clean_20261025/data_manifest.json')
    p.add_argument('--output',type=Path)
    p.add_argument('--device',choices=['cuda','cpu','auto'],default='cuda')
    p.add_argument('--threads',type=int,default=6)
    p.add_argument('--amp',action=argparse.BooleanOptionalAction,default=True)
    p.add_argument('--epochs',type=int,default=160)
    p.add_argument('--batch',type=int,default=48)
    p.add_argument('--seed',type=int,default=20261024)
    p.add_argument('--lr',type=float,default=.002)
    p.add_argument('--weight-decay',type=float,default=.002)
    p.add_argument('--shape-weight',type=float,default=.1)
    p.add_argument('--texture-weight',type=float,default=.1)
    p.add_argument('--pair-weight',type=float,default=.15)
    p.add_argument('--outlier-weight',type=float,default=.05)
    p.add_argument('--hardware-probability',type=float,default=.5)
    p.add_argument('--threshold',type=float,default=.65)
    p.add_argument('--repeats',type=int,default=2)
    p.add_argument('--patience',type=int,default=30)
    p.add_argument('--min-epochs',type=int,default=60)
    p.add_argument('--resume',type=Path)
    p.add_argument('--stop-after',type=int,help='Pause after N epochs; test remains untouched')
    p.add_argument('--check-data-only',action='store_true',help='Validate data and print model budget without training')
    args = p.parse_args(argv)
    resumed = None
    if args.resume:
        resumed = torch.load(args.resume,map_location='cpu',weights_only=True)
        if resumed.get('resume_format') != 'fruit128_training_v1':
            p.error('Use RGB128 last.pt; RGB96 checkpoints are incompatible')
        if args.output and args.output.resolve() != args.resume.resolve().parent:
            p.error('Resume output must be the original run directory')
        for key,value in resumed['config']['training'].items():
            if key not in ('device','threads','check_data_only','stop_after','resume','output'):
                setattr(args,key,Path(value) if key=='manifest' else value)
        args.output = args.resume.resolve().parent
    if min(args.epochs,args.batch,args.threads,args.repeats,args.patience) <= 0:
        p.error('epochs/batch/threads/repeats/patience must be positive')
    if args.min_epochs < 0 or (args.stop_after is not None and args.stop_after <= 0):
        p.error('Invalid min-epochs or stop-after')
    if args.lr <= 0 or args.weight_decay < 0 or not math.isfinite(args.lr+args.weight_decay):
        p.error('Invalid learning rate or weight decay')
    if any(not 0 <= v <= 2 for v in (args.shape_weight,args.texture_weight,args.pair_weight,args.outlier_weight)):
        p.error('Loss weights must be in [0,2]')
    if not 0 <= args.hardware_probability <= 1 or not 0 < args.threshold < 1:
        p.error('Invalid probability or threshold')
    if not 0 <= args.seed < 2**32:
        p.error('Seed must be in [0,2**32)')
    if not args.manifest.is_file():
        p.error('Cleaned manifest missing. Run clean_fruit_datasets.py first: '+str(args.manifest))
    device,runtime = configure_training(args.device,args.threads,args.seed)
    if device.type != 'cuda':
        args.amp = False
    cv2.setNumThreads(1)
    manifest = (args.output/'data_manifest.json') if resumed else args.manifest.resolve()
    if resumed and sha(manifest) != resumed['config']['manifest_sha256']:
        raise ValueError('Resume manifest changed')
    classes,rows,images,labels = load_data(manifest)
    if len(classes) != 5:
        print('NOTE: this class count is for PC experiments; FPGA integration requires five classes.',flush=True)
    model = FruitCNN128(classes,auxiliary=True).to(device)
    budget = model_budget(model)
    if args.check_data_only:
        print(json.dumps(dict(status='DATA_CHECK_PASSED_NO_TRAINING',samples=len(rows),classes=classes,
                              shape=list(images.shape),budget=budget),indent=2),flush=True)
        return
    out = args.output or ROOT/'build/fruit/runs'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    out = out.resolve()
    if not resumed:
        out.mkdir(parents=True,exist_ok=False)
        shutil.copy2(manifest,out/'data_manifest.json')
        csv_path = manifest.with_suffix('.csv')
        if csv_path.is_file():
            shutil.copy2(csv_path,out/'data_manifest.csv')
        config = dict(architecture=ARCHITECTURE,preprocess=PREPROCESS,classes=classes,
                      threshold=args.threshold,temperature=1.,budget=budget,
                      manifest_sha256=sha(out/'data_manifest.json'),runtime=runtime,
                      fpga_deployed=False,fpga_resource_verified=False,
                      training={k:str(v) if isinstance(v,Path) else v for k,v in vars(args).items()},
                      selection='validation only: .45 core macro + .20 worst class + .20 apple/orange + .15 grayscale macro',
                      texture_supervision='4x4-cell rotation invariant uniform LBP histograms, training only',
                      shape_supervision='4x4-cell unthresholded Scharr direction histograms, training only')
        save_json(out/'run_config.json',config)
        save_json(out/'fpga_requirements.json',budget['fpga_constraints'])
        source = out/'source'
        source.mkdir()
        for name in ('train_fruitcnn128.py','fruitcnn128.py','fruitcnn.py','fruitcnn_training.py',
                     'handcnn_model.py','handcnn_training_utils.py','handfixed_math.py',
                     'clean_fruit_datasets.py','fruit_cleaning_review.json'):
            path = Path(__file__).with_name(name)
            if path.is_file():
                shutil.copy2(path,source/name)
    else:
        config = resumed['config']
        if resumed['device_type'] != device.type:
            p.error('Resume on the same device type for reproducible RNG restoration')
        if resumed['complete'] and (out/'completion.json').is_file():
            if sha(out/'model.pt') == json.loads((out/'completion.json').read_text())['checkpoint_sha256']:
                print('ALREADY_COMPLETE '+str(out/'model.pt'),flush=True)
                return
    ids = {s:torch.tensor([i for i,r in enumerate(rows) if r['split']==s]) for s in ('train','validation','test')}
    train_rows = [rows[i] for i in ids['train'].tolist()]
    valid_rows = [rows[i] for i in ids['validation'].tolist()]
    train_x = images[ids['train']].to(device)
    train_hw = hardware_images(train_rows).to(device) if args.hardware_probability else train_x
    mask = foreground_masks(train_x).to(device)
    mask_hw = foreground_masks(train_hw).to(device)
    train_y = labels[ids['train']].to(device)
    valid_y = labels[ids['validation']]
    valid_views = views(images[ids['validation']],valid_rows)
    optimizer = torch.optim.AdamW(model.parameters(),lr=args.lr,weight_decay=args.weight_decay)
    scaler = torch.amp.GradScaler('cuda',enabled=args.amp)
    counts = torch.bincount(train_y,minlength=len(classes)).float()
    weights = len(train_y)/(len(classes)*counts)
    order = torch.Generator().manual_seed(args.seed+1)
    rng = torch.Generator(device=device).manual_seed(args.seed+2)
    first,best,stale,history,best_checkpoint,prior = 1,None,0,[],None,0.
    if resumed:
        model.load_state_dict(resumed['model'],strict=True)
        model.project_fixed_filters()
        optimizer.load_state_dict(resumed['optimizer'])
        scaler.load_state_dict(resumed['scaler'])
        restore_rng(resumed['rng'],order,rng)
        first,best,stale = resumed['epoch']+1,tuple(resumed['best_key']),resumed['stale']
        history,best_checkpoint,prior = resumed['history'],resumed['best_checkpoint'],resumed['elapsed_seconds']
        atomic_save(best_checkpoint,out/'model.pt')
    started = time.monotonic()
    print('TRAINING_CONFIG '+json.dumps(dict(output=str(out),classes=classes,budget=budget,
                                             train_samples=len(train_y),amp=args.amp)),flush=True)
    complete = bool(resumed and resumed['complete'])
    for epoch in range(first,args.epochs+1) if not complete else ():
        model.train()
        warmup = min(5,args.epochs)
        factor = epoch/warmup if epoch<=warmup else .02+.98*(1+math.cos(math.pi*(epoch-warmup)/max(1,args.epochs-warmup)))/2
        for group in optimizer.param_groups:
            group['lr'] = args.lr*factor
        total = torch.zeros(7,device=device)
        presentations = len(train_y)*args.repeats
        for indices in torch.randperm(presentations,generator=order).split(args.batch):
            indices = (indices%len(train_y)).to(device)
            hw = torch.rand((len(indices),1,1,1),generator=rng,device=device)<args.hardware_probability
            source = torch.where(hw,train_hw[indices],train_x[indices])
            foreground = torch.where(hw,mask_hw[indices],mask[indices])
            x,foreground = augment(source,foreground,rng)
            shape,texture,shape_valid,texture_valid = descriptor_targets(x,foreground)
            targets = train_y[indices]
            optimizer.zero_grad(set_to_none=True)
            with torch.autocast(device_type=device.type,dtype=torch.float16,enabled=args.amp):
                logits,shape_logits,texture_logits = model(normalize(x),auxiliary=True)
                main_loss = F.cross_entropy(logits,targets,weight=weights,label_smoothing=.02)
                pair = pair_loss(logits,targets,classes)
                shape_loss = histogram_loss(shape_logits,shape,shape_valid)
                texture_loss = histogram_loss(texture_logits,texture,texture_valid)
                outlier = logits.float().sum()*0
                if args.outlier_weight:
                    outlier = outlier_exposure_loss(forward_outliers(model,normalize(solid_outliers(source,rng))))
                loss = main_loss+args.pair_weight*pair+args.shape_weight*shape_loss+args.texture_weight*texture_loss+args.outlier_weight*outlier
            if not bool(torch.isfinite(loss)):
                raise FloatingPointError('Non-finite loss; last.pt retains the previous completed epoch')
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(),5.,error_if_nonfinite=not args.amp)
            scaler.step(optimizer)
            scaler.update()
            model.project_fixed_filters()
            total += torch.stack([loss.detach().float(),main_loss.detach().float(),pair.detach().float(),
                                  shape_loss.detach().float(),texture_loss.detach().float(),outlier.detach().float(),
                                  (logits.argmax(1)==targets).float().mean()])*len(indices)
        results = evaluate(model,valid_views,valid_y,classes,args.batch,threshold=args.threshold)
        key = selection_key(results)
        improved = best is None or key>best
        if improved:
            best,stale = key,0
            best_checkpoint = dict(**config,model=model.inference_state_dict(),best_epoch=epoch,
                                   selection_key=list(key),auxiliary_heads_removed=True)
            atomic_save(best_checkpoint,out/'model.pt')
            save_json(out/'validation_selected.json',results)
        else:
            stale += 1
        values = (total/presentations).cpu().tolist()
        entry = dict(epoch=epoch,loss=values[0],classification_loss=values[1],pair_loss=values[2],
                     shape_loss=values[3],texture_loss=values[4],outlier_loss=values[5],train_accuracy=values[6],
                     validation_accuracy=results['original']['accuracy'],
                     validation_macro_recall=results['original']['macro_recall'],
                     validation_apple_recall=results['original']['per_class'].get('apple',{}).get('recall'),
                     validation_orange_recall=results['original']['per_class'].get('orange',{}).get('recall'),
                     selection_key=list(key),best=improved,lr=optimizer.param_groups[0]['lr'],
                     elapsed_seconds=prior+time.monotonic()-started)
        history.append(entry)
        complete = epoch==args.epochs or (epoch>=args.min_epochs and stale>=args.patience)
        atomic_save(dict(resume_format='fruit128_training_v1',config=config,epoch=epoch,
                         model=cpu_state_dict(model),optimizer=optimizer.state_dict(),scaler=scaler.state_dict(),
                         rng=capture_rng(order,rng),best_key=list(best),best_checkpoint=best_checkpoint,
                         stale=stale,history=history,elapsed_seconds=entry['elapsed_seconds'],
                         device_type=device.type,complete=complete),out/'last.pt')
        save_json(out/'history.json',history)
        print(json.dumps(entry),flush=True)
        if complete:
            break
        if args.stop_after and epoch-first+1 >= args.stop_after:
            print('PAUSED '+str(out/'last.pt')+'; test not evaluated',flush=True)
            return
    # Model selection is frozen. Fit temperature only on validation NLL;
    # do not force every synthetic outlier rejection at the cost of coverage.
    model,saved = load_model(out/'model.pt',device)
    val_logits = torch.cat([infer(model,valid_views[k],args.batch) for k in ('original','hardware_resize')])
    temperature,calibration = calibrate(val_logits,valid_y.repeat(2))
    saved.update(temperature=temperature,calibration=calibration)
    atomic_save(saved,out/'model.pt')
    frozen_sha = sha(out/'model.pt')
    test_rows = [rows[i] for i in ids['test'].tolist()]
    test_y = labels[ids['test']]
    test_views = views(images[ids['test']],test_rows)
    evaluation = dict(validation=evaluate(model,valid_views,valid_y,classes,args.batch,temperature,args.threshold),
                      test=evaluate(model,test_views,test_y,classes,args.batch,temperature,args.threshold),
                      checkpoint_sha256=frozen_sha,best_epoch=saved['best_epoch'],
                      fpga_deployed=False,fpga_resource_verified=False,real_camera_accuracy_measured=False,
                      limitation='Internet product photos and synthetic views do not establish board-camera accuracy. '
                                 'LBP masks are weak foreground supervision, not semantic segmentation.')
    logits = infer(model,test_views['original'],args.batch)
    probabilities = (logits/temperature).softmax(1)
    with (out/'test_predictions.csv').open('w',newline='',encoding='utf-8-sig') as stream:
        writer = csv.writer(stream)
        writer.writerow(['path','truth','prediction','confidence','accepted',*classes])
        for row,prob in zip(test_rows,probabilities):
            writer.writerow([row['path'],row['label'],classes[int(prob.argmax())],float(prob.max()),
                             bool(prob.max()>=args.threshold),*prob.tolist()])
    if sha(out/'model.pt') != frozen_sha:
        raise AssertionError('Frozen checkpoint changed during test evaluation')
    save_json(out/'evaluation.json',evaluation)
    save_json(out/'completion.json',dict(status='complete',checkpoint_sha256=frozen_sha,
                                        fpga_resource_verified=False,fpga_deployed=False))
    print('COMPLETE '+str(out/'model.pt')+'; TD integration and <=90% slice verification remain pending',flush=True)


if __name__=='__main__':
    main()
