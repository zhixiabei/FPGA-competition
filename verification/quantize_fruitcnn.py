"""Training-only W8A16 calibration and held-out FPGA-algorithm comparison.

Writes an isolated simulation candidate, never programs hardware.
"""
import argparse
import copy
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import zlib

import numpy as np
from PIL import Image, ImageOps
import torch
import torch.nn.functional as F

from fruitcnn import LITE_ARCHITECTURE, load_model
from fruitcnn_training import hardware_input, hardware_images
from handcnn_model import image_tensor, normalize, PREPROCESS
from handfixed_math import align, feature_bytes, integer_run, resize_roi
from handfixed_reference import texture_gate
from handcnn_training_utils import save_json, sha
from export_handfixed_fpga import emit_rom

ROOT = Path(__file__).resolve().parents[1]


def confidence_limit(threshold):
    if not 0 < threshold <= 1:
        raise ValueError('Confidence threshold must be greater than 0 and at most 1')
    return min(4*2**20, math.floor((1-threshold)/threshold * 2**20))


def exponent(value, maximum=32767):
    return math.ceil(math.log2(max(float(value), 1e-12)/maximum))


@torch.inference_mode()
def operation_layout(model, template=None):
    """Derive geometry from actual Conv modules, never reuse old channel sizes."""
    if len(model.features) != 21 or model.fc.out_features != 5:
        raise ValueError('The fixed-ROI exporter supports seven Conv/BN/ReLU layers and five classes')
    if template is None:
        template = [dict(index=6+i, name='classifier_' +
                        (f'conv{i+1}' if i < 7 else 'pool' if i == 7 else 'fc'),
                        src=0xd00000 if i % 2 == 0 else 0xd20000,
                        dst=0xd20000 if i % 2 == 0 else 0xd00000) for i in range(9)]
    if len(template) != 9 or [op['index'] for op in template] != list(range(6, 15)):
        raise ValueError('Expected classifier operation indices 6..14')
    ops = copy.deepcopy(template)
    cin, height, width = 3, 96, 96
    for i in range(7):
        conv = model.features[3*i]
        if (not isinstance(conv, torch.nn.Conv2d) or conv.groups != 1 or conv.dilation != (1, 1)
                or conv.in_channels != cin or conv.kernel_size[0] != conv.kernel_size[1]
                or conv.stride[0] != conv.stride[1] or conv.padding[0] != conv.padding[1]):
            raise ValueError('Unsupported convolution layout')
        kernel, stride, padding = conv.kernel_size[0], conv.stride[0], conv.padding[0]
        oh, ow = (height+2*padding-kernel)//stride+1, (width+2*padding-kernel)//stride+1
        ops[i].update(kind=0, relu=True, kernel=kernel, stride=stride, padding=padding,
                      cin=cin, cout=conv.out_channels, iw=width, ih=height, ow=ow, oh=oh,
                      src_plane=align(width*height, 8), dst_plane=align(ow*oh, 8),
                      input_shape=[cin, height, width], output_shape=[conv.out_channels, oh, ow])
        cin, height, width = conv.out_channels, oh, ow
    if (height, width) != (6, 6) or model.fc.in_features != cin*4 or model.pool.output_size != 2:
        raise ValueError('Exporter requires a 6x6 final feature map and 2x2 average pooling')
    ops[7].update(kind=1, relu=False, kernel=3, stride=3, padding=0,
                  cin=cin, cout=cin*4, iw=width, ih=height, ow=1, oh=1,
                  src_plane=align(height*width, 8), dst_plane=8,
                  input_shape=[cin, height, width], output_shape=[cin*4, 1, 1], groups=[[0, 0]])
    ops[8].update(kind=0, relu=False, kernel=1, stride=1, padding=0,
                  cin=cin*4, cout=5, iw=1, ih=1, ow=1, oh=1, src_plane=8, dst_plane=8,
                  input_shape=[cin*4, 1, 1], output_shape=[5, 1, 1])
    for op in ops:
        # Existing ping-pong DDR regions are 128 KiB apart; descriptors pack
        # spatial sizes into bytes and plane/word counts into unsigned shorts.
        if (max(op['iw'], op['ih'], op['ow'], op['oh']) > 255 or
                op['cin']*op['src_plane']*2 > 0x20000 or
                op['cout']*op['dst_plane']*2 > 0x20000 or
                op['cin']*op['src_plane']//8 > 4608 or
                (op['kind'] == 0 and op['cin']*op['kernel']**2 > 576) or
                max(op['src_plane'], op['dst_plane'], op['cin']*op['src_plane']//8,
                    op['cin']*op['kernel']**2, op['ow']*op['oh']) > 65535):
            raise ValueError('Model exceeds the fixed-ROI descriptor/buffer budget')
    return ops


@torch.inference_mode()
def calibrate(model, images, template=None):
    layers = []
    for i in range(0, len(model.features), 3):
        conv, bn = model.features[i:i+2]
        factor = bn.weight.double()/torch.sqrt(bn.running_var.double()+bn.eps)
        w = conv.weight.double()*factor[:, None, None, None]
        b = bn.bias.double()-bn.running_mean.double()*factor
        layers.append((w, b, conv.stride[0], conv.padding[0], True))
    ops = operation_layout(model, template)
    maxima = [0.]*len(ops)
    for batch in images.split(16):
        x = normalize(batch).double()
        for i, (w,b,stride,padding,_) in enumerate(layers):
            x = F.conv2d(x,w,b,stride=stride,padding=padding).relu()
            maxima[i] = max(maxima[i],float(x.abs().max()))
        x = F.avg_pool2d(x,3,3)
        maxima[7] = max(maxima[7],float(x.abs().max()))
        x = F.linear(x.flatten(1),model.fc.weight.double(),model.fc.bias.double())
        maxima[8] = max(maxima[8],float(x.abs().max()))
    layers += [None, (model.fc.weight.double().reshape(model.fc.out_features,model.fc.in_features,1,1),
                     model.fc.bias.double(),1,0,False)]
    source_exp = -13  # Existing RGB normalization ROM contract.
    details = []
    for i, (op, layer) in enumerate(zip(ops,layers)):
        op['src_exp'] = source_exp
        if layer is None:
            op['dst_exp'] = source_exp
            continue
        w,b,_,_,_ = layer
        dest_exp = exponent(maxima[i]*1.25)
        wexp = [exponent(v,127) for v in w.flatten(1).abs().max(1).values]
        scale = torch.tensor([2.**e for e in wexp],dtype=torch.float64)
        qw = torch.round(w/scale[:,None,None,None]).clamp(-127,127).to(torch.int64)
        qb = torch.round(b/(scale*2.**source_exp)).to(torch.int64)
        shifts = [dest_exp-source_exp-e for e in wexp]
        assert min(shifts)>=0 and max(shifts)<64
        bounds = qw.flatten(1).abs().sum(1)*32768+qb.abs()
        assert int(bounds.max()) < 2**39
        op.update(cout=len(w),weights=qw.flatten(1).tolist(),biases=qb.tolist(),shifts=shifts,
                  dst_exp=dest_exp,max_accumulator_bound=int(bounds.max()))
        op['output_shape'][0] = len(w)
        details.append(dict(name=op['name'],training_abs_max=maxima[i],dst_exp=dest_exp,
                            weight_exponents=wexp,accumulator_bound=int(bounds.max())))
        source_exp=dest_exp
    return ops,details


def emit_bundle(ops, out, saved, checkpoint):
    blob=bytearray(256);blob[:8]=b'HFIXCNN1'
    for op in ops:
        if op['kind']==1: continue
        op['groups']=[]
        for group in range(math.ceil(op['cout']/24)):
            blob.extend(bytes(align(len(blob))-len(blob)))
            waddr=0xc00000+len(blob)
            terms=op['cin']*op['kernel']**2
            for term in range(terms):
                tile=bytearray(32)
                for lane in range(min(24,op['cout']-group*24)):
                    tile[lane]=op['weights'][group*24+lane][term]&255
                blob.extend(tile)
            caddr=0xc00000+len(blob)
            for lane in range(24):
                oc=group*24+lane
                bias,shift=(op['biases'][oc],op['shifts'][oc]) if oc<op['cout'] else (0,0)
                blob.extend((bias&((1<<40)-1)).to_bytes(5,'little')+bytes([shift,0,0]))
            op['groups'].append([waddr,caddr])
    blob.extend(bytes(align(len(blob),256)-len(blob)))
    if len(blob) > 0x100000:
        raise ValueError('Weight bundle would overlap the feature DDR regions')
    crc=zlib.crc32(blob)
    (out/'model.bin').write_bytes(blob)
    write_hex(out/'model.hex',blob)
    emit_rom(ops,out,crc,len(blob))
    label_overrides = {'dragonfruit': 'DRAGON', 'pineapple': 'PINEAPL',
                       'strawberry': 'STRAWBR', 'watermelon': 'WATERML'}
    display_labels = [label_overrides.get(name, name.upper())[:7].ljust(7)
                      for name in saved['classes']]
    if any(not label.isascii() for label in display_labels) or len(set(display_labels)) != 5:
        raise ValueError('FPGA display labels must be five distinct ASCII strings')
    config=dict(format='HFIXCNN1',classes=saved['classes'],display_labels=display_labels,operations=ops,
                architecture=saved['architecture'],preprocess=saved['preprocess'],
                temperature=saved['temperature'],classifier_threshold=saved['threshold'],
                confidence_exp_sum_max=confidence_limit(saved['threshold']),
                classifier_sha256=sha(checkpoint),model_sha256=hashlib.sha256(blob).hexdigest(),
                model_bytes=len(blob),crc32=f'{crc:08x}',roi=[400,120,480],
                weights='INT8',activations='INT16',accumulator_bits=40,
                classifier_first_op=6,last_op=14,fpga_deployed=False,
                texture_gate=dict(channel='green',minimum_range=16,edge_delta=12,minimum_horizontal_edges=24),
                requires_five_class_decoder=True,requires_regenerated_program=True,
                rtl_verified=False,board_verified=False)
    save_json(out/'model.json',config)
    decoder = (ROOT/'user_source/hdl_source/fruitfixed/fruitfixed_decode.v').read_text(encoding='utf-8')
    decoder, count = re.subn(r"ACCEPT_EXP_SUM_MAX = 23'd\d+;",
                            f"ACCEPT_EXP_SUM_MAX = 23'd{config['confidence_exp_sum_max']};", decoder)
    if count != 1:
        raise ValueError('Expected one decoder confidence threshold declaration')
    (out/'fruitfixed_decode.v').write_text(decoder, encoding='utf-8')
    lut=[math.ceil(2**20*math.exp(-i*32*2.**ops[-1]['dst_exp']/saved['temperature'])) for i in range(512)]
    text=['// Fruit checkpoint-specific conservative exponential bounds.',
          'module handcnn_confidence(input wire clk,input wire [8:0] address,output reg [20:0] value);',
          'always @(posedge clk) case(address)']
    text += [f"9'd{i}:value=21'd{v};" for i,v in enumerate(lut)]
    text += ["default:value=21'd1048576;endcase",'endmodule']
    (out/'handcnn_confidence.v').write_text('\n'.join(text)+'\n')
    return config,lut


def write_hex(path,data):
    assert len(data)%16==0
    path.write_text(''.join(f'{int.from_bytes(data[i:i+16],"little"):032x}\n' for i in range(0,len(data),16)),encoding='ascii')


def decisions(q,lut,threshold=.65):
    q=q.reshape(len(q),5).to(torch.int64)
    winners=q.argmax(1)
    sums=[]
    for values,winner in zip(q,winners):
        sums.append(sum(lut[min(int(values.max()-value)>>5,511)] for i,value in enumerate(values) if i!=int(winner)))
    accepted=torch.tensor(sums)<=confidence_limit(threshold)
    return winners,torch.where(accepted,winners+2,1),sums


def summarize(pred,labels,classes,display=None):
    matrix=torch.bincount(labels*5+pred,minlength=25).reshape(5,5)
    result=dict(correct=int((pred==labels).sum()),samples=len(labels),accuracy=float((pred==labels).double().mean()),
                confusion=matrix.tolist(),per_class={c:dict(correct=int(matrix[i,i]),samples=int(matrix[i].sum())) for i,c in enumerate(classes)})
    if display is not None:
        result.update(rejected=int((display==1).sum()),accepted_correct=int((display==labels+2).sum()),
                      accepted_wrong=int(((display!=1)&(display!=labels+2)).sum()))
    return result


def verify_normalization():
    text=(ROOT/'user_source/hdl_source/handcnn/handcnn_normalize.v').read_text()
    rom={int(a):int(b,16) for a,b in re.findall(r"11'd(\d+):value=16'h([0-9a-f]+)",text)}
    pixels=torch.arange(256,dtype=torch.uint8)[None,None,None,:].expand(1,3,1,256)
    expected=torch.round(normalize(pixels)*8192).to(torch.int64)[0,:,0]
    for c in range(3):
        for v in range(256):
            assert rom[1024+c*256+v]==(int(expected[c,v])&65535)


@torch.inference_mode()
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--training',type=Path,default=ROOT/'build/fruits5_hand7_20261023')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--threshold',type=float,default=None,
                   help='Override acceptance threshold without changing trained weights')
    p.add_argument('--temperature',type=float,default=None,
                   help='Override confidence temperature without changing trained weights')
    args=p.parse_args()
    if args.threshold is not None:
        confidence_limit(args.threshold)
    if args.temperature is not None and (not math.isfinite(args.temperature) or args.temperature <= 0):
        p.error('--temperature must be finite and greater than 0')
    out=args.output;out.mkdir(parents=True,exist_ok=False)
    torch.set_num_threads(6)
    model,saved=load_model(args.training/'model.pt')
    trained_threshold, trained_temperature = saved['threshold'], saved['temperature']
    if args.threshold is not None or args.temperature is not None:
        saved = dict(saved,
                     threshold=trained_threshold if args.threshold is None else args.threshold,
                     temperature=trained_temperature if args.temperature is None else args.temperature)
    if len(saved['classes']) != 5 or len(set(saved['classes'])) != 5:
        raise ValueError('The FPGA decoder requires exactly five distinct classes')
    manifest=json.loads((args.training/'data_manifest.json').read_text())
    assert sha(args.training/'data_manifest.json')==saved['manifest_sha256']
    sets={s:[r for r in manifest['samples'] if r['split']==s] for s in ['train','test']}
    def pixels(rows):
        values=[]
        for r in rows:
            assert sha(Path(r['path']))==r['source_sha256']
            with Image.open(r['path']) as im: t=image_tensor(im)
            assert hashlib.sha256(t.numpy().tobytes()).hexdigest()==r['input_sha256']
            values.append(t)
        return torch.stack(values)
    train=pixels(sets['train'])
    calibration_inputs = train
    if saved['architecture'] == LITE_ARCHITECTURE:
        calibration_inputs = torch.cat([train, hardware_images(sets['train'])])
    ops,calibration=calibrate(model,calibration_inputs)
    save_json(out/'calibration.json',dict(split='train_only',source_images=len(train),
              presentations=len(calibration_inputs),samples=len(calibration_inputs),headroom=1.25,layers=calibration,
              includes_hardware_resize=saved['architecture'] == LITE_ARCHITECTURE))
    config,lut=emit_bundle(ops,out,saved,args.training/'model.pt')
    verify_normalization()
    print('CALIBRATED '+json.dumps(dict(bytes=config['model_bytes'],normalization='768 entries match',layers=calibration)),flush=True)
    test=pixels(sets['test']);labels=torch.tensor([r['target'] for r in sets['test']])
    fp=torch.cat([model(normalize(b)) for b in test.split(16)]).double()
    # Sanity against the frozen earlier evaluation, not for model selection.
    previous=json.loads((args.training/'evaluation.json').read_text())
    assert int((fp.argmax(1)==labels).sum())==previous['test']['correct']
    q=torch.cat([integer_run(ops,normalize(b)).flatten(1) for b in test.split(8)])
    qpred,qdisplay,qsums=decisions(q,lut,saved['threshold'])
    float_display=torch.where((fp/saved['temperature']).softmax(1).max(1).values>=saved['threshold'],fp.argmax(1)+2,1)
    hw_crops=[];texture=[]
    for row in sets['test']:
        _,crop=hardware_input(row['path']);hw_crops.append(torch.from_numpy(crop.copy()).permute(2,0,1));texture.append(texture_gate(crop))
    hw=torch.stack(hw_crops)
    hfp=torch.cat([model(normalize(b)) for b in hw.split(16)]).double()
    hq=torch.cat([integer_run(ops,normalize(b)).flatten(1) for b in hw.split(8)])
    hp,hd,hsums=decisions(hq,lut,saved['threshold'])
    gated=hd.clone()
    for i,t in enumerate(texture):
        if not t['has_texture']: gated[i]=1
    saturation=[]
    for i,op in enumerate(ops):
        saturation.append(dict(operation=op['index'],saturated_values=0,total=0))
    for b in hw.split(8):
        values=integer_run(ops,normalize(b),collect=True)
        for i,v in enumerate(values[1:]):
            saturation[i]['saturated_values']+=int(((v==32767)|(v==-32768)).sum())
            saturation[i]['total']+=v.numel()
    with (out/'test_predictions.csv').open('w',newline='',encoding='utf-8') as f:
        writer=csv.writer(f);writer.writerow(['path','truth','float_prediction','quant_prediction','hardware_float','hardware_quant','hardware_display','texture_edges','texture_range'])
        for i,row in enumerate(sets['test']):
            writer.writerow([row['path'],row['label'],saved['classes'][int(fp[i].argmax())],saved['classes'][int(qpred[i])],
                             saved['classes'][int(hfp[i].argmax())],saved['classes'][int(hp[i])],int(gated[i]),texture[i]['texture_edges'],texture[i]['texture_range']])
    cases=[]
    for c in range(5):
        i=int(torch.where(labels==c)[0][0]);row=sets['test'][i]
        roi,_=hardware_input(row['path'])
        raster=np.full((720,1280,3),PREPROCESS['fill'],dtype=np.uint8);raster[120:600,400:880]=roi
        # Snapshot is in camera stream order (first pixel is in the MSB).
        data=raster.tobytes()
        (out/f'snapshot_{c}.hex').write_text(''.join(data[j:j+16].hex()+'\n' for j in range(0,len(data),16)))
        values=integer_run(ops,normalize(hw[i:i+1]),collect=True)
        write_hex(out/f'input_{c}.hex',feature_bytes(values[0]))
        for j,op in enumerate(ops):
            write_hex(out/f'case_{c}_op_{op["index"]}.hex',feature_bytes(values[j+1].reshape(1,*op['output_shape'])))
        cases.append(dict(case=c,path=row['path'],truth=c,logits=hq[i].to(torch.int64).tolist(),
                          expected_class=int(hd[i]),texture=texture[i]))
    # Decoder edge cases: each class, ties, rejection, full signed range, boundary decisions.
    decoder_cases=[]
    logits_cases=[[0]*5,[-32768]*5,[32767]*5]
    for c in range(5):
        v=[-32768]*5;v[c]=32767;logits_cases.append(v)
    rng=np.random.default_rng(20261023)
    logits_cases += rng.integers(-32768,32768,size=(100,5)).tolist()
    # Winner margin where sum crosses the threshold, for all five winner positions.
    boundary=next((delta for delta in range(0,32768,32)
                   if 4*lut[min(delta>>5,511)]<=config['confidence_exp_sum_max']),32736)
    for c in range(5):
        for margin in [max(0,boundary-1),boundary,min(32767,boundary+1)]:
            v=[-margin]*5;v[c]=0;logits_cases.append(v)
    for v in logits_cases:
        _,d,s=decisions(torch.tensor([v]),lut,saved['threshold']);decoder_cases.append(dict(logits=v,expected=int(d[0]),exp_sum=s[0]))
    save_json(out/'simulation_cases.json',dict(pipeline=cases,decoder=decoder_cases))
    result=dict(checkpoint_sha256=sha(args.training/'model.pt'),model_sha256=config['model_sha256'],
                classes=saved['classes'],normalization_rom_entries_checked=768,
                trained_threshold=trained_threshold,classifier_threshold=saved['threshold'],
                trained_temperature=trained_temperature,classifier_temperature=saved['temperature'],
                confidence_exp_sum_max=config['confidence_exp_sum_max'],
                float=summarize(fp.argmax(1),labels,saved['classes'],float_display),
                quantized_same_input=summarize(qpred,labels,saved['classes'],qdisplay),
                quantized_top1_agreement=int((qpred==fp.argmax(1)).sum()),
                quantized_display_agreement=int((qdisplay==float_display).sum()),
                hardware_resize_float=summarize(hfp.argmax(1),labels,saved['classes']),
                hardware_resize_quantized=summarize(hp,labels,saved['classes'],hd),
                hardware_with_texture_gate=summarize(hp,labels,saved['classes'],gated),
                texture_rejections=[sets['test'][i]['path'] for i,t in enumerate(texture) if not t['has_texture']],
                activation_saturation=saturation,fpga_deployed=False,
                limitations=['Synthetic 480px ROI placements, not real board captures.',
                             'Confidence overrides are explicit deployment parameters; scales are not fitted on test images.',
                             'Existing test set has already been reported; not a new blind benchmark.',
                             'RGB preprocessor, core and decoder RTL tests run separately after export.'])
    save_json(out/'evaluation.json',result)
    print('EVALUATION '+json.dumps(result),flush=True)


if __name__=='__main__': main()
