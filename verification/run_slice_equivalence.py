"""Cycle comparisons against the immutable, voice-optimized Slice baseline."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'build/slice_optimization/baseline/input'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trial')
    parser.add_argument('--modelsim', type=Path,
                        default=Path('E:/modelsim/modelsim_ase/win32aloem'))
    parser.add_argument('--suite', choices=('normalize', 'single_shape'), default='normalize')
    parser.add_argument('--timeout-seconds', type=int, default=1800,
                        help='Wall-clock limit; the full vendor-RAM 720p suite needs several minutes')
    parser.add_argument('--td-sim-lib', type=Path,
                        default=Path('E:/TD_6.2.1_Engineer_6.2.168.116/sim_release/ph1p'))
    args = parser.parse_args()
    if args.timeout_seconds <= 0:
        raise ValueError('The simulation timeout must be positive')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.trial):
        raise ValueError('Invalid trial name')
    out = ROOT / 'build/slice_optimization/verification' / args.trial
    out.mkdir(parents=True, exist_ok=False)
    sources = []
    hashes = {}
    for relative in (() if args.suite == 'single_shape' else ('fruit_merged/handcnn_normalize.v',)):
        path = Path('user_source/hdl_source') / relative
        for suffix, folder in (('', ROOT), ('_reference', BASE)):
            raw = (folder / path).read_bytes()
            hashes[str(path) + suffix] = hashlib.sha256(raw).hexdigest()
            data = raw.decode('utf-8-sig')
            data = re.sub(r'\bhandcnn_normalize\b', 'handcnn_normalize' + suffix, data)
            target = out / ('handcnn_normalize' + suffix + '.v')
            target.write_bytes(data.encode('utf-8'))
            sources.append(target)
    bench = ROOT / 'sim/tb_slice_normalize_equivalence.sv'
    top = 'work.tb_slice_normalize_equivalence'
    marker = 'SLICE_NORMALIZE_EQUIVALENCE_PASS'
    if args.suite == 'single_shape':
        sources = [ROOT / 'user_source/hdl_source/isp/red_target_detect_96.v',
                   ROOT / 'sim/tb_single_color_shape.sv']
        sources += [args.td_sim_lib / name for name in ('ph1p_logic_eram.v', 'ph1p_phy_gsr.v')]
        top = '-gW=1280 -gH=720 work.tb_single_color_shape work.PH1P_PHY_GSR'
        marker = 'SINGLE_COLOR_SHAPE_PASS'
    else:
        sources.append(bench)
    frozen_sources = []
    for source in sources:
        target = out / source.name
        if source != target:
            raw = source.read_bytes()
            target.write_bytes(raw)
            hashes[str(source)] = hashlib.sha256(raw).hexdigest()
        frozen_sources.append(target)
    commands = ['onerror {quit -code 1 -force}', 'onbreak {resume}',
                'vlib work', 'vlog -sv ' + ' '.join('{' + p.as_posix() + '}' for p in frozen_sources),
                'vsim -onfinish stop -t ps ' + top,
                'run -all', 'quit -code 0 -force']
    (out / 'run.do').write_text('\n'.join(commands) + '\n', encoding='utf-8')
    (out / 'source_sha256.json').write_text(json.dumps(hashes, indent=2), encoding='utf-8')
    with (out / 'process.log').open('w') as stream:
        result = subprocess.run([str(args.modelsim / 'vsim.exe'), '-c', '-do', 'run.do',
                                 '-l', 'simulation.log'], cwd=out, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=args.timeout_seconds)
    log = (out / 'simulation.log').read_text(errors='replace')
    if result.returncode or '** Error:' in log or '** Fatal:' in log or \
            marker not in log:
        raise RuntimeError(log[-8000:])
    print(log[log.index('# ' + marker):].splitlines()[0])
    print(out)


if __name__ == '__main__':
    main()
