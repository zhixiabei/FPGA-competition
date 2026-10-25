"""Export RGB128 W8A12 (INT16 DDR containers), using training-only scales."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps
import torch
import torch.nn.functional as F

from fruitcnn128 import ARCHITECTURE, PREPROCESS, load_model, normalize
from handcnn_training_utils import save_json, sha
from handfixed_math import align, feature_bytes, resize_roi
from handfixed_reference import texture_gate
from quantize_fruitcnn import decisions, emit_bundle, exponent, summarize, write_hex
from train_fruitcnn128 import load_data, hardware_images

ROOT = Path(__file__).resolve().parents[1]


def layout(model):
    ops = []
    cin, size = 3, 128
    for i in range(9):
        src, dst = (0xd00000, 0xd20000) if i % 2 == 0 else (0xd20000, 0xd00000)
        if i < 7:
            conv = model.features[i*3]
            assert conv.in_channels == cin and conv.groups == 1 and conv.kernel_size == (3,3)
            cout, k, stride, pad = conv.out_channels, 3, conv.stride[0], 1
            out_size = (size+2*pad-k)//stride+1
            output = [cout,out_size,out_size]
            kind, relu = 0, True
        elif i == 7:
            assert size == 8 and model.pool.kernel_size == 4 and model.fc.in_features == cin*4
            cout, k, stride, pad, out_size = cin*4,4,4,0,1
            output = [cout,1,1]
            kind, relu = 1, False
        else:
            assert model.fc.out_features == 5
            cout, k, stride, pad, out_size = 5,1,1,0,1
            output = [5,1,1]
            kind, relu = 0, False
        op = dict(index=6+i,name=f'classifier_{i+1}',src=src,dst=dst,
                  kind=kind,relu=relu,kernel=k,stride=stride,padding=pad,
                  cin=cin,cout=cout,iw=size,ih=size,ow=out_size,oh=out_size,
                  src_plane=align(size*size,8),dst_plane=align(out_size*out_size,8),
                  input_shape=[cin,size,size],output_shape=output)
        assert cin*op['src_plane']//8 <= 6144
        assert max(cin*op['src_plane']*2,cout*op['dst_plane']*2) <= 0x20000
        assert kind or cin*k*k <= 576
        if kind:
            op['groups'] = [[0,0]]
        ops.append(op)
        cin, size = cout, out_size
    return ops


@torch.inference_mode()
def calibrate(model, images):
    ops = layout(model)
    layers = []
    for i in range(7):
        conv,bn = model.features[i*3:i*3+2]
        scale = bn.weight.double()/torch.sqrt(bn.running_var.double()+bn.eps)
        layers.append((conv.weight.double()*scale[:,None,None,None],
                       bn.bias.double()-bn.running_mean.double()*scale))
    maxima = [0.]*9
    for batch in images.split(16):
        x = normalize(batch).double()
        for i,(w,b) in enumerate(layers):
            x = F.conv2d(x,w,b,stride=ops[i]['stride'],padding=1).relu()
            maxima[i] = max(maxima[i],float(x.max()))
        x = F.avg_pool2d(x,4,4)
        maxima[7] = max(maxima[7],float(x.max()))
        x = F.linear(x.flatten(1),model.fc.weight.double(),model.fc.bias.double())
        maxima[8] = max(maxima[8],float(x.abs().max()))
    layers += [None,(model.fc.weight.double().reshape(5,-1,1,1),model.fc.bias.double())]
    src_exp, details = -9, []
    for i,(op,layer) in enumerate(zip(ops,layers)):
        op['src_exp'] = src_exp
        if layer is None:
            op['dst_exp'] = src_exp
            continue
        w,b = layer
        # Cache operands fit signed 12 bits; final logits retain signed 16 bits.
        maximum = 2047 if op['relu'] else 32767
        dst_exp = exponent(maxima[i]*1.25,maximum)
        wexp = [exponent(v,127) for v in w.flatten(1).abs().amax(1)]
        scales = torch.tensor([2.**e for e in wexp],dtype=torch.float64)
        qw = torch.round(w/scales[:,None,None,None]).clamp(-127,127).long()
        qb = torch.round(b/(scales*2.**src_exp)).long()
        shifts = [dst_exp-src_exp-e for e in wexp]
        assert min(shifts) >= 0 and max(shifts) < 64
        bounds = qw.flatten(1).abs().sum(1)*2048+qb.abs()
        assert int(bounds.max()) < 2**39
        op.update(weights=qw.flatten(1).tolist(),biases=qb.tolist(),shifts=shifts,
                  dst_exp=dst_exp,max_accumulator_bound=int(bounds.max()))
        details.append(dict(operation=op['index'],training_abs_max=maxima[i],
                            dst_exp=dst_exp,weight_exponents=wexp,
                            accumulator_bound=int(bounds.max())))
        src_exp = dst_exp
    return ops,details


def integer_run(ops, images, collect=False):
    x = torch.round(normalize(images).double()*512).clamp(-2048,2047)
    values = [x]
    for op in ops:
        # Verify compression will preserve every cached operand exactly.
        assert x.min() >= -2048 and x.max() <= 2047
        if op['kind']:
            x = F.avg_pool2d(x,4,4).floor()
        else:
            x = x.reshape(len(x),*op['input_shape'])
            w = torch.tensor(op['weights'],dtype=torch.float64).reshape(op['cout'],op['cin'],op['kernel'],op['kernel'])
            x = F.conv2d(x,w,torch.tensor(op['biases'],dtype=torch.float64),
                         stride=op['stride'],padding=op['padding'])
            shifts = torch.tensor(op['shifts'],dtype=torch.float64)
            x = (x/torch.pow(2.,shifts)[None,:,None,None]).floor()
            x = x.clamp(0,2047) if op['relu'] else x.clamp(-32768,32767)
        values.append(x)
    return values if collect else x


def normalization_rom(out):
    pixels = torch.arange(256,dtype=torch.uint8)[None,None,None,:].expand(1,3,1,256)
    values = torch.round(normalize(pixels)*512).long()[0,:,0]
    assert values.min() >= -2048 and values.max() <= 2047
    lines = ['// RGB128 Q9 normalization, signed 12-bit operands in INT16 DDR.',
             'module handcnn_normalize(input wire clk,input wire [10:0] address,output reg [15:0] value);',
             'always @(posedge clk) case(address)']
    lines += [f"11'd{1024+c*256+v}:value=16'h{int(values[c,v])&65535:04x};"
              for c in range(3) for v in range(256)]
    lines += ["default:value=16'd0;endcase",'endmodule']
    (out/'handcnn_normalize.v').write_text('\n'.join(lines)+'\n',encoding='ascii')


@torch.inference_mode()
def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--training',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    args = p.parse_args()
    torch.set_num_threads(6)
    model,saved = load_model(args.training/'model.pt')
    assert saved['architecture'] == ARCHITECTURE
    if len(saved['classes']) != 5 or len(set(saved['classes'])) != 5:
        raise ValueError('RGB128 FPGA export requires five distinct checkpoint classes')
    assert sha(args.training/'data_manifest.json') == saved['manifest_sha256']
    classes,rows,pixels,labels = load_data(args.training/'data_manifest.json')
    if classes != saved['classes']:
        raise ValueError('Checkpoint and training manifest class orders differ')
    ids = {s:torch.tensor([i for i,r in enumerate(rows) if r['split']==s]) for s in ('train','validation','test')}
    train_rows = [rows[i] for i in ids['train'].tolist()]
    # Test images never influence weight/activation scales or acceptance settings.
    inputs = torch.cat([pixels[ids['train']],hardware_images(train_rows)])
    ops,details = calibrate(model,inputs)
    out = args.output.resolve()
    out.mkdir(parents=True,exist_ok=False)
    config,lut = emit_bundle(ops,out,saved,args.training/'model.pt')
    config.update(activation_precision_bits=12,activation_container_bits=16,
                  final_logit_precision_bits=16,cache_bits=96,cache_words=6144,
                  normalization_exponent=-9,pool_kernel=4,
                  cache_storage_bytes=73728,training_directory=str(args.training.resolve()))
    save_json(out/'model.json',config)
    normalization_rom(out)
    save_json(out/'calibration.json',dict(split='train_only',source_images=len(train_rows),
              presentations=len(inputs),headroom=1.25,layers=details))
    del inputs
    result = dict(checkpoint_sha256=sha(args.training/'model.pt'),model_sha256=config['model_sha256'],
                  quantization='W8A12, INT16 DDR containers, final logits INT16',
                  classifier_threshold=saved['threshold'],temperature=saved['temperature'],
                  fpga_deployed=False,board_verified=False)
    test_hw = None
    for split in ('validation','test'):
        selected = ids[split]
        selected_rows = [rows[i] for i in selected.tolist()]
        hw = hardware_images(selected_rows)
        if split == 'test':
            test_hw = hw
        result[split] = {}
        for name,images in [('original',pixels[selected]),('hardware_resize',hw)]:
            fp = torch.cat([model(normalize(b)) for b in images.split(16)])
            q = torch.cat([integer_run(ops,b).flatten(1) for b in images.split(8)])
            pred,display,_ = decisions(q,lut,saved['threshold'])
            previous = json.loads((args.training/'evaluation.json').read_text())[split][name]
            assert int((fp.argmax(1)==labels[selected]).sum()) == previous['correct']
            result[split][name] = dict(float=summarize(fp.argmax(1),labels[selected],classes),
                                      quantized=summarize(pred,labels[selected],classes,display),
                                      float_quant_top1_agreement=int((pred==fp.argmax(1)).sum()))
            print(split,name,json.dumps(result[split][name]),flush=True)
    save_json(out/'evaluation.json',result)
    cases = []
    test_rows = [rows[i] for i in ids['test'].tolist()]
    for c in range(5):
        # Deterministic fixtures, not selected by model predictions.
        i = next(i for i,r in enumerate(test_rows) if r['target']==c)
        with Image.open(test_rows[i]['path']) as im:
            roi = ImageOps.pad(ImageOps.exif_transpose(im).convert('RGB'),(480,480),
                               method=Image.Resampling.BILINEAR,color=tuple(PREPROCESS['fill']))
        raster = np.full((720,1280,3),PREPROCESS['fill'],dtype=np.uint8)
        raster[120:600,400:880] = np.asarray(roi)
        data = raster.tobytes()
        (out/f'snapshot_{c}.hex').write_text(''.join(data[j:j+16].hex()+'\n' for j in range(0,len(data),16)))
        values = integer_run(ops,test_hw[i:i+1],collect=True)
        write_hex(out/f'input_{c}.hex',feature_bytes(values[0]))
        for j,op in enumerate(ops):
            write_hex(out/f'case_{c}_op_{op["index"]}.hex',feature_bytes(values[j+1].reshape(1,*op['output_shape'])))
        q = values[-1].flatten(1)
        _,display,_ = decisions(q,lut,saved['threshold'])
        crop = test_hw[i].permute(1,2,0).numpy()
        cases.append(dict(case=c,path=test_rows[i]['path'],truth=c,
                          logits=q[0].long().tolist(),expected_class=int(display[0]),texture=texture_gate(crop)))
    decoder_cases = []
    vectors = [[0]*5,[-32768]*5,[32767]*5]
    for c in range(5):
        v = [-32768]*5;v[c] = 32767;vectors.append(v)
    vectors += np.random.default_rng(20261024).integers(-32768,32768,size=(100,5)).tolist()
    boundary = next((d for d in range(0,32768,32) if 4*lut[min(d>>5,511)]<=config['confidence_exp_sum_max']),32736)
    for c in range(5):
        for margin in (max(0,boundary-1),boundary,min(32767,boundary+1)):
            v = [-margin]*5;v[c] = 0;vectors.append(v)
    for v in vectors:
        _,display,sums = decisions(torch.tensor([v]),lut,saved['threshold'])
        decoder_cases.append(dict(logits=v,expected=int(display[0]),exp_sum=sums[0]))
    save_json(out/'simulation_cases.json',dict(pipeline=cases,decoder=decoder_cases))
    print('FRUIT128_QUANTIZATION_COMPLETE '+str(out),flush=True)


if __name__ == '__main__':
    main()
