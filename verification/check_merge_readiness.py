"""Check merge sources, project paths and named RTL interfaces without compiling.

Uses Python's standard library only. Does not invoke an HDL tool, simulator,
synthesis, place/route, a programmer, UART or USB.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(*args):
    return subprocess.check_output(['git', '-c', 'core.quotepath=false', *args], cwd=ROOT)


def uncomment(text):
    return re.sub(r'//[^\n]*|/\*.*?\*/', '', text, flags=re.S)


def parentheses(text, start):
    require(text[start] == '(', 'Expected opening parenthesis')
    depth = 0
    for end in range(start, len(text)):
        if text[end] == '(':
            depth += 1
        elif text[end] == ')':
            depth -= 1
            if depth == 0:
                return text[start+1:end], end+1
    raise ValueError('Unbalanced interface parentheses')


def interface_names(header):
    # ANSI ports and parameter declarations, including comma shorthand.
    names = set()
    for part in header.split(','):
        part = part.split('=')[0].strip()
        found = re.search(r'([A-Za-z_]\w*)\s*$', part)
        if found:
            names.add(found.group(1))
    return names


def rtl_interfaces(files):
    modules, sources = {}, []
    for path in files:
        if path.suffix.lower() not in ('.v', '.sv'):
            continue
        text = uncomment(path.read_text(encoding='utf-8-sig', errors='replace'))
        sources.append((path, text))
        for match in re.finditer(r'\bmodule\s+(\w+)\s*(#\s*)?\(', text):
            header, end = parentheses(text, match.end()-1)
            params = interface_names(header) if match.group(2) else set()
            if match.group(2):
                port_start = text.index('(', end)
                header, end = parentheses(text, port_start)
            modules[match.group(1)] = (interface_names(header), params)
    count = 0
    if not modules:
        return count
    types = '|'.join(re.escape(name) for name in modules)
    pattern = re.compile(r'\b('+types+r')\s+(#\s*)?(?=\(|[A-Za-z_])')
    for path, text in sources:
        for match in pattern.finditer(text):
            if re.search(r'\bmodule\s*$', text[max(0, match.start()-12):match.start()]):
                continue
            pos = match.end()
            params = ''
            if match.group(2):
                params, pos = parentheses(text, pos)
            instance = re.match(r'\s*(\w+)\s*\(', text[pos:])
            if not instance:
                continue
            ports, _ = parentheses(text, pos+instance.end()-1)
            valid_ports, valid_params = modules[match.group(1)]
            for label, values, valid in [('port', ports, valid_ports), ('parameter', params, valid_params)]:
                names = re.findall(r'\.\s*(\w+)\s*\(', values)
                require(len(names) == len(set(names)), f'{path}: duplicate {label} on {instance.group(1)}')
                require(set(names) <= valid,
                        f'{path}: unknown {label} {set(names)-valid} on {match.group(1)} {instance.group(1)}')
            count += 1
    return count


def check_project(project):
    text = project.read_text(encoding='utf-8-sig')
    section = re.search(r'<Source_Files>.*?</Source_Files>', text, re.S)
    require(section is not None, f'Missing sources: {project}')
    xml = ET.fromstring(section.group().replace('P&R', 'P_R'))
    files = []
    for element in xml.iter('File'):
        path = Path(element.attrib['Path'])
        if not path.is_absolute():
            path = (project.parent/path).resolve()
        require(path.is_file(), f'Missing project source: {path}')
        files.append(path)
    count = rtl_interfaces(files)
    inventory = project.parent/'sources.json'
    if inventory.is_file():
        for row in json.loads(inventory.read_text(encoding='utf-8')):
            path = Path(row['snapshot'])
            require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256'],
                    f'Changed snapshot: {path}')
    print(f'PROJECT_PATHS_AND_NAMED_INTERFACES_PASS {project.name}: {len(files)} files, {count} instances')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--main-ref', default='origin/main')
    parser.add_argument('--project', action='append', type=Path, default=[])
    args = parser.parse_args()
    main_files = git('ls-tree', '-r', '--name-only', args.main_ref).decode().splitlines()
    require(all((ROOT/p).is_file() for p in main_files), 'A main file was removed')
    preserved = ['auto_exposure_control.v', 'awb.v', 'display_effect_control.v',
                 'display_effects_rgb888.v', 'target_frame_bridge.v', 'video_latency_monitor.v']
    preserved += ['isp/'+p for p in ['ae_frame_stats_raw10_4x.v', 'iq_diagnostic_stats.v',
                  'lsc_raw10_4x.v', 'red_target_detect_96.v', 'rgb_edge_switch_96.v',
                  'scharr_edge_detect_96.v', 'target_detect_switch_96.v']]
    for relative in preserved:
        path = 'user_source/hdl_source/'+relative
        expected = git('show', f'{args.main_ref}:{path}').decode('utf-8')
        require((ROOT/path).read_text(encoding='utf-8') == expected, f'Main logic changed: {path}')
    print(f'MAIN_FILES_PRESERVED_PASS {len(main_files)} files; {len(preserved)} core modules match main')
    for path in (ROOT/'verification').glob('*.py'):
        ast.parse(path.read_text(encoding='utf-8-sig'), filename=str(path))
    print('PYTHON_SOURCE_PARSE_PASS')
    pins = (ROOT/'user_source/constraints_source/pin.adc').read_text(encoding='utf-8')
    assignments = re.findall(r'set_pin_assignment\s*\{\s*(\S+)\s*\}\s*\{[^}]*LOCATION\s*=\s*(\w+)', pins)
    require(dict(assignments).get('I_fruit_switch') == 'B4', 'SW2 must be assigned to B4')
    require(dict(assignments).get('I_latency_switch') == 'A4', 'SW1 must remain A4')
    locations = [p for _, p in assignments]
    require(len(locations) == len(set(locations)), 'Duplicate FPGA pin assignment')
    print('SW1_A4_SW2_B4_PIN_ASSIGNMENTS_PASS')
    for project in [ROOT/'td_project/anlogic_edge_osd.al', ROOT/'td_project/anlogic_sc520_capture.al', *args.project]:
        check_project(project.resolve())
    for project in args.project:
        config = json.loads((project.parent/'candidate_config.json').read_text())
        if config.get('design') != 'five_fruit_fixed_roi':
            continue
        require(config.get('switch_control') and not config['key4_control'], 'Fruit must follow SW2 directly')
        require(config['switch_pin'] == 'B4' and config['switch_active_high'], 'Wrong SW2 configuration')
        top = (project.parent/'sources/user_source/hdl_source/design_top_wrapper.v').read_text()
        require('parameter integer ENABLE_HANDCNN = 1,' in top and
                'parameter integer FRUIT_SWITCH_CONTROL = 1,' in top, 'Fruit controls disabled')
        require('.run_switch(I_fruit_switch)' in top, 'SW2 not connected to classifier')
        # Verify the prepared candidate reflects current repository sources.
        from prepare_fruitfixed_project import make_display, make_system, replace_once
        from prepare_fruit128_project import background128, core128, preprocess128
        original_top = (ROOT/'user_source/hdl_source/design_top_wrapper.v').read_text(encoding='utf-8')
        expected_top = replace_once(original_top, 'parameter integer ENABLE_HANDCNN = 0,',
                                    'parameter integer ENABLE_HANDCNN = 1,')
        expected_top = replace_once(expected_top, 'parameter integer FRUIT_SWITCH_CONTROL = 0,',
                                    'parameter integer FRUIT_SWITCH_CONTROL = 1,')
        expected_top = replace_once(expected_top, 'handfixed_system #(.KEY4_CONTROL(1),.BACKGROUND_CONTROL(1),',
                                    'fruitfixed_system #(.KEY4_CONTROL(1),.BACKGROUND_CONTROL(1),')
        expected_top = replace_once(expected_top, '.HANDCNN_DYNAMIC_ROI(ENABLE_HANDCNN != 0),',
                                    '.HANDCNN_DYNAMIC_ROI(ENABLE_HANDCNN != 0),\n        .FRUIT_CNN(1),')
        expected_top = replace_once(expected_top, '.SHOW_RESNET_RUNTIME ( ENABLE_HANDCNN != 0 ? 1 : 0 ),',
                                    '.SHOW_RESNET_RUNTIME ( 0 ),')
        require(top == expected_top, 'Prepared fruit top is older than repository sources')
        candidate = project.parent/'sources/candidate'
        for name, relative, convert in [
            ('fruitcnn128_core.v', 'handcnn/handcnn_core.v', core128),
            ('handfixed_preprocess.v', 'handfixed/handfixed_preprocess.v', preprocess128),
            ('handfixed_background.v', 'handfixed/handfixed_background.v', background128),
            ('handfixed_key_control.v', 'handfixed/handfixed_key_control.v', lambda value: value),
            ('fruitfixed_system.v', 'handfixed/handfixed_system.v',
             lambda value: replace_once(make_system(value), 'handcnn_core core(', 'fruitcnn128_core core(')),
        ]:
            expected = convert((ROOT/'user_source/hdl_source'/relative).read_text(encoding='utf-8'))
            require((candidate/name).read_text(encoding='utf-8') == expected, f'Candidate outdated: {name}')
        expected_display = make_display((ROOT/'user_source/hdl_source/hdmi_mixer.v').read_text(encoding='utf-8'),
                                        config['display_labels'])
        require((project.parent/'sources/user_source/hdl_source/hdmi_mixer.v').read_text(encoding='utf-8') == expected_display,
                'Candidate display outdated')
        for relative in ['td_project/anlogic_edge_osd.sdc', 'user_source/constraints_source/pin.adc']:
            expected = (ROOT/relative).read_bytes()
            if relative.endswith('anlogic_edge_osd.sdc'):
                expected += b'\n' + (ROOT/'user_source/constraints_source/cnn_optional.sdc').read_bytes()
            require((project.parent/'sources'/relative).read_bytes() == expected,
                    f'Candidate constraint outdated: {relative}')
        print('FRUIT_CANDIDATE_SOURCE_FRESHNESS_PASS')
        data = (Path(config['model_directory'])/'model.bin').read_bytes()
        require(hashlib.sha256(data).hexdigest() == config['model_sha256'], 'Model bundle mismatch')
        # Four display slots (native addresses count 16-bit words) end at C00000.
        require(1572864*2*4 == 0xc00000 and 1280*720*3 <= 1572864*2, 'Video slot overlap')
        require(0xc00000+len(data) <= 0xe00000 and 0xe00000+1280*720*3 <= 0x1100000,
                'Model/snapshot memory overlap')
        print('FRUIT_SW2_MODEL_AND_MEMORY_MAP_PASS')
    print('MERGE_SOURCE_STATIC_CHECK_PASS (no compilation, simulation or programming)')


if __name__ == '__main__':
    main()
