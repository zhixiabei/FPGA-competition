"""Freeze the RGB128 W8A12 project without modifying the retained RGB96 design."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
import re

from prepare_fruitfixed_project import project_file, replace_once, snapshot

ROOT = Path(__file__).resolve().parents[1]


def core128(text):
    text = replace_once(text,'module handcnn_core(','module fruitcnn128_core(')
    text = replace_once(text,'reg [127:0] input_cache[0:4607]','reg [95:0] input_cache[0:6143]')
    text = replace_once(text,'reg [127:0] first_weight_word,input_q;',
                        'reg [127:0] first_weight_word;\n    reg [95:0] input_q;')
    text = replace_once(text,"input_q[pipe_offset*16+:16]",
                        "{{4{input_q[pipe_offset*12+11]}},input_q[pipe_offset*12+:12]}")
    packed = ','.join(f'mem_rsp_data[{i*16}+:12]' for i in reversed(range(8)))
    text = replace_once(text,'input_cache[received]<=mem_rsp_data;',f'input_cache[received]<={{{packed}}};')
    text = replace_once(text,"pool_y={6'd0,pool_channel[1],1'b0}+pool_channel[1]+ky;",
                        "pool_y={5'd0,pool_channel[1],2'd0}+ky;")
    text = replace_once(text,"pool_x={6'd0,pool_channel[0],1'b0}+pool_channel[0]+kx;",
                        "pool_x={5'd0,pool_channel[0],2'd0}+kx;")
    text = replace_once(text,"row_offset(pool_y,8'd6)","row_offset(pool_y,8'd8)")
    text = replace_once(text,"input_q[pool_byte*16+:16]",
                        "{{4{input_q[pool_byte*12+11]}},input_q[pool_byte*12+:12]}")
    text = replace_once(text,"scaled>32767 ? 16'h7fff : scaled< -32768 ? 16'h8000 : scaled[15:0]",
                        "relu && scaled>2047 ? 16'd2047 : scaled>32767 ? 16'h7fff : scaled< -32768 ? 16'h8000 : scaled[15:0]")
    text = replace_once(text,'input_words>4608','input_words>6144')
    text = replace_once(text,'if(kx==2 && ky==2)','if(kx==3 && ky==3)')
    text = replace_once(text,'if(kx==2) begin','if(kx==3) begin')
    old = '''                        // Restoring constant division replaces a long reciprocal
                        // multiply path; 19 clocks cost <0.12 ms per full pool.
                        divide_n<=pool_total<0 ? -pool_total : pool_total;
                        divide_negative<=pool_total<0;divide_q<=0;divide_rem<=0;divide_step<=0;
                        write_address<=dst+{18'd0,pool_channel,4'd0};state<=POOL_DIVIDE;'''
    new = '''                        // Exact floor(sum/16), matching the 8x8 -> 2x2 pool.
                        store_word<={112'd0,pool_total[19:4]};
                        write_address<=dst+{18'd0,pool_channel,4'd0};state<=POOL_WRITE;'''
    text = replace_once(text,old,new)
    text = '// RGB128: 6144 x 96-bit cache = 72 KiB, signed A12, INT16 DDR.\n'+text
    return text


def preprocess128(text):
    text = replace_once(text,'assign green_row_end=ox==95;','assign green_row_end=ox==127;')
    text = replace_once(text,"wire [7:0] width=mode ? 8'd96 : 8'd128;","wire [7:0] width=8'd128;")
    text = replace_once(text,"wire [7:0] height=8'd96;","wire [7:0] height=mode ? 8'd128 : 8'd96;")
    text = replace_once(text,"16'd18432 : 16'd36864","16'd32768 : 16'd65536")
    # 65536 needs 17 bits; detector offsets are still supported but pruned here.
    text = replace_once(text,'wire [15:0] plane_offset=','wire [16:0] plane_offset=')
    text = text.replace("16'd32768 : 16'd65536","17'd32768 : 17'd65536")
    text = replace_once(text,'({16\'d0,roi_side}<<16)/96','({16\'d0,roi_side}<<16)/128')
    old = "({16'd0,roi_side}<<16)/192"
    assert text.count(old) == 4
    text = text.replace(old,"({16'd0,roi_side}<<16)/256")
    return '// RGB128 classifier preprocessing, Q9 normalization ROM.\n'+text


def background128(text):
    # 128/4 = 32 samples per dimension, preserving the 32x32 reference RAM.
    text = replace_once(text,'sy<=sy==2 ? 0 : sy+1\'b1','sy<=sy+1\'b1')
    text = replace_once(text,'sx<=sx==2 ? 0 : sx+1\'b1','sx<=sx+1\'b1')
    return '// RGB128 stream: select every fourth pixel and row.\n'+text


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    args = p.parse_args()
    model,out = args.model.resolve(),args.output.resolve()
    config = json.loads((model/'model.json').read_text())
    assert config['activation_precision_bits'] == 12 and config['preprocess']['size'] == 128
    subprocess.run([sys.executable,str(ROOT/'verification/prepare_fruitfixed_project.py'),
                    '--model',str(model),'--output',str(out)],check=True)
    inventory_path = out/'sources.json'
    inventory = json.loads(inventory_path.read_text())
    project_path = out/'handfixed_candidate.al'
    project = project_path.read_text()
    section = re.search(r'<Source_Files>.*?</Source_Files>',project,re.S)
    xml = ET.fromstring(section.group().replace('P&R','P_R'))
    changes = [('handcnn/handcnn_core.v','fruitcnn128_core.v',core128),
               ('handfixed/handfixed_preprocess.v','handfixed_preprocess.v',preprocess128),
               ('handfixed/handfixed_background.v','handfixed_background.v',background128)]
    for relative,name,convert in changes:
        source = ROOT/'user_source/hdl_source'/relative
        target = out/'sources/candidate'/name
        old = project_file(xml,Path(relative).name)
        old_path = Path(old.attrib['Path'])
        inventory = [row for row in inventory if Path(row['snapshot']) != old_path]
        snapshot(target,convert(source.read_text(encoding='utf-8')),inventory,source)
        old.attrib['Path'] = target.as_posix()
    source = model/'handcnn_normalize.v'
    target = out/'sources/candidate/handcnn_normalize.v'
    old = project_file(xml,'handcnn_normalize.v')
    inventory = [r for r in inventory if Path(r['snapshot']) != Path(old.attrib['Path'])]
    snapshot(target,source.read_text(),inventory,source)
    old.attrib['Path'] = target.as_posix()
    system = out/'sources/candidate/fruitfixed_system.v'
    snapshot(system,replace_once(system.read_text(),'handcnn_core core(','fruitcnn128_core core('),
             inventory,ROOT/'user_source/hdl_source/handfixed/handfixed_system.v')
    updated = ET.tostring(xml,encoding='unicode').replace('P_R','P&R').replace('&amp;','&')
    project_path.write_text(project[:section.start()]+updated+project[section.end():])
    inventory_path.write_text(json.dumps(inventory,indent=2))
    candidate = json.loads((out/'candidate_config.json').read_text())
    candidate.update(input_size=128,activation_precision_bits=12,activation_container_bits=16,
                     cache_bytes=73728,max_slices=19094,max_slice_percent=90,
                     generator_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (out/'candidate_config.json').write_text(json.dumps(candidate,indent=2))
    print('FRUIT128_PROJECT_READY '+str(out))


if __name__ == '__main__':
    main()
