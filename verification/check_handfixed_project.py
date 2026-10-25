"""Verify retained HandCNN artifacts, cleaned projects, simulation and routed reports."""
import argparse
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

import handfixed_validation as common

ROOT = common.ROOT
PROJECT = ROOT/'build/gesture/td'
CHECKS = ROOT/'build/gesture/checks'
AUDIT = ROOT/'build/gesture/audit'


def check_sources():
    original = json.loads((PROJECT/'verification.json').read_text(encoding='utf-8'))
    assert common.sha(AUDIT/'original_build_sources.json') == original['source_inventory_sha256']
    inventory = json.loads((PROJECT/'sources.json').read_text(encoding='utf-8'))
    for item in inventory:
        assert common.sha(Path(item['snapshot'])) == item['sha256'], item['snapshot']
        assert common.sha(Path(item['source'])) == item['sha256'], item['source']
    for path in [ROOT/'td_project/anlogic_edge_osd.al', ROOT/'td_project/anlogic_sc520_capture.al', PROJECT/'handfixed_candidate.al']:
        section = re.search(r'<Source_Files>.*?</Source_Files>', path.read_text(encoding='utf-8'), re.S).group()
        xml = ET.fromstring(section.replace('P&R', 'P_R'))
        for element in xml.iter('File'):
            source = Path(element.attrib['Path'])
            if not source.is_absolute(): source = path.parent/source
            assert source.exists(), source
    top = (ROOT/'user_source/hdl_source/design_top_wrapper.v').read_text(encoding='utf-8')
    assert '.KEY4_CONTROL(1),.BACKGROUND_CONTROL(1)' in top
    assert '.key4_n(I_param_key_n)' in top and 'resnet18_system' not in top
    return len(inventory)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--physical', action='store_true', help='Check original routed reports and immutable bit')
    p.add_argument('--checks', type=Path, default=CHECKS)
    args = p.parse_args()
    preserved = json.loads((AUDIT/'preserved_artifacts.json').read_text(encoding='utf-8'))
    for path, digest in preserved.items():
        assert common.sha(ROOT/path) == digest, path
    source_count = check_sources()
    model = ROOT/'build/gesture/weights/model.bin'
    config = json.loads(model.with_suffix('.json').read_text(encoding='utf-8'))
    assert common.sha(model) == config['model_sha256']
    assert config['classifier_threshold'] == .65 and model.stat().st_size == 233472
    markers = {
        'key': 'HANDFIXED_KEY_CONTROL_PASS',
        'refresh': 'HANDFIXED_REFRESH_PASS KEY4',
        'background': 'HANDFIXED_BACKGROUND_PASS no_reference identical noise23 delta24 enter64 exit32 stationary atomic_reference reset',
        'system': 'HANDFIXED_BACKGROUND_SYSTEM_PASS textured_empty stationary_hand removal_nothing paused_refresh model_preserved fixed480',
    }
    for name, marker in markers.items():
        log = common.read_log(args.checks/f'{name}_simulation.log')
        assert marker in log and not re.search(r'\*\* (?:Fatal|Error):', log), name
    common.CHECKS = args.checks
    status_cases = common.check_status()
    for ready in [0, 1]:
        result = common.subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            str(ROOT/'verification/read_handfixed_status.ps1'), '-ResponseFile',
            str(CHECKS/f'status_background_{ready}.bin')], capture_output=True, check=True)
        status = json.loads(result.stdout)
        assert status['background_control'] and status['background_ready'] == bool(ready)
        assert status['last_display'] == 'NOTHING'
    report = dict(status='pass', source_count=source_count, simulation=list(markers),
                  protocol_cases=status_cases+2, artifacts=preserved)
    if args.physical:
        phy = PROJECT/'handfixed_candidate_Runs/phy_1'
        timing = (phy/'handfixed_candidate_pr.timing').read_text(encoding='utf-8')
        for key in ['SWNS', 'HWNS', 'STNS', 'HTNS']:
            value = float(re.search(r'\b'+key+r':\s*(-?[0-9.]+)ns', timing)[1])
            assert value >= 0, key
        health = (phy/'handfixed_candidate_constraints.timing').read_text(encoding='utf-8')
        assert 'There are 0 invalid constraints.' in health
        assert 'There are 0 constraints that have no timing paths.' in health
        original = json.loads((PROJECT/'verification.json').read_text(encoding='utf-8'))
        assert common.sha(AUDIT/'original_build_handfixed_background.tcl') == original['build_script_sha256']
        assert common.sha(phy/'handfixed_candidate_pr.db') == original['routed_db_sha256']
        for path in ['td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit']:
            assert common.sha(ROOT/path) == original['bitstream']['sha256'], path
        report['original_physical_reports'] = 'pass; source cleanup recorded in source_cleanup.json; no new route/bit generation'
    (AUDIT/'verification.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
