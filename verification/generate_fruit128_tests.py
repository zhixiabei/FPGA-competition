"""Adapt the retained randomized-memory full-pipeline test to frozen RGB128 RTL."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from prepare_fruitfixed_project import replace_once

ROOT = Path(__file__).resolve().parents[1]


def control_fixtures(model,project):
    text = (ROOT/'sim/tb_handfixed_background.sv').read_text()
    text = text.replace('y<96','y<128').replace('x<96','x<128')
    text = text.replace('(y/3)*32+x/3','(y/4)*32+x/4').replace('y==48','y==64').replace('x==95','x==127')
    (model/'tb_background128.sv').write_text(text)
    lib = Path('E:/TD_6.2.1_Engineer_6.2.168.116/sim_release/ph1p')
    for name,tb,tbfile in [('background','tb_handfixed_background',model/'tb_background128.sv'),
                           ('key','tb_handfixed_key_control',ROOT/'sim/tb_handfixed_key_control.sv'),
                           ('system','tb_fruitfixed_system',ROOT/'sim/tb_fruitfixed_system.sv')]:
        work = 'fruit128_'+name+'_work'
        files = [lib/x for x in ['ph1p_logic_dram.v','ph1p_logic_dram64x8.v','ph1p_phy_mslice.v',
                                 'ph1p_phy_dramhardcon.v','ph1p_phy_gsr.v','ph1p_logic_eram.v']]
        files += [ROOT/x for x in ['sim/resnet18_dsp_reference.sv',
                                   'user_source/hdl_source/cnn/cnn_eram_byte_dp.v',
                                   'user_source/hdl_source/resnet18/resnet18_uart.v',
                                   'user_source/hdl_source/resnet18/resnet18_weight_loader.v',
                                   'user_source/hdl_source/handcnn/handcnn_snapshot.v']]
        files += list((project/'sources/candidate').glob('*.v'))+[tbfile]
        text = 'onerror {quit -code 1 -force}\nonbreak {quit -code 1 -force}\n'
        text += f'vlib {work}\nvlog -work {work} -sv '+' '.join('{'+x.as_posix()+'}' for x in files)+'\n'
        text += f'vsim -onfinish exit -t ps {work}.{tb} {work}.PH1P_PHY_GSR\nrun -all\nquit -code 0 -force\n'
        (model/f'run_{name}.tcl').write_text(text)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,required=True)
    p.add_argument('--project',type=Path,required=True)
    args = p.parse_args()
    model,project = args.model.resolve(),args.project.resolve()
    subprocess.run([sys.executable,str(ROOT/'verification/generate_fruitfixed_tests.py'),
                    '--model',str(model)],check=True)
    path = model/'tb_fruitfixed.sv'
    text = path.read_text()
    text = replace_once(text,'expected[0:4607]','expected[0:6143]')
    text = replace_once(text,'handcnn_core core(','fruitcnn128_core core(')
    assert text.count('expected,0,3455') == 5 and text.count('3456,') == 5
    text = text.replace('expected,0,3455','expected,0,6143').replace('3456,','6144,')
    text = replace_once(text,'ticks>30000000','ticks>100000000')
    path.write_text(text)
    path = model/'run_simulation.tcl'
    text = path.read_text()
    for old,new in [('handcnn/handcnn_core.v','fruitcnn128_core.v'),
                    ('handcnn/handcnn_normalize.v','handcnn_normalize.v'),
                    ('handfixed/handfixed_preprocess.v','handfixed_preprocess.v')]:
        text = replace_once(text,'../../user_source/hdl_source/'+old,
                            '{'+(project/'sources/candidate'/new).as_posix()+'}')
    text = text.replace('../../', ROOT.as_posix()+'/')
    path.write_text(text)
    inventory = []
    for file in (project/'sources/candidate').glob('*.v'):
        inventory.append(dict(path=str(file),sha256=hashlib.sha256(file.read_bytes()).hexdigest()))
    (model/'rtl_under_test.json').write_text(json.dumps(inventory,indent=2))
    control_fixtures(model,project)
    print('FRUIT128_RTL_FIXTURES_READY '+str(model))


if __name__ == '__main__':
    main()
