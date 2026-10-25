"""Fixed camera ROI, bit-exact bilinear input and frozen W8A16 decision."""
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import torch
from handfixed_math import integer_run, normalize, snapshot, resize_roi

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODEL = ROOT/'build/gesture/weights/model.json'
CLASSES = ['PEACE', 'PUNCH', 'STOP']


def load_config(path=DEFAULT_MODEL):
    config = json.loads(Path(path).read_text(encoding='utf-8'))
    if config['format'] != 'HFIXCNN1': raise ValueError('Expected fixed-region model')
    if config.get('texture_gate') != dict(channel='green', minimum_range=16, edge_delta=12, minimum_horizontal_edges=24):
        raise ValueError('Texture gate must match the fixed FPGA implementation')
    if hashlib.sha256(Path(path).with_suffix('.bin').read_bytes()).hexdigest() != config['model_sha256']:
        raise ValueError('Model hash mismatch')
    x, y, side = config['roi']
    if not (0 <= x < x+side <= 1280 and 0 <= y < y+side <= 720):
        raise ValueError('Fixed ROI outside camera raster')
    return config


def decision(q, config):
    q = q.flatten().to(torch.int64)
    winner = int(q.argmax())
    total = sum(math.ceil(2**20*math.exp(-min(int(d) >> 5, 511)*32*2.**config['operations'][-1]['dst_exp']/config['temperature']))
                for i, d in enumerate(q.max()-q) if i != winner)
    probabilities = (q.double()*2.**config['operations'][-1]['dst_exp']/config['temperature']).softmax(0).tolist()
    return dict(label=CLASSES[winner] if total <= 564617 else 'NOTHING',
                class_id=winner+2 if total <= 564617 else 1, logits=q.tolist(),
                probabilities=probabilities, confidence=max(probabilities), exp_sum=total)


def patch(rgb, config):
    x, y, side = config['roi']
    return resize_roi(rgb, [x, y, x+side, y+side], 96, 96)


def texture_gate(crop):
    green = crop[:, :, 1].astype(np.int16)
    edges = int((np.abs(np.diff(green, axis=1)) >= 12).sum())
    span = int(green.max()-green.min())
    return dict(has_texture=span >= 16 and edges >= 24, texture_edges=edges, texture_range=span)


@torch.inference_mode()
def infer(rgb, config):
    """Input must be the unmirrored 1280x720 RGB snapshot."""
    if rgb.shape != (720, 1280, 3): raise ValueError('Expected 1280x720 RGB')
    crop = patch(rgb, config)
    result = decision(integer_run(config['operations'], normalize(crop, True)), config)
    result.update(texture_gate(crop))
    if not result['has_texture']:
        result.update(label='NOTHING', class_id=1, reason='flat_region')
    return result


def placed_crop(crop, config):
    """Synthetic placement for implementation checks, not camera accuracy."""
    x, y, side = config['roi']
    rgb = np.full((720, 1280, 3), [124, 116, 104], dtype=np.uint8)
    h, w = crop.shape[:2]
    rgb[y:y+side, x:x+side] = resize_roi(crop, [0, 0, w, h], side, side)
    return rgb
