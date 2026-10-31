"""Small RGB96 fruit CNNs with versioned, portable checkpoints."""
import argparse
import json
from pathlib import Path
import random
import sys

import numpy as np
import torch
from torch import nn
from PIL import Image
from handcnn_model import CapacityGestureCNN, PREPROCESS, image_tensor, normalize

ARCHITECTURE = 'fruit_hand7_rgb96_v1'
LITE_ARCHITECTURE = 'fruit_lite_rgb96_v2'
FRUIT_VARIANTS = {'hand7': ARCHITECTURE, 'fruit_lite_v2': LITE_ARCHITECTURE}


class FruitLiteCNN(nn.Module):
    """Seven ordinary convolutions; keep the second convolution at 48x48.

    Five classes: 112,389 trainable parameters and 14,268,288 Conv/Linear MACs.
    The final 6x6x96 feature map and 2x2 pooling retain the export interface.
    Export descriptors must still be regenerated for the new channels/strides.
    """
    channels = (16, 16, 24, 32, 48, 64, 96)
    strides = (2, 1, 2, 2, 1, 2, 1)

    def __init__(self, classes):
        super().__init__()
        layers, incoming = [], 3
        for outgoing, stride in zip(self.channels, self.strides):
            layers.extend([nn.Conv2d(incoming, outgoing, 3, stride, 1, bias=False),
                           nn.BatchNorm2d(outgoing), nn.ReLU(inplace=True)])
            incoming = outgoing
        self.features = nn.Sequential(*layers)
        self.pool = nn.AdaptiveAvgPool2d(2)
        # The dataset has only a few hundred independent images.  Dropout is
        # training-only, so this adds regularization without changing FPGA ops.
        self.dropout = nn.Dropout(.25)
        self.fc = nn.Linear(incoming * 4, len(classes))

    def forward_features(self, x):
        return self.pool(self.features(x)).flatten(1)

    def forward(self, x):
        return self.fc(self.dropout(self.forward_features(x)))


def configure_training(device_name, threads, seed):
    """Select the requested device; explicit CUDA never silently falls back."""
    if device_name == 'auto':
        device_name = 'cuda' if torch.cuda.is_available() else 'cpu'
    device = torch.device(device_name)
    if device.type == 'cuda' and not torch.cuda.is_available():
        raise RuntimeError(
            f'CUDA is unavailable in {sys.executable}. In PyCharm select the '
            'project .conda/fruitcuda/python.exe interpreter, or explicitly '
            'pass --device cpu for CPU training.')
    torch.set_num_threads(threads)
    random.seed(seed)
    np.random.seed(seed % (2**32))
    torch.manual_seed(seed)
    # AdaptiveAvgPool2d backward on CUDA has no strictly deterministic kernel.
    # Keep the original strict CPU behavior and seeded cuDNN behavior on GPU.
    torch.use_deterministic_algorithms(device.type == 'cpu')
    if device.type == 'cuda':
        torch.backends.cudnn.benchmark = False
        torch.backends.cudnn.deterministic = True
        # Match the FP32 CPU/export reference rather than cuDNN's default TF32.
        torch.backends.cuda.matmul.allow_tf32 = False
        torch.backends.cudnn.allow_tf32 = False
    details = dict(device=str(device),
                   device_name=torch.cuda.get_device_name(device) if device.type == 'cuda' else 'CPU',
                   python=sys.executable, torch_version=str(torch.__version__),
                   cuda_runtime=torch.version.cuda,
                   deterministic_algorithms=torch.are_deterministic_algorithms_enabled())
    print('TRAINING_DEVICE ' + json.dumps(details), flush=True)
    return device, details


def cpu_state_dict(model):
    return {name: value.detach().cpu().clone() for name, value in model.state_dict().items()}


def make_model(classes, architecture=ARCHITECTURE):
    architecture = FRUIT_VARIANTS.get(architecture, architecture)
    if architecture == LITE_ARCHITECTURE:
        return FruitLiteCNN(classes)
    if architecture != ARCHITECTURE:
        raise ValueError('Unsupported fruit architecture: ' + str(architecture))
    model = CapacityGestureCNN('hand7', pool_size=2)
    model.fc = nn.Linear(model.fc.in_features, len(classes))
    return model


def load_model(path, device='cpu'):
    saved = torch.load(path, map_location='cpu', weights_only=True)
    if saved['architecture'] not in FRUIT_VARIANTS.values() or saved['preprocess'] != PREPROCESS:
        raise ValueError('Unsupported fruit checkpoint or preprocessing')
    model = make_model(saved['classes'], saved['architecture'])
    model.load_state_dict(saved['model'], strict=True)
    return model.to(device).eval(), saved


@torch.inference_mode()
def predict(model, saved, image):
    device = next(model.parameters()).device
    logits = model(normalize(image_tensor(image)[None].to(device))).double()
    probabilities = (logits / saved['temperature']).softmax(1)[0].cpu()
    return dict(winner=saved['classes'][int(probabilities.argmax())],
                probabilities=dict(zip(saved['classes'], probabilities.tolist())),
                confidence=float(probabilities.max()),
                label=(saved['classes'][int(probabilities.argmax())]
                       if probabilities.max() >= saved['threshold'] else 'UNKNOWN'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--device', choices=['cpu', 'cuda', 'auto'], default='cpu')
    args = parser.parse_args()
    torch.set_num_threads(4)
    device = ('cuda' if torch.cuda.is_available() else 'cpu') if args.device == 'auto' else args.device
    model, saved = load_model(args.checkpoint, device=device)
    with Image.open(args.image) as image:
        print(json.dumps(predict(model, saved, image), indent=2))
