"""Data, GPU augmentation and reproducible state for the small fruit CNNs.

No test-set measurements are used by augmentation, loss or model selection.
"""
import csv
import hashlib
import json
import math
from pathlib import Path
import random

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageOps
import torch
import torch.nn.functional as F

from handcnn_model import PREPROCESS, image_tensor
from handcnn_training_utils import infer, sha
from handfixed_math import resize_roi

FOCUS_CLASSES = ('orange', 'pear')


def load_manifest(path):
    """Reload a frozen split, checking bytes, labels and cross-split leakage."""
    manifest = json.loads(Path(path).read_text(encoding='utf-8'))
    classes, rows = manifest['classes'], manifest['samples']
    if len(classes) < 2 or len(set(classes)) != len(classes) or not rows:
        raise ValueError('Manifest must contain distinct classes and samples')
    splits = ('train', 'validation', 'test')
    seen = {s: {k: set() for k in ('source_sha256', 'input_sha256', 'group')} for s in splits}
    pixels = []
    for row in rows:
        if row['split'] not in splits or not 0 <= row['target'] < len(classes):
            raise ValueError('Invalid split or target in manifest: ' + str(row))
        if row['label'] != classes[row['target']]:
            raise ValueError('Class order changed: ' + row['path'])
        source = Path(row['path'])
        if sha(source) != row['source_sha256']:
            raise ValueError('Image bytes changed: ' + str(source))
        with Image.open(source) as image:
            tensor = image_tensor(image)
        if hashlib.sha256(tensor.numpy().tobytes()).hexdigest() != row['input_sha256']:
            raise ValueError('Preprocessing changed: ' + str(source))
        pixels.append(tensor)
        for key in seen[row['split']]:
            seen[row['split']][key].add(row[key])
    for i, a in enumerate(splits):
        for b in splits[i+1:]:
            for key in seen[a]:
                if seen[a][key] & seen[b][key]:
                    raise ValueError(f'Cross-split leakage: {a}/{b}/{key}')
    for split in splits:
        present = {r['target'] for r in rows if r['split'] == split}
        if present != set(range(len(classes))):
            raise ValueError('Every split must contain every class: ' + split)
    return classes, rows, torch.stack(pixels), torch.tensor([r['target'] for r in rows])


def hardware_input(path):
    """Synthetic 480px ROI followed by the existing integer hardware resize."""
    with Image.open(path) as image:
        roi = ImageOps.pad(ImageOps.exif_transpose(image).convert('RGB'), (480, 480),
                           method=Image.Resampling.BILINEAR, color=tuple(PREPROCESS['fill']))
    rgb = np.asarray(roi).copy()
    return rgb, resize_roi(rgb, [0, 0, 480, 480], 96, 96)


def hardware_images(rows):
    return torch.stack([torch.from_numpy(hardware_input(r['path'])[1].copy()).permute(2, 0, 1)
                        for r in rows])


def white_background_masks(images):
    """Conservatively identify edge-connected neutral white, on CPU only."""
    masks = []
    for image in images.cpu().permute(0, 2, 3, 1).numpy():
        high, low = image.max(2).astype(np.int16), image.min(2).astype(np.int16)
        white = ((low >= 205) & (high - low <= 25)).astype(np.uint8)
        _, components = cv2.connectedComponents(white, connectivity=4)
        edges = np.unique(np.concatenate([components[0], components[-1],
                                          components[:, 0], components[:, -1]]))
        mask = np.isin(components, edges[edges != 0])
        if not .08 <= mask.mean() <= .85:
            mask[:] = False
        masks.append(torch.from_numpy(mask.copy()))
    return torch.stack(masks)[:, None]


@torch.no_grad()
def augment_fruit(images, generator, masks=None, hue_degrees=12., background_probability=.5,
                  grayscale_probability=.18):
    """Shape-preserving geometry and strong camera/color augmentation on x.device.

    Inverse scales shrink rather than randomly crop the fruit, keeping its full
    contour visible.  Random grayscale and wider color changes make color alone
    unreliable. Randomness uses a checkpointed generator on the same device.
    """
    x = images.float() / 255
    n, _, height, width = x.shape
    device = x.device
    rand = lambda *shape: torch.rand(*shape, generator=generator, device=device)
    if masks is not None and background_probability:
        texture = F.interpolate(rand(n, 1, 8, 8), size=(height, width),
                                mode='bilinear', align_corners=False) * .08 - .04
        background = .15 + .7 * rand(n, 3, 1, 1)
        replace = masks & (rand(n, 1, 1, 1) < background_probability)
        x = torch.where(replace, (background + texture).clamp(0, 1), x)
    angles = (rand(n) * 2 - 1) * math.radians(15)
    scale = 1.02 + .83 * rand(n)
    flip = torch.where(rand(n) < .5, -1., 1.)
    theta = torch.zeros(n, 2, 3, device=device)
    # A rotated full square needs cos(a)+sin(abs(a)) inverse scale to fit.
    span = angles.cos().abs() + angles.sin().abs()
    scale = torch.maximum(scale, span + .02)
    theta[:, 0, 0] = angles.cos() * scale * flip
    theta[:, 0, 1] = -angles.sin() * scale
    theta[:, 1, 0] = angles.sin() * scale * flip
    theta[:, 1, 1] = angles.cos() * scale
    margin = (scale / span - 1).clamp_min(0)
    theta[:, :, 2] = (rand(n, 2) * 2 - 1) * torch.minimum(margin[:, None],
                                                        torch.full((n, 1), .18, device=device))
    fill = .1 + .8 * rand(n, 3, 1, 1)
    grid = F.affine_grid(theta, x.shape, align_corners=False)
    x = F.grid_sample(x - fill, grid, align_corners=False) + fill
    # Same small hue distribution for every class: no class-specific color rule.
    r, g, b = x.unbind(1)
    angle = (rand(n, 1, 1) * 2 - 1) * math.radians(hue_degrees)
    luminance = .299*r + .587*g + .114*b
    u, v = -.14713*r - .28886*g + .436*b, .615*r - .51499*g - .10001*b
    ru, rv = u*angle.cos() - v*angle.sin(), u*angle.sin() + v*angle.cos()
    x = torch.stack([luminance + 1.13983*rv,
                     luminance - .39465*ru - .58060*rv,
                     luminance + 2.03211*ru], 1)
    gray = (x * x.new_tensor([.299, .587, .114])[None, :, None, None]).sum(1, keepdim=True)
    x = gray + (x-gray) * (.55 + .9*rand(n, 1, 1, 1))
    x = torch.where(rand(n, 1, 1, 1) < grayscale_probability, gray.expand_as(x), x)
    x = ((x-.5) * (.7 + .6*rand(n, 1, 1, 1)) + .5) * (.6 + .8*rand(n, 1, 1, 1))
    x *= .82 + .36*rand(n, 3, 1, 1)
    blur = F.avg_pool2d(F.pad(x, (1, 1, 1, 1), mode='replicate'), 3, 1)
    x = torch.where(rand(n, 1, 1, 1) < .15, blur, x)
    x += torch.randn(x.shape, generator=generator, device=device) * .01
    augmented = (x.clamp(0, 1) * 255).round().to(torch.uint8)
    return torch.where(rand(n, 1, 1, 1) < .1, images, augmented)


@torch.no_grad()
def make_shape_destroyed_outliers(images, generator):
    """Keep fruit-like colors while removing usable object shape.

    Half of the batch is reduced to its mean color plus smooth illumination;
    the other half has its 12x12 patches shuffled.  These are outlier-exposure
    inputs, not a sixth class: the five logits are trained toward a uniform
    distribution so the existing FPGA confidence decoder emits UNKNOWN.
    """
    x = images.float() / 255
    n, channels, height, width = x.shape
    if channels != 3 or height != 96 or width != 96:
        raise ValueError('Shape-destroyed outliers require NCHW RGB96 images')
    device = x.device
    rand = lambda *shape: torch.rand(*shape, generator=generator, device=device)

    mean = x.mean((2, 3), keepdim=True)
    illumination = F.interpolate(rand(n, 1, 6, 6), size=(height, width),
                                 mode='bilinear', align_corners=False) - .5
    color_only = (mean + illumination * .16).clamp(0, 1)

    patches = x.reshape(n, 3, 8, 12, 8, 12).permute(0, 2, 4, 1, 3, 5)
    patches = patches.reshape(n, 64, 3, 12, 12)
    permutation = torch.randperm(64, generator=generator, device=device)
    shuffled = patches[:, permutation].reshape(n, 8, 8, 3, 12, 12)
    shuffled = shuffled.permute(0, 3, 1, 4, 2, 5).reshape(n, 3, 96, 96)

    outliers = torch.where(rand(n, 1, 1, 1) < .5, color_only, shuffled)
    return (outliers * 255).round().to(torch.uint8)


def outlier_exposure_loss(logits):
    """Uniform-target cross entropy, shifted so its optimum is zero."""
    if logits.ndim != 2 or logits.shape[1] < 2:
        raise ValueError('Expected N x classes outlier logits')
    return -logits.float().log_softmax(1).mean() - math.log(logits.shape[1])


def forward_outliers(model, normalized_images):
    """Backpropagate outliers without contaminating BatchNorm running stats."""
    batch_norms = [module for module in model.modules()
                   if isinstance(module, torch.nn.modules.batchnorm._BatchNorm)]
    states = [module.training for module in batch_norms]
    try:
        for module in batch_norms:
            module.eval()
        return model(normalized_images)
    finally:
        for module, training in zip(batch_norms, states):
            module.train(training)


def outlier_metrics(logits, temperature=1., threshold=.75):
    probabilities = (logits / temperature).softmax(1)
    confidence = probabilities.max(1).values
    return dict(samples=len(logits), accepted=int((confidence >= threshold).sum()),
                acceptance_rate=float((confidence >= threshold).float().mean()),
                mean_confidence=float(confidence.mean()), max_confidence=float(confidence.max()))


def safe_temperature(unconstrained, outlier_logits, threshold, maximum=8.):
    """Sharpen predictions only as far as fixed validation outliers permit."""
    if outlier_logits.ndim != 2 or outlier_logits.shape[1] < 2 or not len(outlier_logits):
        raise ValueError('Expected non-empty N x classes outlier logits')
    if not 1/outlier_logits.shape[1] < threshold < 1:
        raise ValueError('Threshold must exceed uniform class confidence')
    lower = max(float(unconstrained), .25)
    def accepted(temperature):
        return bool(((outlier_logits/temperature).softmax(1).max(1).values >= threshold).any())
    if not accepted(lower):
        return lower
    upper = max(1., lower)
    while upper < maximum and accepted(upper):
        upper = min(maximum, upper*2)
    if accepted(upper):
        raise ValueError('No safe confidence temperature within calibration bounds')
    for _ in range(60):
        middle = (lower+upper)/2
        if accepted(middle):
            lower = middle
        else:
            upper = middle
    return upper


def validation_outliers(images):
    """Fixed color-only, shape-destroyed and blank probes for model selection."""
    generator = torch.Generator(device=images.device).manual_seed(2026102403)
    destroyed = make_shape_destroyed_outliers(images, generator)
    colors = torch.tensor([
        [0, 0, 0], [255, 255, 255], [128, 128, 128], [255, 220, 0],
        [90, 20, 110], [230, 90, 20], [80, 180, 70], [120, 90, 60],
    ], dtype=torch.uint8, device=images.device)
    solids = colors[:, :, None, None].expand(-1, -1, 96, 96).clone()
    return torch.cat([destroyed, solids])


def fruit_loss(logits, targets, classes, class_weights=None, pair_weight=.25, smoothing=.03):
    """Five-way CE plus orange-vs-pear CE; no additional inference head."""
    main = F.cross_entropy(logits, targets, weight=class_weights, label_smoothing=smoothing)
    pair = logits.float().sum() * 0
    if pair_weight:
        orange, pear = (classes.index(c) for c in FOCUS_CLASSES)
        mask = (targets == orange) | (targets == pear)
        if mask.any():
            pair = F.cross_entropy(logits[mask][:, [orange, pear]].float(),
                                   (targets[mask] == pear).long())
    return main + pair_weight * pair, main, pair


def metrics(logits, labels, classes, temperature=1., threshold=.65):
    probs = (logits / temperature).softmax(1)
    pred = probs.argmax(1)
    accepted = probs.max(1).values >= threshold
    confusion = torch.bincount(labels*len(classes)+pred, minlength=len(classes)**2).reshape(len(classes), -1)
    recalls = confusion.diag() / confusion.sum(1).clamp_min(1)
    return dict(samples=len(labels), correct=int((pred == labels).sum()),
                accuracy=float((pred == labels).double().mean()), macro_recall=float(recalls.mean()),
                nll=float(F.cross_entropy(logits / temperature, labels)), classes=classes,
                confusion=confusion.tolist(),
                per_class={c: dict(samples=int(confusion[i].sum()), correct=int(confusion[i, i]),
                                   recall=float(recalls[i])) for i, c in enumerate(classes)},
                rejected=int((~accepted).sum()), accepted_wrong=int((accepted & (pred != labels)).sum()),
                accepted_correct=int((accepted & (pred == labels)).sum()),
                accepted_accuracy=float((pred[accepted] == labels[accepted]).double().mean()) if accepted.any() else None)


def validation_views(images, rows):
    views = {'original': images, 'hardware_resize': hardware_images(rows)}
    small = F.interpolate(images.float(), size=(58, 58), mode='bilinear', align_corners=False).round().to(torch.uint8)
    for name, fill in [('gray', (128, 128, 128)), ('white', (255, 255, 255))]:
        canvas = torch.tensor(fill, dtype=torch.uint8)[None, :, None, None].expand_as(images).clone()
        canvas[:, :, 19:77, 19:77] = small
        views[name + '_surround_60pct'] = canvas
    for name, gain in [('warm_dim', [1., .85, .7]), ('cool_dim', [.7, .85, 1.])]:
        views[name] = (images.float() * torch.tensor(gain)[None, :, None, None]).round().to(torch.uint8)
    return views


def measure(model, views, labels, classes, batch=64, temperature=1., threshold=.65):
    return {name: metrics(infer(model, x, batch), labels, classes, temperature, threshold)
            for name, x in views.items()}


def selection_key(results, baseline=None, max_class_drop=1, outliers=None):
    """Protect the baseline and prefer models without a collapsed fruit class."""
    eligible = True
    if baseline is not None:
        protected = results['original']['classes']
        for view in ('original', 'hardware_resize'):
            for c in protected:
                if results[view]['per_class'][c]['correct'] < baseline[view]['per_class'][c]['correct'] - max_class_drop:
                    eligible = False
            if results[view]['correct'] < baseline[view]['correct'] - 2:
                eligible = False
    macro = sum(r['macro_recall'] for r in results.values()) / len(results)
    core_views = [results[name] for name in ('original', 'hardware_resize') if name in results]
    classes = results['original']['classes']
    class_means = [sum(r['per_class'][c]['recall'] for r in core_views) / len(core_views)
                   for c in classes] if core_views else []
    worst_class = min(class_means) if class_means else macro
    focus = [r['per_class'][c]['recall'] for r in results.values() for c in FOCUS_CLASSES
             if c in r['per_class']]
    focus_mean = sum(focus) / len(focus) if focus else macro
    score = .55*macro + .25*worst_class + .20*focus_mean
    if outliers is not None:
        # Penalize confident decisions on inputs that retain color but have no
        # coherent fruit shape. Accuracy remains the dominant term.
        score -= .12*outliers['mean_confidence'] + .08*outliers['acceptance_rate']
    nll = sum(r['nll'] for r in results.values()) / len(results)
    return int(eligible), score, macro, -nll


def capture_rng(order_generator, augment_generator):
    np_state = np.random.get_state()
    return dict(torch=torch.get_rng_state(), cuda=torch.cuda.get_rng_state_all() if torch.cuda.is_available() else [],
                python=random.getstate(), numpy=[np_state[0], np_state[1].tolist(), *np_state[2:]],
                order=order_generator.get_state(), augmentation=augment_generator.get_state())


def restore_rng(state, order_generator, augment_generator):
    torch.set_rng_state(state['torch'])
    if state['cuda'] and torch.cuda.is_available():
        torch.cuda.set_rng_state_all(state['cuda'])
    random.setstate(state['python'])
    np_state = state['numpy']
    np.random.set_state((np_state[0], np.array(np_state[1], dtype=np.uint32), *np_state[2:]))
    order_generator.set_state(state['order'])
    augment_generator.set_state(state['augmentation'])


def atomic_save(value, path):
    path = Path(path)
    temporary = path.with_name(path.name + '.tmp')
    torch.save(value, temporary)
    temporary.replace(path)


def save_predictions(output, rows, pixels, labels, logits, classes, temperature, threshold):
    probs = (logits / temperature).softmax(1)
    predictions = probs.argmax(1)
    with (output / 'test_predictions.csv').open('w', newline='', encoding='utf-8') as stream:
        writer = csv.writer(stream)
        writer.writerow(['path', 'truth', 'prediction', 'confidence', 'accepted', *classes])
        for row, prob in zip(rows, probs):
            writer.writerow([row['path'], row['label'], classes[int(prob.argmax())], float(prob.max()),
                             bool(prob.max() >= threshold), *prob.tolist()])
    # Prioritize orange/pear mistakes, then other mistakes; at most 30 tiles.
    errors = torch.where(predictions != labels)[0].tolist()
    errors.sort(key=lambda i: (classes[int(labels[i])] not in FOCUS_CLASSES, i))
    sheet = Image.new('RGB', (6*176, max(1, math.ceil(min(len(errors), 30)/6))*152), '#222222')
    draw = ImageDraw.Draw(sheet)
    if not errors:
        draw.text((12, 12), 'No top-1 errors on this test split.', fill='white')
    for j, i in enumerate(errors[:30]):
        x, y = (j % 6)*176, (j // 6)*152
        sheet.paste(Image.fromarray(pixels[i].permute(1, 2, 0).numpy()).resize((120, 120)), (x, y+30))
        draw.text((x+2, y+3), classes[int(labels[i])] + ' > ' + classes[int(predictions[i])], fill='white')
        draw.text((x+2, y+16), f'{float(probs[i].max()):.1%}', fill='white')
    sheet.save(output / 'test_errors.jpg')
