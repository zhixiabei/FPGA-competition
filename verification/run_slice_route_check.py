"""Route an existing immutable synthesis snapshot without generating a bitstream."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/slice_optimization'


def check_constraint_health(health_path, sdc_path):
    """Require the same CDC path coverage as the production build driver."""
    health = health_path.read_text()
    for marker in ('There are 0 invalid constraints.',
                   'There are 0 constraints that have no timing paths.'):
        if marker not in health:
            raise RuntimeError('Invalid or missing-path constraints: ' + str(health_path))
    rules = (
        ('display_effect', 'u_display_effect_cdc/payload_hold[*]',
         'u_display_effect_cdc/O_dst_data[*]', 13.0),
        ('frame_context', 'u_target_frame_bridge/S_start_nonce[*]',
         'u_target_frame_bridge/S_slot*', 20.0),
        ('detector_result', 'u_target_frame_bridge/S_result_payload[*]',
         'u_target_frame_bridge/S_last_result_payload[*]', 20.0),
        ('display_snapshot', 'u_target_frame_bridge/S_read_payload[*]',
         'u_target_frame_bridge/O_*', 13.0),
        ('ae_statistics', 'u_ae_stats_cdc/payload_hold[*]',
         'u_ae_stats_cdc/O_dst_data[*]', 20.0),
    )
    pattern = (r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+'
               r'set_max_delay\s+-datapath_only\b.*\s(\d+(?:\.\d+)?)\s*$')
    results = {}
    for name, source, target, limit in rules:
        rows = [line for line in health.splitlines() if source in line and target in line]
        match = re.fullmatch(pattern, rows[0]) if len(rows) == 1 else None
        if not match:
            raise RuntimeError('Missing or ambiguous CDC rule: ' + name)
        total, dominated, shadowed, ignored = map(int, match.groups()[:4])
        if not (total > 0 and dominated == total and shadowed == ignored == 0
                and float(match[5]) == limit):
            raise RuntimeError('Incomplete CDC coverage: ' + name)
        results[name] = dict(payload_paths=total, max_delay_ns=limit, status='passed')
    if any(re.match(r'^\s*set_false_path\b', line) and 'awb_hold' in line
           for line in sdc_path.read_text().splitlines()):
        raise RuntimeError('Unused compatibility-AWB hold exception remains')
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trial')
    parser.add_argument('--td-bin', type=Path,
                        default=Path('E:/TD_6.2.1_Engineer_6.2.168.116/bin'))
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.trial):
        raise ValueError('Invalid trial name')
    trial = OUT / args.trial
    pointer = (ROOT / 'build/voice_resource_check/optimized/snapshot.txt'
               if args.trial == 'baseline' else trial / 'snapshot.txt')
    snapshot = Path(pointer.read_text().strip())
    # Verify the snapshot, including its project and constraints, before
    # importing its database. Never route the live workspace/GUI project.
    with (trial / 'source_sha256.csv').open(encoding='utf-8-sig') as stream:
        for row in csv.DictReader(stream):
            actual = hashlib.sha256((snapshot / row['Path']).read_bytes()).hexdigest()
            if actual.upper() != row['Hash'].upper():
                raise RuntimeError('Snapshot changed: ' + row['Path'])
    assert (snapshot / 'system_gate.db').is_file(), snapshot
    route = trial / 'route'
    route.mkdir(exist_ok=False)
    script = (ROOT / 'verification/continue_slice_route.tcl').read_text()
    script = script.replace('    commit_param -step place',
                            '    set_param place seed 1\n    commit_param -step place')
    (route / 'route.tcl').write_text(script, encoding='utf-8')
    with (route / 'console.log').open('w') as stream:
        result = subprocess.run([str(args.td_bin / 'td_commands_prompt.exe'),
                                 (route / 'route.tcl').as_posix()], cwd=snapshot,
                                stdout=stream, stderr=subprocess.STDOUT)
    for name in ('place.qor', 'system_place.timing', 'system_pr.timing', 'system_phy.area',
                 'system_phy.ts', 'constraint_health.timing'):
        if (snapshot / name).is_file():
            shutil.copy2(snapshot / name, route / name)
    console = (route / 'console.log').read_text(errors='replace')
    summary = dict(trial=args.trial, snapshot=str(snapshot), seed=1,
                   tool_exit_code=result.returncode, bit_generated=False)
    if (route / 'system_phy.area').is_file():
        area = (route / 'system_phy.area').read_text()
        for resource in ('slice', 'lut6', 'reg', 'eram', 'dsp'):
            match = re.search(r'^#' + resource + r'\s+(\d+)', area, re.M)
            summary[resource] = int(match[1]) if match else None
    if (route / 'system_pr.timing').is_file():
        timing = (route / 'system_pr.timing').read_text()
        for resource in ('SWNS', 'HWNS'):
            match = re.search(resource + r':\s*(-?[\d.]+)ns', timing)
            summary[resource] = float(match[1]) if match else None
    route_pass = result.returncode == 0 and 'SLICE_CANDIDATE_ROUTE_PASS' in console
    summary['route_completed'] = route_pass
    summary['timing_passed'] = route_pass and all(
        summary.get(key) is not None and summary[key] >= 0 for key in ('SWNS', 'HWNS'))
    health_path = route / 'constraint_health.timing'
    if health_path.is_file():
        summary['cdc_constraints'] = check_constraint_health(
            health_path, snapshot / 'td_project/anlogic_edge_osd.sdc')
        summary['constraint_health_passed'] = True
    (route / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary, indent=2))
    if not summary['timing_passed'] or not summary.get('constraint_health_passed', False):
        raise RuntimeError('Physical validation did not pass: ' + str(route))


if __name__ == '__main__':
    main()
