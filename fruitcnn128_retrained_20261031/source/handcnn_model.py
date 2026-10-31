"""Seven-convolution hand7 classifier, 156675 parameters, RGB96."""
from pathlib import Path
import numpy as np
from PIL import Image, ImageOps
import torch
from torch import nn
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CHECKPOINT = ROOT/'build/gesture/training/model.pt'
# This identifier is embedded in the existing checkpoint and is kept for compatibility.
CAPACITY_ARCHITECTURE = 'lightcnn_rgb96_capacity_v1'
CAPACITY_VARIANTS = {'hand7': {'channels':[16,24,48,64,96], 'repeats':[1,1,2,2,1], 'strides':[2,2,2,2,1]}}
CLASSES = ['PEACE', 'PUNCH', 'STOP']
DISPLAY_CLASSES = ['NOTHING', *CLASSES]
SIZE = 96
DEFAULT_THRESHOLD = .65
PREPROCESS = {
    'size': SIZE, 'color': 'RGB', 'resize': 'bilinear_letterbox_full_image',
    'fill': [124, 116, 104], 'mean': [.485, .456, .406],
    'std': [.229, .224, .225],
}
MEAN = torch.tensor(PREPROCESS['mean']).reshape(1, 3, 1, 1)
STD = torch.tensor(PREPROCESS['std']).reshape(1, 3, 1, 1)


def image_tensor(image):
    image = ImageOps.exif_transpose(image).convert('RGB')
    image = ImageOps.pad(image, (SIZE, SIZE), method=Image.Resampling.BILINEAR,
                         color=tuple(PREPROCESS['fill']))
    return torch.from_numpy(np.array(image, dtype=np.uint8, copy=True)).permute(2, 0, 1)


def normalize(images):
    return (images.float() / 255 - MEAN.to(images.device)) / STD.to(images.device)


class CapacityGestureCNN(nn.Module):
    """The deployed hand7 network; names match the frozen checkpoint."""
    def __init__(self, variant, pool_size=1):
        super().__init__()
        if variant != 'hand7' or pool_size != 2:
            raise ValueError('Only hand7 with 2x2 pooling is retained')
        self.pool = nn.AdaptiveAvgPool2d(pool_size)
        self.dropout = nn.Dropout(.1)
        spec = CAPACITY_VARIANTS[variant]
        layers, incoming = [], 3
        for outgoing, repeats, stride in zip(spec['channels'], spec['repeats'], spec['strides']):
            for repeat in range(repeats):
                layers.extend([
                    nn.Conv2d(incoming, outgoing, 3, stride=stride if repeat == 0 else 1,
                              padding=1, bias=False),
                    nn.BatchNorm2d(outgoing), nn.ReLU(inplace=True),
                ])
                incoming = outgoing
        self.features = nn.Sequential(*layers)
        self.fc = nn.Linear(incoming*pool_size*pool_size, len(CLASSES))


    def forward_features(self, x):
        return self.pool(self.features(x)).flatten(1)

    def forward(self, x):
        return self.fc(self.dropout(self.forward_features(x)))

def display_predictions(probabilities, threshold=DEFAULT_THRESHOLD):
    if not 0 < threshold <= 1:
        raise ValueError('Threshold must be in (0, 1]')
    confidence, winner = probabilities.max(dim=-1)
    return torch.where(confidence >= threshold, winner + 1, 0)


def feature_distances(features, gate):
    """Nearest positive-class Mahalanobis distance, without background training."""
    features = features.double()
    centers = torch.as_tensor(gate['centers'], dtype=torch.float64, device=features.device)
    precision = torch.as_tensor(gate['precision'], dtype=torch.float64, device=features.device)
    delta = features[:, None, :]-centers[None, :, :]
    return torch.einsum('ncd,de,nce->nc', delta, precision, delta).clamp_min(0).min(1).values


def decisions(probabilities, features, config):
    prediction = display_predictions(probabilities, config['threshold'])
    gate = config.get('feature_gate')
    if gate is None:
        return prediction, None
    distance = feature_distances(features, gate)
    return torch.where(distance <= gate['maximum_distance'], prediction, 0), distance


def load_model(checkpoint=DEFAULT_CHECKPOINT, device='cpu'):
    saved = torch.load(checkpoint, map_location='cpu', weights_only=True)
    if (saved.get('architecture') != CAPACITY_ARCHITECTURE or saved.get('variant') != 'hand7'
            or saved.get('pool_size') != 2 or saved.get('classes') != CLASSES
            or saved.get('preprocess') != PREPROCESS or saved.get('comparison') != 'greater_equal'
            or not 0 < saved.get('threshold',0) <= 1
            or not 0 < saved.get('temperature',0) < float('inf')):
        raise ValueError('Expected the hand7 RGB96 three-class checkpoint')
    model = CapacityGestureCNN('hand7', 2)
    model.load_state_dict(saved['model'], strict=True)
    return model.to(device).eval(), saved

@torch.inference_mode()
def predict(model, config, image):
    device = next(model.parameters()).device
    features = model.forward_features(normalize(image_tensor(image).unsqueeze(0).to(device)))
    logits = model.fc(features).double()
    probabilities = torch.softmax(logits / config['temperature'], dim=-1)[0].cpu()
    prediction, distance = decisions(probabilities[None], features.cpu(), config)
    display_id = int(prediction[0])
    return {
        'label': DISPLAY_CLASSES[display_id], 'display_id': display_id,
        'confidence': float(probabilities.max()),
        'winner': CLASSES[int(probabilities.argmax())],
        'probabilities': {name: float(p) for name, p in zip(CLASSES, probabilities)},
        'threshold': config['threshold'],
        'rejection_reason': ('outside_training_distribution' if distance is not None
            and float(distance[0]) > config['feature_gate']['maximum_distance']
            else 'low_confidence' if display_id == 0 else None),
        'feature_distance': float(distance[0]) if distance is not None else None,
    }


def complexity(model):
    """Count real convolution/linear MACs; excludes normalization and activations."""
    macs = 0
    hooks = []

    def count(module, inputs, output):
        nonlocal macs
        if isinstance(module, nn.Conv2d):
            macs += (output.numel() * module.in_channels // module.groups
                     * module.kernel_size[0] * module.kernel_size[1])
        else:
            macs += output.numel() * module.in_features

    for module in model.modules():
        if isinstance(module, (nn.Conv2d, nn.Linear)):
            hooks.append(module.register_forward_hook(count))
    was_training = model.training
    model.eval()
    with torch.no_grad():
        model(torch.zeros(1, 3, SIZE, SIZE, device=next(model.parameters()).device))
    for hook in hooks:
        hook.remove()
    model.train(was_training)
    return {'parameters': sum(p.numel() for p in model.parameters()),
            'conv_and_linear_macs': macs,
            'input_shape': [3, SIZE, SIZE], 'inference_requires_resnet': False}


