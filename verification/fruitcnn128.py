"""RGB128 CNN with explicit Scharr/Laplacian features and training-only heads.

Inference is seven Conv/BN/ReLU blocks, 4x4 average pooling and one FC.
This is a NEW checkpoint contract; do not feed it to the RGB96 FPGA exporter.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps
import torch
from torch import nn
import torch.nn.functional as F

from handcnn_model import PREPROCESS as RGB96_PREPROCESS, normalize

ARCHITECTURE = 'fruit_scharr_texture_rgb128_v1'
PREPROCESS = dict(RGB96_PREPROCESS, size=128)
CLASSES = ['apple', 'banana', 'grape', 'orange', 'strawberry']


def image_tensor(image):
    image = ImageOps.exif_transpose(image).convert('RGB')
    image = ImageOps.pad(image, (128, 128), method=Image.Resampling.BILINEAR,
                         color=tuple(PREPROCESS['fill']))
    return torch.from_numpy(np.array(image, dtype=np.uint8, copy=True)).permute(2, 0, 1)


class FruitCNN128(nn.Module):
    channels = (12, 12, 24, 32, 48, 64, 96)
    strides = (2, 1, 2, 2, 1, 2, 1)

    def __init__(self, classes=CLASSES, auxiliary=False):
        super().__init__()
        if len(classes) < 2 or len(set(classes)) != len(classes):
            raise ValueError('Need distinct classes')
        self.classes = list(classes)
        layers, incoming = [], 3
        for outgoing, stride in zip(self.channels, self.strides):
            layers.extend([nn.Conv2d(incoming, outgoing, 3, stride, 1, bias=False),
                           nn.BatchNorm2d(outgoing), nn.ReLU(inplace=True)])
            incoming = outgoing
        self.features = nn.Sequential(*layers)
        self.pool = nn.AvgPool2d(4, 4)
        self.dropout = nn.Dropout(.25)
        self.fc = nn.Linear(384, len(classes))
        # Raw luminance gradients, BEFORE the display Scharr module's Gaussian,
        # NMS and thresholding. Positive and negative filters survive ReLU.
        gx = torch.tensor([[-3., 0, 3], [-10, 0, 10], [-3, 0, 3]]) / 16
        lap = torch.tensor([[0., 1, 0], [1, -4, 1], [0, 1, 0]]) / 4
        kernels = torch.stack([gx, -gx, gx.T, -gx.T, lap, -lap])
        # x=(RGB-mean)/std. Multiplying by std restores RGB derivative units.
        # Zero-sum kernels remove the constant luminance mean in the interior.
        color = torch.tensor([.25, .5, .25]) * torch.tensor(PREPROCESS['std'])
        self.register_buffer('_fixed_filters', kernels[:, None] * color[None, :, None, None],
                             persistent=False)
        self.project_fixed_filters()
        self.features[0].weight.register_hook(self._mask_fixed_gradients)
        if auxiliary:
            self.shape_head = nn.Linear(384, 16*4)
            self.texture_head = nn.Linear(384, 16*10)

    @staticmethod
    def _mask_fixed_gradients(gradient):
        result = gradient.clone()
        result[:6] = 0
        return result

    @torch.no_grad()
    def project_fixed_filters(self):
        # Also undo AdamW weight decay on the fixed rows after every step.
        self.features[0].weight[:6].copy_(self._fixed_filters)

    def forward_features(self, x):
        if x.shape[-2:] != (128, 128):
            raise ValueError('This architecture requires 128x128 input')
        return self.pool(self.features(x)).flatten(1)

    def forward(self, x, auxiliary=False):
        features = self.forward_features(x)
        logits = self.fc(self.dropout(features))
        if not auxiliary:
            return logits
        if not hasattr(self, 'shape_head'):
            raise ValueError('Auxiliary heads were not constructed')
        return logits, self.shape_head(features).reshape(-1, 16, 4), self.texture_head(features).reshape(-1, 16, 10)

    def inference_state_dict(self):
        return {k: v.detach().cpu().clone() for k, v in self.state_dict().items()
                if not k.startswith(('shape_head.', 'texture_head.'))}


@torch.no_grad()
def descriptor_targets(images, foreground):
    """4x4-cell Scharr direction histograms and rotation-invariant uniform LBP.

    No class-specific thresholds. Padding and known white background are masked.
    Nonwhite backgrounds have only a weak foreground mask, not segmentation.
    Histograms are supervision targets; no LBP operator is needed on the FPGA.
    """
    if images.shape[-2:] != (128, 128) or foreground.shape != images[:, :1].shape:
        raise ValueError('Expected NCHW RGB128 and N1HW masks')
    gray = (images.float()/255 * images.new_tensor([.25,.5,.25], dtype=torch.float32)[None,:,None,None]).sum(1, keepdim=True)
    valid = foreground.float().clone()
    valid[..., :2, :] = valid[..., -2:, :] = 0
    valid[..., :, :2] = valid[..., :, -2:] = 0
    # A target center is valid only if its full 3x3 neighbourhood is foreground.
    valid = (F.avg_pool2d(valid, 3, 1, 1) > .999).float()
    kernel = gray.new_tensor([[-3,0,3],[-10,0,10],[-3,0,3]])/16
    gradients = F.conv2d(gray, torch.stack([kernel,kernel.T])[:,None], padding=1)
    gx, gy = gradients[:,0:1], gradients[:,1:2]
    angle = torch.remainder(torch.atan2(gy, gx), torch.pi)
    bins = torch.floor(angle / (torch.pi/4)).long().clamp(0,3)
    strength = gradients.square().sum(1,keepdim=True).sqrt()*valid
    directions = torch.cat([(bins == i)*strength for i in range(4)], 1)
    # Ignore derivatives too weak to carry meaningful shape evidence.
    shape = F.avg_pool2d(directions, 32).flatten(2).transpose(1,2)
    shape_mass = shape.sum(-1, keepdim=True)
    shape = shape / shape_mass.clamp_min(1e-8)
    center = gray[...,1:-1,1:-1]
    offsets = ((0,0),(0,1),(0,2),(1,2),(2,2),(2,1),(2,0),(1,0))
    bits = torch.stack([gray[...,y:y+126,x:x+126] >= center for y,x in offsets], 1).squeeze(2)
    transitions = (bits != bits.roll(1,1)).sum(1)
    codes = torch.where(transitions <= 2, bits.sum(1), 9)
    codes = F.pad(codes, (1,1,1,1), value=9)
    textures = torch.stack([(codes == i).float() for i in range(10)], 1)*valid
    texture = F.avg_pool2d(textures, 32).flatten(2).transpose(1,2)
    texture_mass = texture.sum(-1, keepdim=True)
    texture = texture / texture_mass.clamp_min(1e-8)
    return shape, texture, shape_mass.squeeze(-1) > .002, texture_mass.squeeze(-1) > .1


def histogram_loss(logits, target, valid):
    losses = -(target*logits.float().log_softmax(-1)).sum(-1)
    return (losses*valid).sum()/valid.sum().clamp_min(1)


def model_budget(model):
    layers, cin, size, macs = [], 3, 128, 0
    for i, (cout, stride) in enumerate(zip(model.channels, model.strides), 1):
        out = (size+1)//2 if stride == 2 else size
        layers.append(dict(layer=i, input=[cin,size,size], output=[cout,out,out],
                           input_bytes=cin*size*size*2, output_bytes=cout*out*out*2,
                           needs_input_tiling=cin*size*size*2 > 73728))
        macs += out*out*cout*cin*9
        cin, size = cout, out
    macs += model.fc.in_features*model.fc.out_features
    return dict(inference_parameters=sum(v.numel() for k,v in model.named_parameters()
                                         if not k.startswith(('shape_head.','texture_head.'))),
                conv_and_linear_macs=macs, layers=layers,
                fpga_constraints=dict(device='PH1P35MDG324', max_slice_percent=90,
                                      max_slices=19094, total_slices=21216,
                                      measured_slice_percent=None, approved_for_deployment=False,
                                      requires=['128 ROI preprocessing','tiling for oversized inputs',
                                                '8x8 -> 2x2 average pool','background sampling update',
                                                'new export descriptors','place and route <=90% slices']),
                note='A training architecture budget, not a synthesis or board result.')


def load_model(path, device='cpu'):
    saved = torch.load(Path(path), map_location='cpu', weights_only=True)
    if saved.get('architecture') != ARCHITECTURE or saved.get('preprocess') != PREPROCESS:
        raise ValueError('Expected the new RGB128 shape/texture checkpoint')
    model = FruitCNN128(saved['classes'])
    model.load_state_dict(saved['model'], strict=True)
    if not torch.equal(model.features[0].weight[:6], model._fixed_filters):
        raise ValueError('Fixed shape/texture filters changed')
    return model.to(device).eval(), saved
