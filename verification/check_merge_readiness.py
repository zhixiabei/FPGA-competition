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


def check_scharr_center_scope(expected, actual):
    """Allow the reviewed centre-only substitution, preserve all other effects.

    This checks edit scope, not functional equivalence. The centre-delay and
    complete Scharr differential simulations remain separate required checks.
    """
    compact = lambda text: re.sub(r'\s+', '', uncomment(text))
    original = compact(expected)
    candidate = compact(actual)
    if original == candidate:
        return False
    modules = list(re.finditer(
        r'\bmodule\s+scharr_center_delay_4\b.*?\bendmodule\b',
        uncomment(actual), re.S,
    ))
    require(len(modules) == 1, 'Expected one centre-only delay module')
    body = uncomment(actual)
    candidate = compact(body[:modules[0].start()] + body[modules[0].end():])
    replacements = []
    for position in ('center', 'final'):
        old_signal = f'cartoon_{position}_window'
        new_signal = f'cartoon_{position}_pixels'
        valid, user, last, word = (
            ('pv', 'pu', 'pl', 'cartoon_quantized') if position == 'center'
            else ('vp[2]', 'up[2]', 'lp[2]', 'cartoon_delay[2]')
        )
        replacements.append((
            f"""wire [323:0] {old_signal};
            scharr_window_4 #(.DATA_WIDTH(9),.IMG_WIDTH(IMG_WIDTH),
                .IMG_HEIGHT(IMG_HEIGHT),.TRACK_POSITION(0))
            u_cartoon_{position}_window(
                .clk(I_clk),.rst_n(I_rst_n),.valid({valid}),.user({user}),.last({last}),
                .word({word}),.out_valid(),.out_user(),.out_last(),.ok(),
                .windows({old_signal}),.out_x(),.out_y());""",
            f"""wire [35:0] {new_signal};
            scharr_center_delay_4 #(.DATA_WIDTH(9),.IMG_WIDTH(IMG_WIDTH))
            u_cartoon_{position}_window(
                .clk(I_clk),.rst_n(I_rst_n),.valid({valid}),.user({user}),.last({last}),
                .word({word}),.out_valid(),.out_user(),.out_last(),
                .centers({new_signal}));""",
        ))
    replacements.extend([
        ("""for(cartoon_lane=0;cartoon_lane<4;cartoon_lane=cartoon_lane+1)
                cartoon_delay[0][35-cartoon_lane*9 -:9]<=
                    cartoon_center_window[287-cartoon_lane*81 -:9];""",
         "cartoon_delay[0]<=cartoon_center_pixels;"),
        ("cartoon_expand(cartoon_final_window[287-lane*81 -:9])",
         "cartoon_expand(cartoon_final_pixels[35-lane*9 -:9])"),
    ])
    for before, after in replacements:
        before, after = compact(before), compact(after)
        require(original.count(before) == 1,
                'Scharr reference no longer matches the reviewed substitution')
        original = original.replace(before, after)
    require(candidate == original,
            'Scharr changed outside the reviewed centre-only substitution')
    print('SCHARR_CENTER_ONLY_CHANGE_SCOPE_PASS (run differential simulations separately)')
    return True


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


def check_red_single_scope(expected, actual):
    """Check the authorized detector edit scope, not algorithm equivalence.

    RGB/single-target scene regressions and descriptor arithmetic differential
    tests remain required. Multitarget, RAM, cleanup and legacy logic stay
    protected against the selected main reference.
    """
    compact = lambda text: re.sub(r'\s+', '', uncomment(text))
    if compact(expected) == compact(actual):
        return False

    def modules(text):
        entries = {}
        for match in re.finditer(
                r'\bmodule\s+(\w+)\b.*?\bendmodule\b', uncomment(text), re.S):
            name = match.group(1)
            require(name not in entries, f'Duplicate detector module: {name}')
            entries[name] = match.group()
        return entries

    def header(text):
        match = re.match(r'\s*module\s+\w+\s*(#\s*)?\(', text)
        require(match is not None, 'Missing detector ANSI interface')
        parameters, end = parentheses(text, match.end()-1)
        if match.group(1):
            ports, end = parentheses(text, text.index('(', end))
        else:
            ports, parameters = parameters, ''
        return parameters, ports

    original, candidate = modules(expected), modules(actual)
    require(original.keys() == candidate.keys(),
            'Detector module inventory changed outside the reviewed scope')
    editable = {'red_target_detect_96', 'red_single_shape_engine',
                'color_shape_descriptor'}
    require(editable <= original.keys(), 'Missing reviewed detector modules')
    for name in original.keys() - editable:
        require(compact(candidate[name]) == compact(original[name]),
                f'Preserved detector module changed: {name}')
    for name in sorted(editable):
        require(tuple(map(compact, header(candidate[name]))) ==
                tuple(map(compact, header(original[name]))),
                f'Detector external interface changed: {name}')

    # Compare the entire top after masking only the color predicate, the
    # single-target beat metadata and its instance connections.
    def mask_region(text, first, last, label):
        require(text.count(first) == 1 and text.count(last) == 1,
                f'Detector {label} scope anchors changed')
        begin = text.index(first) + len(first)
        end = text.index(last, begin)
        return text[:begin] + '<' + label + '>' + text[end:]

    scopes = [
        ('localparam[8:0]RED_DELTA_9=RED_DELTA;',
         'reg[GROUP_BITS-1:0]x_grp;', 'color_predicate'),
        ('wire[X_BITS-1:0]last_x=hits_f[3]?lane_x3:'
         'hits_f[2]?lane_x2:hits_f[1]?lane_x1:lane_x0;',
         'reg[COUNT_BITS-1:0]count;', 'single_beat_metadata'),
        ('endelseif(SINGLE_SHAPE_ENABLE)begin:gen_single_shape',
         'endelsebegin:gen_single_only', 'single_instance'),
    ]
    reference_top = compact(original['red_target_detect_96'])
    actual_top = compact(candidate['red_target_detect_96'])
    for first, last, label in scopes:
        reference_top = mask_region(reference_top, first, last, label)
        actual_top = mask_region(actual_top, first, last, label)
    require(actual_top == reference_top,
            'Detector changed outside color/single-target scope')
    print('RED_SINGLE_TARGET_CHANGE_SCOPE_PASS '
          '(run scene and descriptor differential simulations separately)')
    return True


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
    files, enabled_files = [], set()
    for element in xml.iter('File'):
        path = Path(element.attrib['Path'])
        if not path.is_absolute():
            path = (project.parent/path).resolve()
        require(path.is_file(), f'Missing project source: {path}')
        files.append(path)
        attributes = {attr.attrib['Name'].replace('P_R', 'P&R'): attr.attrib['Val']
                      for attr in element.iter('Attr')}
        # TD refreshes AutoExcluded during hierarchy analysis. Check the
        # explicit flow selectors here; synthesis checks the actual hierarchy.
        if (attributes.get('UsedInSyn', 'true') == 'true' and
                attributes.get('UsedInP&R', 'true') == 'true'):
            enabled_files.add(path)
    # Compiling every file in voice/ can conceal a missing entry in the actual
    # TD project. Check its enabled source list before checking named interfaces.
    if any(path.name == 'design_top_wrapper.v' and
           re.search(r'\bcheckout_voice_bridge\s*#?\s*\(',
                     uncomment(path.read_text(encoding='utf-8-sig', errors='replace')))
           for path in files):
        for name in ('cx_sp5t_uart', 'scale_voice_stable', 'scale_voice_phrase',
                     'scale_voice_auto', 'checkout_voice_bridge'):
            require(any(path.name == name + '.v' and
                        re.search(r'\bmodule\s+' + name + r'\b',
                                  uncomment(path.read_text(encoding='utf-8-sig', errors='replace')))
                        for path in enabled_files),
                    f'{project.name}: missing or disabled voice source {name}.v')
        print(f'VOICE_PROJECT_SOURCES_PASS {project.name}: 5 enabled modules')
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
    optimized = 0
    detector_optimized = 0
    for relative in preserved:
        path = 'user_source/hdl_source/'+relative
        expected = git('show', f'{args.main_ref}:{path}').decode('utf-8')
        actual = (ROOT/path).read_text(encoding='utf-8')
        if relative == 'isp/scharr_edge_detect_96.v':
            optimized += check_scharr_center_scope(expected, actual)
        elif relative == 'isp/red_target_detect_96.v':
            detector_optimized += check_red_single_scope(expected, actual)
        else:
            require(actual == expected, f'Main logic changed: {path}')
    print(f'MAIN_FILES_PRESERVED_PASS {len(main_files)} files; '
          f'{len(preserved)-optimized-detector_optimized} core modules match main; '
          f'{optimized} reviewed centre-only substitution; '
          f'{detector_optimized} reviewed single-target detector change')
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
