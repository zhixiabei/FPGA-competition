"""Compare synthesis only using the same committed full-project configuration.

The local TD GUI project is never changed. No placement, routing or bitgen.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASELINE = '67e43ce9d8f7fa6565156a6d4afc0c8edeff1354'


def git_file(path):
    return subprocess.check_output(['git', 'show', f'{BASELINE}:{path}'], cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('variant', choices=('baseline', 'optimized'))
    parser.add_argument('--td-bin', default='E:/TD_6.2.1_Engineer_6.2.168.116/bin')
    args = parser.parse_args()
    out = ROOT / 'build/voice_resource_check' / args.variant
    stage = out / 'input'
    (stage / 'td_project').mkdir(parents=True, exist_ok=True)
    (stage / 'verification').mkdir(exist_ok=True)
    shutil.copytree(ROOT / 'user_source', stage / 'user_source', dirs_exist_ok=True)
    for name in ('anlogic_edge_osd.al', 'anlogic_edge_osd.sdc'):
        (stage / 'td_project' / name).write_bytes(git_file('td_project/' + name))
    if args.variant == 'baseline':
        for path in (ROOT / 'user_source/hdl_source/voice').glob('*.v'):
            relative = path.relative_to(ROOT)
            (stage / relative).write_bytes(git_file(relative.as_posix()))
    shutil.copy2(ROOT / 'verification/run_image_quality_build.ps1', stage / 'verification')
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
    for name in ('system_gate.area', 'system_gate.timing', 'system_rtl.area',
                 'source_sha256.csv', 'console.log', 'build.tcl'):
        shutil.copy2(snapshot / name, out / name)
    print(f'VOICE_RESOURCE_SYNTHESIS_PASS variant={args.variant} reports={out}')


if __name__ == '__main__':
    main()
