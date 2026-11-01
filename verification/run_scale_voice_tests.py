"""Run serial-wire and stability regression without generating an FPGA bitstream."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modelsim', type=Path, default=Path('C:/altera/14.1/modelsim_ase/win32aloem'))
    args = parser.parse_args()
    out = ROOT / 'build/scale_voice_tests'
    out.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / 'user_source/hdl_source/resnet18/resnet18_uart.v']
    sources += sorted((ROOT / 'user_source/hdl_source/voice').glob('*.v'))
    sources += sorted((ROOT / 'user_source/hdl_source/checkout').glob('*.v'))
    # Compile the actual integrated top as well; its video/vendor instances
    # are not elaborated by these focused simulation tops.
    sources += [ROOT / 'user_source/hdl_source/design_top_wrapper.v']
    tops = ('tb_five_class_checkout', 'tb_scale_voice', 'tb_checkout_voice_link',
            'tb_voice_phrase_widths', 'tb_cx_sp5t_uart')
    sources += [ROOT / 'sim' / (top + '.sv') for top in tops]
    commands = ['onerror {quit -code 1 -force}', 'onbreak {resume}',
                'vlib work', 'vlog -sv -work work ' + ' '.join('{' + p.as_posix() + '}' for p in sources)]
    for top in tops:
        commands += [f'vsim -novopt -onfinish stop -t ps work.{top}', 'run -all', 'quit -sim']
    commands += ['quit -code 0 -force']
    (out / 'run.tcl').write_text('\n'.join(commands) + '\n', encoding='utf-8')
    with (out / 'process.log').open('w') as log:
        result = subprocess.run([str(args.modelsim / 'vsim.exe'), '-c', '-do', 'run.tcl', '-l', 'simulation.log'],
                                cwd=out, stdout=log, stderr=subprocess.STDOUT)
    text = (out / 'simulation.log').read_text(errors='replace')
    if result.returncode or '** Error:' in text or '** Fatal:' in text:
        raise RuntimeError(text[-6000:])
    for marker in ('FIVE_CLASS_CHECKOUT_PASS', 'SCALE_VOICE_PASS', 'CHECKOUT_VOICE_LINK_PASS',
                   'VOICE_PHRASE_WIDTHS_PASS', 'CX_SP5T_UART_PASS'):
        assert marker in text, text[-6000:]
    print('SCALE_VOICE_TESTS_PASS checkout five-prices 105-phrases stability serial-wire playback-timeout checkout-link phrase-widths transport-boundaries')
    print(out / 'simulation.log')


if __name__ == '__main__':
    main()
