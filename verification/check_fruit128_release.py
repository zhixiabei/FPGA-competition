"""Verify RGB128 numerical fixtures, frozen RTL and routed resource limits."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib

import torch
from fruitcnn128 import ARCHITECTURE, normalize
from handcnn_training_utils import sha, save_json


def read_log(path):
    data = path.read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8',errors='replace')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project',type=Path,required=True)
    p.add_argument('--physical',action='store_true')
    args = p.parse_args()
    project = args.project.resolve()
    candidate = json.loads((project/'candidate_config.json').read_text())
    model = Path(candidate['model_directory'])
    config = json.loads((model/'model.json').read_text())
    assert config['architecture'] == ARCHITECTURE
    assert len(config['classes']) == len(set(config['classes'])) == 5
    assert config['classes'] == candidate['classes']
    assert config['display_labels'] == candidate['display_labels']
    checkpoint = torch.load(Path(config['training_directory'])/'model.pt', map_location='cpu', weights_only=True)
    assert checkpoint['classes'] == config['classes']
    display = (project/'sources/user_source/hdl_source/hdmi_mixer.v').read_text()
    for index,label in enumerate(config['display_labels'], 2):
        assert len(label) == 7 and label.isascii()
        assert f"3'd{index}: S_cnn_char=F_fruit_char(56'h{label.encode('ascii').hex()}," in display
    assert config['activation_precision_bits'] == candidate['activation_precision_bits'] == 12
    assert config['preprocess']['size'] == candidate['input_size'] == 128
    assert config['cache_bits']*config['cache_words']//8 == candidate['cache_bytes'] == 73728
    assert candidate['max_slices'] == 19094
    assert config['classifier_sha256'] == sha(Path(config['training_directory'])/'model.pt')
    data = (model/'model.bin').read_bytes()
    assert sha(model/'model.bin') == candidate['model_sha256'] == config['model_sha256']
    assert len(data) == config['model_bytes'] == candidate['model_bytes']
    assert f'{zlib.crc32(data):08x}' == config['crc32']
    checked = 0
    program = (project/'sources/candidate/handfixed_program.v').read_text()
    for op in config['operations']:
        assert op['cin']*op['src_plane']//8 <= 6144
        for g,(w,c) in enumerate(op['groups']):
            d = struct.pack('<6BHH4BHH4I',op['kind'],int(op['relu']),op['kernel'],op['stride'],op['padding'],0,
                            op['cin'],op['cout'],op['iw'],op['ih'],op['ow'],op['oh'],op['src_plane'],op['dst_plane'],
                            op['src'],op['dst'],w,c)
            d += struct.pack('<HHHI',op['cin']*op['src_plane']//8,op['cin']*op['kernel']**2,
                             op['ow']*op['oh'],op['dst']+g*24*op['dst_plane']*2)
            d += bytes(48-len(d))
            assert f"3'd{g}:descriptor=384'h{d[::-1].hex()};" in program
            if op['kind']:
                continue
            w -= 0xc00000;c -= 0xc00000
            for lane in range(min(24,op['cout']-g*24)):
                oc = g*24+lane
                for term,value in enumerate(op['weights'][oc]):
                    assert data[w+term*32+lane] == value&255
                    checked += 1
                assert int.from_bytes(data[c+lane*8:c+lane*8+5],'little',signed=True) == op['biases'][oc]
                assert data[c+lane*8+5] == op['shifts'][oc]
    rom = (project/'sources/candidate/handcnn_normalize.v').read_text()
    entries = {int(a):int(b,16) for a,b in re.findall(r"11'd(\d+):value=16'h([0-9a-f]+)",rom)}
    pixels = torch.arange(256,dtype=torch.uint8)[None,None,None,:].expand(1,3,1,256)
    expected = torch.round(normalize(pixels)*512).long()[0,:,0]
    for c in range(3):
        for v in range(256):
            assert entries[1024+c*256+v] == int(expected[c,v])&65535
    for item in json.loads((project/'sources.json').read_text()):
        assert sha(Path(item['snapshot'])) == item['sha256'], item['snapshot']
    for item in json.loads((model/'rtl_under_test.json').read_text()):
        assert sha(Path(item['path'])) == item['sha256'], item['path']
    # The behavioral DSP used for the numeric test is frozen by the generator.
    inventory = json.loads((model/'sources.json').read_text())
    dsp = [r for r in inventory if Path(r['path']).name=='resnet18_dsp_reference.sv']
    assert len(dsp) == 1 and sha(Path(dsp[0]['path'])) == dsp[0]['sha256']
    cases = json.loads((model/'simulation_cases.json').read_text())
    text = read_log(model/'rtl_console.log')
    assert not re.search(r'\*\* (?:Error|Fatal):',text)
    assert text.count('FRUIT_LAYER_PASS ') == 50
    assert text.count('FRUIT_PIPELINE_CASE_PASS ') == 5
    assert f'FRUIT_DECODER_PASS cases={len(cases["decoder"])}' in text
    assert 'FRUIT_FILTER_PASS all_five' in text and 'FRUIT_RTL_PASS five_images' in text
    for name,marker in [('background','HANDFIXED_BACKGROUND_PASS'),('key','HANDFIXED_KEY_CONTROL_PASS'),('system','FRUIT_SYSTEM_PASS')]:
        text = read_log(model/f'{name}_simulation.log')
        assert marker in text and not re.search(r'\*\* (?:Error|Fatal):',text),name
    report = dict(status='passed',architecture=ARCHITECTURE,model_sha256=config['model_sha256'],
                  checkpoint_sha256=config['classifier_sha256'],model_bytes=len(data),weight_bytes_verified=checked,
                  rtl_images=5,rtl_layer_checks=50,decoder_cases=len(cases['decoder']),
                  normalization_entries=768,background='passed',key4='passed',system_status='passed',
                  fpga_resource_verified=False,board_programmed=False,real_camera_accuracy_measured=False,
                  scope='Numeric RTL tests use a behavioral MAC; physical timing/resources checked separately.')
    if args.physical:
        release = Path(__file__).resolve().parents[1]/'td_project/anlogic_edge_osd_Runs/best_result'
        physical = project/'handfixed_candidate_Runs/best_result'
        area = (physical/'handfixed_candidate_phy.area').read_text()
        resources = {}
        for name,limit in [('slice',19094),('eram',108),('dsp',40)]:
            match = re.search(r'#'+name+r'\s+(\d+)\s+out of\s+(\d+)',area)
            assert match, name
            used,total = map(int,match.groups())
            assert used <= limit, (name,used,limit)
            resources[name] = dict(used=used,total=total,percent=100*used/total)
        timing = (physical/'handfixed_candidate_pr.timing').read_text()
        slacks = {}
        for name in ('SWNS','HWNS','STNS','HTNS'):
            match = re.search(r'\b'+name+r':\s*(-?[0-9.]+)ns',timing)
            assert match, name
            slacks[name] = float(match[1])
            assert slacks[name] >= 0, (name,slacks[name])
        health = (physical/'handfixed_candidate_constraints.timing').read_text()
        assert 'There are 0 invalid constraints.' in health
        assert 'There are 0 constraints that have no timing paths.' in health
        bit = release/'fruitfixed_candidate.bit'
        assert bit.is_file() and bit.stat().st_size > 0
        report.update(fpga_resource_verified=True,resources=resources,timing_ns=slacks,
                      bitstream=str(bit),bitstream_bytes=bit.stat().st_size,bitstream_sha256=sha(bit))
    save_json(project/'release_verification.json',report)
    print(json.dumps(report,indent=2))


if __name__ == '__main__':
    main()
