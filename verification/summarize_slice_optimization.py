"""Audit the selected RTL and compare the frozen Slice implementation trials."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re

from run_slice_route_check import check_constraint_health

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/slice_optimization'
TRIALS = ('baseline', 'eram_weights_norm', 'eram_shape_static',
          'eram_shape_center', 'eram_shape_center_bcd', 'eram_shape_bcd')


def area(path, gate=False):
    text = path.read_text()
    keys = {'slice': 'slice*' if gate else 'slice', 'lut6': 'lut6',
            'reg': 'reg', 'eram': 'eram', 'dsp': 'dsp'}
    result = {}
    for name, key in keys.items():
        match = re.search(r'^\s*#' + re.escape(key) + r'\s+(\d+)', text, re.M)
        if not match:
            raise RuntimeError(f'Missing {key}: {path}')
        result[name] = int(match[1])
    return result


def project_config(text):
    # TD's AL format resembles XML but contains non-XML names and ampersands.
    return re.sub(r'(<Project\b[^>]*\bPath=)"[^"]*"', r'\1"WORKSPACE"', text)


def require_marker(folder, filename, marker):
    text = (folder / filename).read_text(errors='replace')
    if marker not in text or re.search(r'\*\* (?:Fatal|Error):', text):
        raise RuntimeError('Incomplete simulation: ' + str(folder))
    return str((folder / filename).relative_to(ROOT))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selected', choices=('eram_weights_norm', 'eram_shape_static'),
                        required=True)
    args = parser.parse_args()
    trials = {}
    for name in TRIALS:
        folder = OUT / name
        record = {'gate_estimate': area(folder / 'system_gate.area', gate=True)}
        route = folder / 'route'
        if (route / 'place.qor').exists():
            qor = (route / 'place.qor').read_text()
            record['placement'] = dict(slice=int(re.search(r'#slices\s*\|\s*(\d+)', qor)[1]))
        if (route / 'summary.json').exists():
            physical = json.loads((route / 'summary.json').read_text())
            if not physical.get('route_completed'):
                if name != 'baseline':
                    raise RuntimeError('Route incomplete: ' + name)
                record['route_status'] = physical
            else:
                physical.update(area(route / 'system_phy.area'))
                physical['cdc_constraints'] = check_constraint_health(
                    route / 'constraint_health.timing',
                    folder / 'input/td_project/anlogic_edge_osd.sdc')
                physical['constraint_health_passed'] = True
                record['physical'] = physical
        trials[name] = record
    selected = trials[args.selected]['physical']
    baseline = trials['baseline'].get('physical')
    baseline_placement = trials['baseline']['placement']['slice']
    selected_placement = trials[args.selected]['placement']['slice']
    eligible = {name: item['physical'] for name, item in trials.items()
                if name != 'baseline' and 'physical' in item
                and item['physical']['timing_passed']}
    if (not selected['timing_passed'] or selected_placement >= baseline_placement
            or selected['slice'] != min(item['slice'] for item in eligible.values())):
        raise RuntimeError('Select the smallest candidate that passes timing and saves Slice')
    for resource, capacity in dict(slice=21216, lut6=21216, reg=42432, eram=108, dsp=40).items():
        if selected[resource] > capacity:
            raise RuntimeError('Selected candidate exceeds device capacity: ' + resource)

    # Recheck every RTL, memory/init asset and constraint in the synthesis manifest.
    manifest = OUT / args.selected / 'source_sha256.csv'
    hashes = {}
    for row in csv.DictReader(manifest.open(encoding='utf-8-sig')):
        path = ROOT / row['Path']
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if row['Path'] == 'td_project/anlogic_edge_osd.al':
            frozen = OUT / args.selected / 'input' / row['Path']
            if project_config(path.read_text()) != project_config(frozen.read_text()):
                raise RuntimeError('Project configuration changed')
        elif row['Path'] == 'td_project/anlogic_edge_osd.sdc':
            frozen = OUT / args.selected / 'input' / row['Path']
            if path.read_text() != frozen.read_text():
                raise RuntimeError('Timing constraints changed')
        elif actual.upper() != row['Hash'].upper():
            raise RuntimeError('Production differs from selected input: ' + row['Path'])
        hashes[row['Path']] = actual
    project = ROOT / 'td_project/anlogic_edge_osd.al'
    references = re.findall(r'<File\s+Path="([^"]+)"', project.read_text())
    missing = [name for name in references if not (project.parent / name).is_file()]
    if missing:
        raise RuntimeError('Missing project references: ' + str(missing))

    verified = OUT / 'verification'
    evidence = {}
    for name, filename, marker in (
        ('cnn_vendor_numeric', 'console.log', 'FRUIT_CORE_NUMERIC_PASS cases=23'),
        ('eram_norm_final', 'simulation.log', 'SLICE_NORMALIZE_EQUIVALENCE_PASS'),
        ('voice_equivalence_final', 'simulation.log', 'VOICE_TRANSPORT_EQUIVALENCE_PASS'),
        ('scale_voice_tests_final', 'simulation.log', 'CHECKOUT_VOICE_LINK_PASS'),
    ):
        evidence[name] = require_marker(verified / name, filename, marker)
    for marker in ('VOICE_PHRASE_EQUIVALENCE_PASS', 'VOICE_CONTROL_EQUIVALENCE_PASS'):
        require_marker(verified / 'voice_equivalence_final', 'simulation.log', marker)
    for marker in ('FIVE_CLASS_CHECKOUT_PASS', 'SCALE_VOICE_PASS'):
        require_marker(verified / 'scale_voice_tests_final', 'simulation.log', marker)
    for name in ('voice_equivalence_final', 'scale_voice_tests_final'):
        for path in (ROOT / 'user_source/hdl_source/voice').glob('*.v'):
            if path.read_bytes() != (verified / name / path.name).read_bytes():
                raise RuntimeError('Final voice regression used different RTL: ' + path.name)
    core = ROOT / 'user_source/hdl_source/fruit_merged/fruitcnn128_core.v'
    if core.read_bytes() != (verified / 'cnn_vendor_numeric/fruitcnn128_core.v').read_bytes():
        raise RuntimeError('CNN numerical test used different RTL')
    if args.selected == 'eram_shape_static':
        for name, filename, marker in (
            ('shape_descriptor_equivalence', 'console.log', 'SHAPE_DESCRIPTOR_EQUIVALENCE_PASS'),
            ('single_shape_720p_complete', 'simulation.log', 'SINGLE_COLOR_SHAPE_PASS W=1280 H=720'),
        ):
            evidence[name] = require_marker(verified / name, filename, marker)
        shape = ROOT / 'user_source/hdl_source/isp/red_target_detect_96.v'
        module = re.search(r'\bmodule color_shape_descriptor\b.*?\bendmodule\b',
                           shape.read_text(), re.S).group()
        tested = (verified / 'shape_descriptor_equivalence/current.v').read_text(encoding='utf-8-sig')
        if module != tested:
            raise RuntimeError('Shape equivalence used different RTL')
        if shape.read_bytes() != (verified / 'single_shape_720p_complete' / shape.name).read_bytes():
            raise RuntimeError('720p simulation used different RTL')
    norm = ROOT / 'user_source/hdl_source/fruit_merged/handcnn_normalize.v'
    if norm.read_bytes() != (verified / 'eram_norm_final/handcnn_normalize.v').read_bytes():
        raise RuntimeError('Normalization test used different RTL')

    result = dict(selected=args.selected, trials=trials,
                  placement_slice_saved=baseline_placement - selected_placement,
                  placement_slice_reduction_percent=100 * (baseline_placement - selected_placement) / baseline_placement,
                  physical_slice_saved=baseline['slice'] - selected['slice'] if baseline else None,
                  physical_slice_reduction_percent=(100 * (baseline['slice'] - selected['slice']) / baseline['slice']) if baseline else None,
                  physical_slice_utilization_percent=100 * selected['slice'] / 21216,
                  advisory_target_slice=19000, advisory_target_met=selected['slice'] <= 19000,
                  project_references=len(references), missing_project_references=missing,
                  verified_production_inputs=len(hashes), bit_generated=False,
                  board_tested=False, evidence=evidence,
                  project_path_normalized_for_config_comparison=True,
                  sdc_line_endings_normalized_for_text_comparison=True)
    (OUT / 'final_source_sha256.json').write_text(json.dumps(hashes, indent=2), encoding='utf-8')
    (OUT / 'comparison.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
