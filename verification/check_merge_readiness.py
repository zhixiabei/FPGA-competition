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


def approved_cleanup_removals(policy):
    """Permit only reviewed obsolete documents and disposable simulator files."""
    require(policy.get('schema_version') == 1, 'Unknown cleanup manifest version')
    simulator_files = {'modelsim.ini', 'transcript', 'sim/normalize_work/transcript'} | {
        prefix + name for prefix in (
            'sim/fruit_core_work/', 'sim/core_compile_work/work/',
            'sim/normalize_work/work/', 'sim/preprocess_compile_work/work/'
        ) for name in
        ('_info', '_lib.qdb', '_lib1_0.qdb', '_lib1_0.qpg', '_lib1_0.qtl', '_vmake')
    }
    allowed = {}
    critical_tools = {'check_merge_readiness.py', 'run_image_quality_build.ps1',
                      'run_scale_voice_tests.py', 'test_voice_project_sources.py',
                      'read_flash_model_status.ps1', 'refresh_osd_font.py',
                      'check_color_mask_equivalence.ps1', 'fruitcnn128.py', 'handcnn_model.py'}
    for row in policy['removed_tracked_files']:
        path, category, blob = row['path'], row['category'], row['git_blob']
        require('..' not in path.split('/') and '\\' not in path,
                f'Invalid cleanup path: {path}')
        valid = (
            category == 'obsolete_document' and path.endswith('.md') and
            path.startswith(('docs/', 'verification/', 'firmware/'))
        ) or (
            category == 'generated_simulation_file' and path in simulator_files
        ) or (
            category == 'retired_launcher' and path == 'load_fruits128_weights.cmd'
        ) or (
            category == 'retired_training' and (
                path.startswith('fruits5_selected_20261031/') or
                path.startswith('fruitcnn128_retrained_20261031/') and
                path not in {
                    'fruitcnn128_retrained_20261031/README.md',
                    'fruitcnn128_retrained_20261031/summary.json',
                    'fruitcnn128_retrained_20261031/training/model.pt',
                    'fruitcnn128_retrained_20261031/training/run_config.json',
                    'fruitcnn128_retrained_20261031/training/evaluation.json',
                    'fruitcnn128_retrained_20261031/training/fpga_requirements.json',
                }
            )
        ) or (
            category == 'retired_project' and path in {
                'td_project/anlogic_edge_osd_voice_optimized.al',
                'td_project/anlogic_sc520_capture.al', 'td_project/anlogic_sc520_capture.sdc'}
        ) or (
            category == 'retired_workflow' and (
                path.startswith('verification/') and Path(path).name not in critical_tools and
                Path(path).suffix in {'.py', '.ps1', '.tcl', '.json', '.cs', '.adc', '.sdc', '.txt'} or
                path.startswith('sim/') and Path(path).suffix in {'.ps1', '.sv', '.hex'} or
                path.startswith('.run/') and path.endswith('.xml') or
                path in {'firmware/handcnn_manifest.json', 'run_handfixed_desktop.cmd'}
            )
        )
        require(valid, f'Cleanup cannot authorize source/data removal: {path}')
        require(path not in allowed and re.fullmatch(r'[0-9a-f]{40}', blob),
                f'Duplicate cleanup path or invalid Git identity: {path}')
        allowed[path] = blob
    return allowed


def check_main_inventory(main_ref):
    tree = {}
    for entry in git('ls-tree', '-r', '-z', main_ref).decode().split('\0'):
        if entry:
            metadata, path = entry.split('\t', 1)
            tree[path] = metadata.split()[2]
    manifest = ROOT/'verification/workspace_cleanup_20261101.json'
    allowed = (approved_cleanup_removals(json.loads(manifest.read_text(encoding='utf-8')))
               if manifest.is_file() else {})
    missing = [path for path in tree if not (ROOT/path).is_file()]
    unexpected = [path for path in missing if allowed.get(path) != tree[path]]
    require(not unexpected, 'Unreviewed main files removed or upstream version changed: ' +
            ', '.join(unexpected))
    return tree, len(missing)


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
    main_files, retired_count = check_main_inventory(args.main_ref)
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
    print(f'MAIN_FILES_PRESERVED_PASS {len(main_files)-retired_count} present; '
          f'{retired_count} reviewed obsolete files removed; '
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
    for project in [ROOT/'td_project/anlogic_edge_osd.al', *args.project]:
        check_project(project.resolve())
    print('MERGE_SOURCE_STATIC_CHECK_PASS (no compilation, simulation or programming)')


if __name__ == '__main__':
    main()
