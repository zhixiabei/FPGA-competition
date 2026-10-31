"""Training metrics and validation calibration for hand7."""
import hashlib
import json
import math
import time
import torch
import torch.nn.functional as F
from handcnn_model import CLASSES, DISPLAY_CLASSES, display_predictions, normalize

def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


@torch.inference_mode()
def infer(model, images, batch=64):
    model.eval()
    device = next(model.parameters()).device
    return torch.cat([model(normalize(chunk.to(device))).double().cpu()
                      for chunk in images.split(batch)])


def metrics(logits, labels, temperature, threshold):
    probabilities = torch.softmax(logits.double()/temperature, dim=1)
    predictions = display_predictions(probabilities, threshold)
    truth = labels+1
    accepted = predictions != 0
    per_class = {}
    for i, name in enumerate(CLASSES):
        mask = labels == i
        per_class[name] = {
            'samples': int(mask.sum()),
            'top1_accuracy': float((logits[mask].argmax(1) == i).double().mean()),
            'correct_display_fraction': float((predictions[mask] == i+1).double().mean()),
            'rejected_fraction': float((predictions[mask] == 0).double().mean()),
        }
    return {
        'samples': len(labels),
        'top1_accuracy': float((logits.argmax(1) == labels).double().mean()),
        'macro_top1': sum(r['top1_accuracy'] for r in per_class.values())/3,
        'correct_display_fraction': float((predictions == truth).double().mean()),
        'rejected_fraction': float((~accepted).double().mean()),
        'wrong_gesture_fraction': float(((predictions != truth) & accepted).double().mean()),
        'accepted_accuracy': float((predictions[accepted] == truth[accepted]).double().mean()) if accepted.any() else None,
        'confusion_order': DISPLAY_CLASSES,
        'confusion': [[int(((truth == t) & (predictions == p)).sum()) for p in range(4)] for t in range(4)],
        'per_class': per_class,
    }, probabilities, predictions


def calibrate(logits, labels):
    candidates = torch.logspace(math.log10(.25), math.log10(8), 501).double()
    losses = [float(F.cross_entropy(logits/t, labels)) for t in candidates]
    index = min(range(len(losses)), key=losses.__getitem__)
    return float(candidates[index]), {
        'fit_data': 'validation_only', 'bounds': [.25, 8.],
        'validation_nll_before': float(F.cross_entropy(logits, labels)),
        'validation_nll_after': losses[index], 'at_search_boundary': index in (0, len(losses)-1),
    }


def benchmark(model, images):
    sample = images[:1]
    with torch.inference_mode():
        for _ in range(10):
            model(normalize(sample))
        times = []
        for _ in range(60):
            started = time.perf_counter()
            model(normalize(sample))
            times.append((time.perf_counter()-started)*1000)
    times.sort()
    return {'device': 'cpu', 'threads': torch.get_num_threads(), 'samples': len(times),
            'median_ms_normalize_and_forward': times[len(times)//2],
            'p95_ms_normalize_and_forward': times[int(len(times)*.95)-1],
            'excludes': ['image decoding', 'RGB letterbox', 'camera', 'display'],
            'is_fpga_measurement': False}


