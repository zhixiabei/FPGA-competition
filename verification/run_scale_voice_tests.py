"""Run serial-wire and stability regression without generating an FPGA bitstream."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modelsim', type=Path, default=Path('E:/modelsim/modelsim_ase/win32aloem'))
    args = parser.parse_args()
    out = ROOT / 'build/scale_voice_tests'
    out.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / 'user_source/hdl_source/resnet18/resnet18_uart.v']
    sources += sorted((ROOT / 'user_source/hdl_source/voice').glob('*.v'))
    sources += sorted((ROOT / 'user_source/hdl_source/checkout').glob('*.v'))
    # Compile the actual integrated top as well; its video/vendor instances
    # are not elaborated by these focused simulation tops.
    sources += [ROOT / 'user_source/hdl_source/design_top_wrapper.v']
    sources += [ROOT / 'sim' / p for p in ('tb_scale_voice.sv', 'tb_five_class_checkout.sv', 'tb_checkout_voice_link.sv')]
    commands = ['onerror {quit -code 1 -force}', 'onbreak {resume}',
                'vlib work', 'vlog -sv -work work ' + ' '.join('{' + p.as_posix() + '}' for p in sources)]
    for top in ('tb_five_class_checkout', 'tb_scale_voice', 'tb_checkout_voice_link'):
        commands += [f'vsim -novopt -onfinish stop -t ps work.{top}', 'run -all', 'quit -sim']
    commands += ['quit -code 0 -force']
    (out / 'run.tcl').write_text('\n'.join(commands) + '\n', encoding='utf-8')
    with (out / 'process.log').open('w') as log:
        result = subprocess.run([str(args.modelsim / 'vsim.exe'), '-c', '-do', 'run.tcl', '-l', 'simulation.log'],
                                cwd=out, stdout=log, stderr=subprocess.STDOUT)
    text = (out / 'simulation.log').read_text(errors='replace')
    if result.returncode or '** Error:' in text or '** Fatal:' in text:
        raise RuntimeError(text[-6000:])
    for marker in ('FIVE_CLASS_CHECKOUT_PASS', 'SCALE_VOICE_PASS', 'CHECKOUT_VOICE_LINK_PASS'):
        assert marker in text, text[-6000:]
    print('SCALE_VOICE_TESTS_PASS checkout five-prices 105-phrases stability serial-wire playback-timeout checkout-link')
    print(out / 'simulation.log')


if __name__ == '__main__':
    main()
