"""Freeze the voice-optimized baseline, then synthesize Slice trials only.

The TD GUI project and all programming files are left untouched.
"""
import argparse
import csv
import hashlib
from pathlib import Path
import re
import shutil
import subprocess

from run_voice_resource_check import ROOT, git_file

OUT = ROOT / 'build/slice_optimization'
REPORTS = ('system_gate.area', 'system_gate.timing', 'system_rtl.area',
           'source_sha256.csv', 'console.log', 'build.tcl')


def freeze():
    target = OUT / 'baseline'
    if target.exists():
        raise RuntimeError(f'Baseline already exists and is immutable: {target}')
    previous = ROOT / 'build/voice_resource_check/optimized'
    with (previous / 'source_sha256.csv').open(encoding='utf-8-sig') as stream:
        manifest = list(csv.DictReader(stream))
    for row in manifest:
        if row['Path'].startswith('user_source/'):
            actual = hashlib.sha256((ROOT / row['Path']).read_bytes()).hexdigest().upper()
            if actual != row['Hash']:
                raise RuntimeError(f'Freeze before changing RTL: {row["Path"]}')
    stage = target / 'input'
    shutil.copytree(ROOT / 'user_source', stage / 'user_source')
    (stage / 'td_project').mkdir()
    (stage / 'verification').mkdir()
    for name in ('anlogic_edge_osd.al', 'anlogic_edge_osd.sdc'):
        (stage / 'td_project' / name).write_bytes(git_file('td_project/' + name))
    shutil.copy2(ROOT / 'verification/run_image_quality_build.ps1', stage / 'verification')
    for name in REPORTS:
        shutil.copy2(previous / name, target / name)
    print(f'SLICE_BASELINE_FROZEN {target}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trial', help='freeze or a new trial name')
    parser.add_argument('--td-bin', default='E:/TD_6.2.1_Engineer_6.2.168.116/bin')
    args = parser.parse_args()
    if args.trial == 'freeze':
        freeze()
        return
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', args.trial) or args.trial == 'baseline':
        raise ValueError('Use a distinct trial name with letters, digits, underscores or hyphens')
    out = OUT / args.trial
    out.mkdir(parents=True, exist_ok=False)
    stage = out / 'input'
    shutil.copytree(ROOT / 'user_source', stage / 'user_source')
    for folder in ('td_project', 'verification'):
        shutil.copytree(OUT / 'baseline/input' / folder, stage / folder)
    command = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
               str(stage / 'verification/run_image_quality_build.ps1'),
               '-TdBin', args.td_bin, '-SkipRoute']
    with (out / 'driver.log').open('w', encoding='utf-8') as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    text = (out / 'driver.log').read_text(encoding='utf-8')
    print(text)
    if result.returncode or 'IMAGE_QUALITY_SYNTHESIS_PASS' not in text:
        raise RuntimeError(f'Synthesis failed: {out / "driver.log"}')
    snapshot = Path(re.search(r'Build output: (.+)', text).group(1).strip())
    (out / 'snapshot.txt').write_text(str(snapshot), encoding='utf-8')
    for name in REPORTS:
        shutil.copy2(snapshot / name, out / name)
    area = (out / 'system_gate.area').read_text()
    print(f'SLICE_SYNTHESIS_PASS trial={args.trial} slice_estimate=' +
          re.search(r'^#slice\*\s+(\d+)', area, re.M).group(1))


if __name__ == '__main__':
    main()
