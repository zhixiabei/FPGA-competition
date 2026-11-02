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


def check_ae_awb_hold_scope(relative, expected, actual):
    """Permit AE fast-window/hold control and AWB hold/cyan/routing changes.

    Exposure/divider arithmetic and pixel multiplication must match main.
    AWB may register accepted smoothed gains and bank delay-memory pointers.
    The neutral gate may only add the G/B-matched red recovery branch.
    Functional regression and final routed STA remain required.
    """
    compact = lambda text: re.sub(r'\s+', '', uncomment(text))
    original, candidate = compact(expected), compact(actual)
    if original == candidate:
        return False
    if relative == 'auto_exposure_control.v':
        replacements = [
            ("parameter integer AVERAGE_FRAMES = 6,",
             "parameter integer AVERAGE_FRAMES = 6, parameter integer FAST_AVERAGE_FRAMES = 0,"),
            ("reg [COUNT_BITS-1:0] count_accum;",
             "reg [COUNT_BITS-1:0] count_accum; reg fast_window_dark, fast_window_bright;"),
            ("wire [COUNT_BITS-1:0] window_count = FIXED_SAMPLE_COUNT != 0 ? "
             "MAX_WINDOW_COUNT : count_accum + input_count; "
             "wire window_complete = frame_count == AVERAGE_FRAMES - 1;",
             "wire frame_fast_dark = frame_sum < count_scale(input_count, DARK_FAST); "
             "wire frame_fast_bright = frame_sum > count_scale(input_count, BRIGHT_FAST); "
             "wire fast_window_complete = FAST_AVERAGE_FRAMES != 0 && "
             "frame_count == FAST_AVERAGE_FRAMES-1 && "
             "((fast_window_dark && frame_fast_dark) || (fast_window_bright && frame_fast_bright)); "
             "wire [COUNT_BITS-1:0] window_count = FIXED_SAMPLE_COUNT != 0 ? "
             "(fast_window_complete ? FIXED_SAMPLE_COUNT * FAST_AVERAGE_FRAMES : "
             "MAX_WINDOW_COUNT) : count_accum + input_count; "
             "wire window_complete = frame_count == AVERAGE_FRAMES - 1 || fast_window_complete;"),
            ("count_accum <= {COUNT_BITS{1'b0}}; O_ae_req <= 1'b0;",
             "count_accum <= {COUNT_BITS{1'b0}}; fast_window_dark <= 1'b0; "
             "fast_window_bright <= 1'b0; O_ae_req <= 1'b0;"),
            ("ST_COLLECT: if (I_stats_valid && stats_ok) begin if (window_complete)",
             "ST_COLLECT: if (I_stats_valid && stats_ok) begin "
             "fast_window_dark <= frame_fast_dark && (frame_count == 0 || fast_window_dark); "
             "fast_window_bright <= frame_fast_bright && (frame_count == 0 || fast_window_bright); "
             "if (window_complete)"),
            ('if (SETTLE_FRAMES < 0 || SETTLE_FRAMES > 255)',
             'if (FAST_AVERAGE_FRAMES != 0 && (FAST_AVERAGE_FRAMES < 2 || '
             'FAST_AVERAGE_FRAMES >= AVERAGE_FRAMES)) '
             '$fatal(1, "Fast AE window must be disabled or in 2..AVERAGE_FRAMES-1"); '
             'if (SETTLE_FRAMES < 0 || SETTLE_FRAMES > 255)'),
            ("O_awb_hold <= state != ST_COLLECT || !I_cam_cfg_done;",
             "if (!I_ae_cfg_done) O_awb_hold <= 1'b1;"),
            ("if (!I_cam_cfg_done) begin state <= ST_INITIAL;",
             "if (!I_cam_cfg_done) begin O_awb_hold <= 1'b1; state <= ST_INITIAL;"),
            ("ST_INITIAL: begin if (I_ae_cfg_done) begin",
             "ST_INITIAL: begin O_awb_hold <= 1'b1; if (I_ae_cfg_done) begin"),
            ("O_awb_hold <= 1'b1; state <= ST_WAIT_BUSY; end",
             "O_awb_hold <= 1'b1; state <= ST_WAIT_BUSY; "
             "end else if (I_ae_cfg_done) begin O_awb_hold <= 1'b0; end"),
            ("default: state <= ST_INITIAL;",
             "default: begin state <= ST_INITIAL; O_awb_hold <= 1'b1; end"),
        ]
    else:
        replacements = [
            ("parameter integer CONFIDENCE_ENABLE = 0,",
             "parameter integer CONFIDENCE_ENABLE = 0, parameter integer RED_RECOVERY_ENABLE = 0,"),
            ("""wire sample_neutral_d1 =
                sample_max_d1 >= 8'd40 && sample_max_d1 <= 8'd220 &&
                sample_spread_d1 <= (sample_max_d1 >> 1) &&
                {1'b0, red_d1} <= neutral_upper_d1 && red_d1 >= neutral_lower_d1 &&
                {1'b0, blue_d1} <= neutral_upper_d1 && blue_d1 >= neutral_lower_d1;""",
             """wire [7:0] gb_difference_d1 = green_d1_stats >= blue_d1 ?
                green_d1_stats-blue_d1 : blue_d1-green_d1_stats;
                wire red_recovery_d1 = RED_RECOVERY_ENABLE != 0 &&
                sample_max_d1 >= 8'd40 && sample_max_d1 <= 8'd220 &&
                red_d1 >= 8'd20 && red_d1 >= (green_d1_stats >> 2) &&
                red_d1 < neutral_lower_d1 &&
                gb_difference_d1 <= (green_d1_stats >> 3);
                wire sample_neutral_d1 =
                red_recovery_d1 || (sample_max_d1 >= 8'd40 && sample_max_d1 <= 8'd220 &&
                sample_spread_d1 <= (sample_max_d1 >> 1) &&
                {1'b0, red_d1} <= neutral_upper_d1 && red_d1 >= neutral_lower_d1 &&
                {1'b0, blue_d1} <= neutral_upper_d1 && blue_d1 >= neutral_lower_d1);"""),
            ("wire hold_updates = CONFIDENCE_ENABLE != 0 && I_hold;",
             "wire hold_updates = I_hold;"),
            ("wire coverage_ok = CONFIDENCE_ENABLE == 0 || "
             "(upper_samples == REGION_MIN && lower_samples == REGION_MIN && !completed_frame_bad);",
             "wire coverage_ok = !completed_frame_bad && (CONFIDENCE_ENABLE == 0 || "
             "(upper_samples == REGION_MIN && lower_samples == REGION_MIN));"),
            ("bad_d0 <= hold_updates || line_bad || (!I_tuser && frame_bad);",
             "bad_d0 <= hold_updates || (CONFIDENCE_ENABLE != 0 && line_bad) || (!I_tuser && frame_bad);"),
            ("(CONFIDENCE_ENABLE == 0 || !overrun_block);", "!overrun_block;"),
            ("frame_bad <= hold_updates || line_bad;",
             "frame_bad <= hold_updates || (CONFIDENCE_ENABLE != 0 && line_bad);"),
            ("if (line_bad || hold_updates) frame_bad <= 1'b1;",
             "if ((CONFIDENCE_ENABLE != 0 && line_bad) || hold_updates) frame_bad <= 1'b1;"),
            ("""wire [10:0] committed_gain_r = F_smooth_gain(gain_r_q8, pending_r_q8);
                wire [10:0] committed_gain_b = F_smooth_gain(gain_b_q8, pending_b_q8);""",
             "reg [10:0] committed_gain_r, committed_gain_b;"),
            ("pending_b_q8 <= 11'd256; pending_ready <= 1'b0;",
             "pending_b_q8 <= 11'd256; committed_gain_r <= 11'd256; "
             "committed_gain_b <= 11'd256; pending_ready <= 1'b0;"),
            ("pending_b_q8 <= blue_result; pending_ready <= 1'b1;",
             "pending_b_q8 <= blue_result; "
             "committed_gain_r <= F_smooth_gain(gain_r_q8, div_red_result); "
             "committed_gain_b <= F_smooth_gain(gain_b_q8, blue_result); "
             "pending_ready <= 1'b1;"),
            ("reg [5:0] video_write_address, video_read_address;", ""),
            ("video_write_address <= 6'd0; video_read_address <= 6'd13;", ""),
            ("video_write_address <= video_write_address + 1'b1; "
             "video_read_address <= video_read_address + 1'b1;", ""),
            ("""PH1P_LOGIC_DRAM #(
                .DATA_WIDTH_W(96), .DATA_WIDTH_R(96),
                .ADDR_WIDTH_W(6), .ADDR_WIDTH_R(6),
                .DATA_DEPTH_W(64), .DATA_DEPTH_R(64),
                .READREG("ENABLE"), .RESETMODE("ASYNC"),
                .INIT_FILE("NONE"), .FILL_ALL("NONE")
            ) u_video_start_guard (
                .di(output_data), .waddr(video_write_address), .we(I_rst_n), .wclk(I_clk),
                .raddr(video_read_address), .rclk(I_clk), .rrst(!I_rst_n), .rce(1'b1),
                .rdo(), .rdoq(video_delayed_data)
            );""",
             """genvar video_bank;
            generate for (video_bank=0; video_bank<4; video_bank=video_bank+1) begin : g_video_delay
                (* preserve=1 *) reg [5:0] write_address, read_address;
                always @(posedge I_clk or negedge I_rst_n) begin
                    if (!I_rst_n) begin
                        write_address <= 6'd0;
                        read_address <= 6'd13;
                    end else begin
                        write_address <= write_address + 1'b1;
                        read_address <= read_address + 1'b1;
                    end
                end
                PH1P_LOGIC_DRAM #(
                    .DATA_WIDTH_W(24), .DATA_WIDTH_R(24),
                    .ADDR_WIDTH_W(6), .ADDR_WIDTH_R(6),
                    .DATA_DEPTH_W(64), .DATA_DEPTH_R(64),
                    .READREG("ENABLE"), .RESETMODE("ASYNC"),
                    .INIT_FILE("NONE"), .FILL_ALL("NONE")
                ) u_video_start_guard (
                    .di(output_data[video_bank*24 +: 24]),
                    .waddr(write_address), .we(I_rst_n), .wclk(I_clk),
                    .raddr(read_address), .rclk(I_clk), .rrst(!I_rst_n), .rce(1'b1),
                    .rdo(), .rdoq(video_delayed_data[video_bank*24 +: 24])
                );
            end endgenerate"""),
        ]
    for before, after in replacements:
        before, after = compact(before), compact(after)
        require(original.count(before) == 1,
                f'{relative}: main no longer matches the AE/AWB hold change')
        original = original.replace(before, after)
    require(candidate == original, f'{relative}: change outside AE/AWB hold scope')
    print(f'AE_AWB_HOLD_CHANGE_SCOPE_PASS {relative} '
          '(run hold/frame regression and routed timing separately)')
    return True


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


def check_video_routing_scope(relative, expected, actual):
    """Allow only reviewed local control copies; equivalence is simulated separately."""
    compact = lambda text: re.sub(r'\s+', '', uncomment(text))
    candidate = compact(actual)
    if relative == 'isp/scharr_edge_detect_96.v':
        declaration = '(*preserve=1*)regvd_bottom,vd_top_tail,vd_middle_tail,vd_bottom_tail;'
        if declaration not in candidate:
            return actual, False
        replacements = [
            (declaration, ''),
            ('vd_bottom<=0;vd_top_tail<=0;vd_middle_tail<=0;vd_bottom_tail<=0;', ''),
            ('vd_bottom<=valid;vd_top_tail<=valid;vd_middle_tail<=valid;vd_bottom_tail<=valid;', ''),
            ('if(vd_bottom)bottom_output<=bottom;'
             'if(vd_top_tail)top_tail<=top[2*DATA_WIDTH-1:0];'
             'if(vd_middle_tail)middle_tail<=middle[2*DATA_WIDTH-1:0];'
             'if(vd_bottom_tail)bottom_tail<=bottom_output[2*DATA_WIDTH-1:0];', ''),
            ('out_x<=xd;out_y<=yd;',
             'out_x<=xd;out_y<=yd;bottom_output<=bottom;'
             'top_tail<=top[2*DATA_WIDTH-1:0];'
             'middle_tail<=middle[2*DATA_WIDTH-1:0];'
             'bottom_tail<=bottom_output[2*DATA_WIDTH-1:0];'),
        ]
        # Preserve token boundaries for the existing module-level scope check.
        restored = actual
        for before, after in replacements:
            require(candidate.count(before) == 1, 'Unexpected Scharr control-bank edit')
            pattern = r'\s*'.join(re.escape(char) for char in before)
            if after:
                after = ('out_x<=xd; out_y<=yd; bottom_output<=bottom; '
                         'top_tail<=top[2*DATA_WIDTH-1:0]; '
                         'middle_tail<=middle[2*DATA_WIDTH-1:0]; '
                         'bottom_tail<=bottom_output[2*DATA_WIDTH-1:0];')
            restored, count = re.subn(pattern, lambda _: after, restored)
            require(count == 1, 'Could not isolate Scharr control-bank edit')
            candidate = candidate.replace(before, compact(after), 1)
        return restored, True
    if '(*shifter_style="reg_shifter_reg"*)reg[95:0]rgb_delay' in candidate:
        reference_delay = re.search(
            r'`ifdef\s+SCHARR_PORTABLE_RAM\s+(.*?)`else.*?`endif',
            expected, re.S)
        require(reference_delay is not None, 'Missing reference RGB delay block')
        portable_delay = reference_delay.group(1)
        register_delay = portable_delay.replace(
            'reg [95:0] rgb_delay',
            '(* shifter_style="reg_shifter_reg" *) reg [95:0] rgb_delay')
        require(candidate.count(compact(register_delay)) == 1,
                'RGB delay differs from the eleven-cycle reference shift chain')
        candidate = candidate.replace(compact(register_delay),
                                      compact(reference_delay.group(0)), 1)
        print('RGB_DELAY_SHIFT_MEMORY_SCOPE_PASS (same eleven clocks; no reset or enable)')
    if 'reg[95:0]output_data;' in candidate:
        stage = '''
            always @(posedge I_clk) output_data<=selected_data;
            always @(posedge I_clk or negedge I_rst_n) begin
                if(!I_rst_n) begin
                    output_markers<=0;
                    output_config<=DEFAULT_CONFIG;
                end else begin
                    output_markers<={selected_valid,selected_user,selected_last};
                    output_config<=config_delay[LATENCY-1];
                end
            end
            assign O_tdata=output_data;
            assign {O_tvalid,O_tuser,O_tlast}=output_markers;
            assign O_effect_config=output_config;
        '''
        changes = [
            ('''wire selected_last, selected_user, selected_valid;
                wire [95:0] selected_data;
                reg [95:0] output_data;
                reg [2:0] output_markers;
                reg [11:0] output_config;''', ''),
            ('.O_tlast(selected_last),.O_tuser(selected_user),.O_tdata(edge_data)',
             '.O_tlast(O_tlast),.O_tuser(O_tuser),.O_tdata(edge_data)'),
            ('.O_tvalid(selected_valid),.O_tready()', '.O_tvalid(O_tvalid),.O_tready()'),
            (stage, 'assign O_effect_config=config_delay[LATENCY-1];'),
        ]
        for before, after in changes:
            require(candidate.count(compact(before)) == 1,
                    'Unexpected selector output-register scope')
            candidate = candidate.replace(compact(before), compact(after), 1)
        print('VIDEO_OUTPUT_REGISTER_SCOPE_PASS '
              '(pixels, markers and config delayed together by one clock)')
    declaration = 'reg[LATENCY-2:0]select_valid_delay;'
    if declaration not in candidate:
        require(candidate == compact(expected), 'Unexpected selector edit')
        return actual, False
    for addition in (declaration, 'select_valid_delay<=0;',
                     'select_valid_delay<={select_valid_delay[LATENCY-3:0],I_tvalid};'):
        require(candidate.count(addition) == 1, 'Unexpected selector control-pipeline edit')
        candidate = candidate.replace(addition, '', 1)
    reference = compact(expected)
    old_start = 'assignO_tdata='
    new_start = 'function[5:0]decode_effect;'
    end = 'assignO_effect_config='
    require(reference.count(old_start) == candidate.count(new_start) == 1 and
            reference.count(end) == candidate.count(end) == 1,
            'Selector output scope anchors changed')
    reference = reference[:reference.index(old_start)] + reference[reference.index(end):]
    candidate = candidate[:candidate.index(new_start)] + candidate[candidate.index(end):]
    require(candidate == reference, 'Selector changed outside its final selection controls')
    return actual, True


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
    if any(path.name == 'design_top_wrapper.v' for path in files):
        for name in ('pen_minimal.v', 'signature_control.v'):
            require((ROOT / 'user_source/hdl_source' / name).resolve() in enabled_files,
                    f'{project.name}: missing or disabled signature source {name}')
    inventory = project.parent/'sources.json'
    if inventory.is_file():
        for row in json.loads(inventory.read_text(encoding='utf-8')):
            path = Path(row['snapshot'])
            require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256'],
                    f'Changed snapshot: {path}')
    print(f'PROJECT_PATHS_AND_NAMED_INTERFACES_PASS {project.name}: {len(files)} files, {count} instances')


def check_signature_scope(relative, expected, actual):
    """Allow only the mode-13 red override and selected-slot mirror output.

    All original detector, frame ownership and CDC logic must still match.
    Behavior is covered separately by the signature/single-switch regressions.
    """
    if actual == expected:
        return False
    if relative == 'target_frame_bridge.v':
        local_bypass = '''    // Active writeback holds the same message in this DDR-domain register.
    // Use that local copy for pending-slot reads instead of the CSI mailbox.
    wire [BODY_WIDTH-1:0] S_slot_result_read =
        S_result_write_active && S_active_pending_mask[I_read_slot] ?
        S_last_result_payload[BODY_WIDTH-1:0] : S_slot_result_ram;'''
        if local_bypass in actual:
            require(actual.count(local_bypass) == 1, 'Duplicate bridge bypass substitution')
            actual = actual.replace(local_bypass, '''    wire [BODY_WIDTH-1:0] S_slot_result_read =
        S_result_write_active && S_active_pending_mask[I_read_slot] ?
        S_result_payload[BODY_WIDTH-1:0] : S_slot_result_ram;''', 1)
            print('BRIDGE_LOCAL_BYPASS_SCOPE_PASS '
                  '(run mailbox invariant and routing equivalence separately)')
            if actual == expected:
                return True
        storage_prefix = '''    reg [4*BODY_WIDTH-1:0] S_slot_result_storage;
    genvar record_bank;
    generate if (SINGLE_TARGET_ONLY) begin : g_slot_registers
        // Four shallow records can sit beside their consumers instead of
        // routing the whole mailbox to a distributed-RAM column. Preserve
        // the RAM write mask and asynchronous read, including same-edge reads.
        for (record_bank=0; record_bank<4; record_bank=record_bank+1) begin : g_record
            always @(posedge I_ddr_clk) begin
                if (S_ram_write_mask[record_bank])
                    S_slot_result_storage[record_bank*BODY_WIDTH +: BODY_WIDTH] <=
                        S_ram_write_data;
            end
        end
        assign S_slot_result_ram =
            S_slot_result_storage[I_read_slot*BODY_WIDTH +: BODY_WIDTH];
    end else begin : g_slot_ram
'''
        if storage_prefix in actual:
            require(actual.count(storage_prefix) == 1, 'Duplicate bridge storage substitution')
            actual = actual.replace(storage_prefix, '', 1)
            storage_end = '        .rdo(S_slot_result_ram),.rdoq()\n    );\n    end endgenerate\n'
            require(actual.count(storage_end) == 1, 'Unexpected bridge storage scope')
            actual = actual.replace(storage_end,
                                    '        .rdo(S_slot_result_ram),.rdoq()\n    );\n', 1)
            print('BRIDGE_STORAGE_CHANGE_SCOPE_PASS '
                  '(run bridge routing equivalence separately)')
            if actual == expected:
                return True
        additions = [
            '    // DDR-domain selection, sampled by video_out at the same read-start edge.\n'
            '    output wire O_read_mirror,\n',
            '    // Mirror belongs to the stored video even when its target result is absent.\n'
            '    assign O_read_mirror = S_slot_effect_config[I_read_slot][11:8] == 4\'d13;\n',
        ]
        for addition in additions:
            require(actual.count(addition) == 1, 'Unexpected signature bridge edit')
            actual = actual.replace(addition, '', 1)
    else:
        new_mode = ("    wire signature_requested = I_effect_config[11:8] == 4'd13;\n"
                    "    wire signature_active = active_mask_view_mode == 4'd13;\n"
                    "    wire [1:0] frame_mode = signature_requested ? 2'b00 :\n"
                    '        (color_sync == color_sync_d ? color_sync : active_mode);')
        old_mode = '    wire [1:0] frame_mode = color_sync == color_sync_d ? color_sync : active_mode;'
        new_clear = ('            ((signature_requested != signature_active) ||\n'
                     "             ((frame_mode == 2'b11) != active_motion) ||")
        old_clear = "            (((frame_mode == 2'b11) != active_motion) ||"
        for new, old in [(new_mode, old_mode), (new_clear, old_clear)]:
            require(actual.count(new) == 1, 'Unexpected signature detector edit')
            actual = actual.replace(new, old, 1)
    require(actual == expected, f'Unreviewed changes beyond signature integration: {relative}')
    return True


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
    signature_changed = 0
    routing_changed = 0
    ae_awb_changed = 0
    unchanged = 0
    for relative in preserved:
        path = 'user_source/hdl_source/'+relative
        expected = git('show', f'{args.main_ref}:{path}').decode('utf-8')
        actual = (ROOT/path).read_text(encoding='utf-8')
        unchanged += actual == expected
        if actual == expected:
            continue
        if relative in {'isp/scharr_edge_detect_96.v', 'isp/rgb_edge_switch_96.v'}:
            actual, changed = check_video_routing_scope(relative, expected, actual)
            routing_changed += changed
            if changed:
                print(f'VIDEO_ROUTING_CHANGE_SCOPE_PASS {relative} '
                      '(run pixel/control equivalence simulations separately)')
            if relative == 'isp/rgb_edge_switch_96.v':
                continue
        if relative in {'auto_exposure_control.v', 'awb.v'}:
            ae_awb_changed += check_ae_awb_hold_scope(relative, expected, actual)
        elif relative == 'isp/scharr_edge_detect_96.v':
            optimized += check_scharr_center_scope(expected, actual)
        elif relative == 'isp/red_target_detect_96.v':
            detector_optimized += check_red_single_scope(expected, actual)
        elif relative in {'target_frame_bridge.v', 'isp/target_detect_switch_96.v'}:
            signature_changed += check_signature_scope(relative, expected, actual)
        else:
            require(actual == expected, f'Main logic changed: {path}')
    print(f'MAIN_FILES_PRESERVED_PASS {len(main_files)-retired_count} present; '
          f'{retired_count} reviewed obsolete files removed; '
          f'{unchanged} core modules match main; '
          f'{optimized} reviewed centre-only substitution; '
          f'{detector_optimized} reviewed single-target detector change; '
          f'{signature_changed} reviewed signature integration changes; '
          f'{routing_changed} reviewed local video-control changes; '
          f'{ae_awb_changed} reviewed AE/AWB hold changes')
    for path in (ROOT/'verification').glob('*.py'):
        ast.parse(path.read_text(encoding='utf-8-sig'), filename=str(path))
    print('PYTHON_SOURCE_PARSE_PASS')
    pins = (ROOT/'user_source/constraints_source/pin.adc').read_text(encoding='utf-8')
    assignments = re.findall(r'set_pin_assignment\s*\{\s*(\S+)\s*\}\s*\{[^}]*LOCATION\s*=\s*(\w+)', pins)
    require(dict(assignments).get('I_fruit_switch') == 'B4', 'SW2 must be assigned to B4')
    require(dict(assignments).get('I_latency_switch') == 'A4', 'SW1 must remain A4')
    require(dict(assignments).get('I_signature_switch') == 'E11', 'SW3 must be E11')
    require(dict(assignments).get('I_signature_pause_switch') == 'D11', 'SW4 must be D11')
    locations = [p for _, p in assignments]
    require(len(locations) == len(set(locations)), 'Duplicate FPGA pin assignment')
    print('SW1_A4_SW2_B4_SW3_E11_SW4_D11_PIN_ASSIGNMENTS_PASS')
    for project in [ROOT/'td_project/anlogic_edge_osd.al', *args.project]:
        check_project(project.resolve())
    print('MERGE_SOURCE_STATIC_CHECK_PASS (no compilation, simulation or programming)')


if __name__ == '__main__':
    main()
