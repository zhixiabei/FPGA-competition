"""Prepare standalone KEY4/background/full-system regression fixtures."""
import argparse
from pathlib import Path
import shutil
ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True,help='New direct subdirectory of build/gesture/')
    args=p.parse_args()
    out=args.output.resolve()
    if out.parent!=ROOT/'build/gesture': raise ValueError('Test directory must be directly under build/gesture/')
    out.mkdir(parents=True,exist_ok=False)
    for name in ['model.hex','handfixed_program.v','handfixed_config.v']:
        shutil.copyfile(ROOT/'build/gesture/weights'/name,out/name)
    shutil.copyfile(ROOT/'sim/handfixed_vectors/snapshot_punch.hex',out/'snapshot_punch.hex')
    for kind in ['system','refresh','key_control','background','result_filter']:
        shutil.copyfile(ROOT/f'sim/tb_handfixed_{kind}.sv',out/f'tb_handfixed_{kind}.sv')
    for kind in ['background','key']:
        shutil.copyfile(ROOT/f'verification/run_handfixed_{kind}_test.tcl',out/f'{kind}_test.tcl')
    raw=bytearray()
    for y in range(720):
        for x in range(1280):
            value=64+48*((x//40+y//40)%2)
            raw.extend([value]*3)
    (out/'snapshot_background.hex').write_text(''.join(raw[i:i+16].hex()+'\n' for i in range(0,len(raw),16)),encoding='ascii')
    print(out)

if __name__=='__main__': main()
