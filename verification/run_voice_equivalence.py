"""Compare optimized voice RTL against the pre-optimization Git revision."""
import argparse
from pathlib import Path
import re
import subprocess

from run_voice_resource_check import BASELINE, ROOT, git_file


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modelsim', type=Path, default=Path('E:/modelsim/modelsim_ase/win32aloem'))
    args = parser.parse_args()
    out = ROOT / 'build/voice_equivalence'
    out.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / 'user_source/hdl_source/resnet18/resnet18_uart.v']
    voices = sorted((ROOT / 'user_source/hdl_source/voice').glob('*.v'))
    names = [path.stem for path in voices]
    pattern = re.compile(r'\b(' + '|'.join(names) + r')\b')
    for path in voices:
        reference = pattern.sub(lambda m: m[0] + '_reference',
                                git_file(path.relative_to(ROOT).as_posix()).decode('utf-8-sig'))
        target = out / (path.stem + '_reference.v')
        target.write_text(reference, encoding='utf-8')
        sources += [path, target]
    sources += [ROOT / 'sim/tb_voice_equivalence.sv']
    commands = ['onerror {quit -code 1 -force}', 'onbreak {resume}', 'vlib work',
                'vlog -sv -work work ' + ' '.join('{' + p.as_posix() + '}' for p in sources)]
    for top in ('tb_voice_phrase_equivalence', 'tb_voice_control_equivalence',
                'tb_voice_transport_equivalence'):
        commands += [f'vsim -novopt -onfinish stop -t ps work.{top}', 'run -all', 'quit -sim']
    commands += ['quit -code 0 -force']
    (out / 'run.tcl').write_text('\n'.join(commands) + '\n', encoding='utf-8')
    with (out / 'process.log').open('w') as log:
        result = subprocess.run([str(args.modelsim / 'vsim.exe'), '-c', '-do', 'run.tcl',
                                 '-l', 'simulation.log'], cwd=out, stdout=log, stderr=subprocess.STDOUT)
    text = (out / 'simulation.log').read_text(errors='replace')
    markers = ['VOICE_PHRASE_EQUIVALENCE_PASS', 'VOICE_CONTROL_EQUIVALENCE_PASS',
               'VOICE_TRANSPORT_EQUIVALENCE_PASS']
    if result.returncode or '** Error:' in text or '** Fatal:' in text or not all(m in text for m in markers):
        raise RuntimeError(text[-8000:])
    print(f'VOICE_EQUIVALENCE_PASS reference={BASELINE}')
    for line in text.splitlines():
        if any(marker in line for marker in markers):
            print(line)
    print(out / 'simulation.log')


if __name__ == '__main__':
    main()
