"""Synthesize isolated signature blocks; never place, route or program hardware."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HDL = ROOT / 'user_source/hdl_source'


def defaults(source, values):
    for name, value in values.items():
        source, count = re.subn(
            rf'(parameter\s+(?:integer\s+)?{name}\s*=\s*)\d+',
            lambda match: match[1] + str(value), source, count=1)
        if count != 1:
            raise ValueError(f'Missing parameter {name}')
    return source


def narrow_probe(top, source):
    """Drive independent serial input stages to keep the probe below 160 pads.

    The same harness is used before/after; its overhead cancels in the delta.
    This is an area comparison, not a timing or physical implementation model.
    """
    header = source.split(');', 1)[0]
    ports = re.findall(r'\b(input|output)\s+(?:wire\s*|reg\s*)?'
                       r'(?:\[(\d+):(\d+)\]\s*)?(\w+)', header)
    connections, input_width, output_width = [], 0, 0
    for direction, high, low, name in ports:
        width = int(high) - int(low) + 1 if high else 1
        if name in {'I_clk', 'I_ddr_clk'}:
            signal = 'probe_clk'
        elif name == 'I_dsi_clk':
            signal = 'pixel_clk'
        elif name == 'I_rst_n':
            signal = 'rst_n'
        elif direction == 'input':
            signal = f'stimulus[{input_width} +: {width}]'
            input_width += width
        else:
            signal = f'observed[{output_width} +: {width}]'
            output_width += width
        connections.append(f'.{name}({signal})')
    return f'''
module signature_resource_probe(input wire probe_clk,pixel_clk,rst_n,
    input wire [15:0] drive,output wire observed_parity);
    reg [{input_width-1}:0] stimulus;
    always @(posedge probe_clk) stimulus<={{stimulus[{input_width-17}:0],drive}};
    wire [{output_width-1}:0] observed;
    {top} dut({','.join(connections)});
    assign observed_parity=^observed;
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--td-exe', type=Path, default=Path('D:/TD/bin/td_commands_prompt.exe'))
    parser.add_argument('--cases', nargs='+', default=['pen', 'control', 'reader_before',
                                                    'reader_after', 'mixer_before', 'mixer_after'])
    args = parser.parse_args()
    output = ROOT / 'build/signature_20261101/resources'
    output.mkdir(parents=True, exist_ok=True)
    mixer_dependencies = ['display_effects_rgb888.v', 'gamma_lut_rgb888.v',
                          'anlogic_logo_rom.v', 'osd_char_lib.v', 'video_latency_osd.v',
                          'pen_minimal.v']
    reader_dependencies = ['../ip_source/w128_d512_fifo/w128_d512_fifo.v',
                           '../ip_source/w128_d512_fifo/soft_fifo_al_4057d6b76aa6.v']
    results = {}
    summary = output / 'results.json'
    if summary.exists():
        results = json.loads(summary.read_text(encoding='utf-8'))
    for case in args.cases:
        parameters, dependencies = {}, []
        if case == 'pen':
            top = 'pen_minimal'
            parameters = {'CANVAS_SHIFT': 2, 'SMOOTH_ENABLE': 0}
        elif case == 'control':
            top = 'signature_control'
        elif case in {'reader_before', 'reader_after'}:
            top = 'video_out'
            parameters = {'FRAME_STRIDE_NATIVE': 1572864, 'MIRROR_ENABLE': int(case.endswith('after'))}
            dependencies = reader_dependencies
        elif case in {'mixer_before', 'mixer_after'}:
            top = 'hdmi_mixer'
            parameters = {'H_OFFSET': 0, 'V_OFFSET': 0, 'SHOW_COLOR_TARGET': 1,
                          'MULTI_TARGET_ENABLE': 0, 'SINGLE_SHAPE_ENABLE': 1,
                          'TARGET_SLOTS': 1,
                          'SHOW_LATENCY': 1, 'LATENCY_SWITCH_ENABLE': 1, 'SHOW_EFFECT_LABEL': 1,
                          'SHOW_CNN': 1, 'HANDCNN_DYNAMIC_ROI': 1, 'FRUIT_CNN': 1,
                          'CNN_RESULT_TIMEOUT_FRAMES': 0, 'SIGNATURE_ENABLE': int(case.endswith('after'))}
            dependencies = mixer_dependencies
        else:
            raise ValueError(f'Unknown probe {case}')
        directory = output / case
        directory.mkdir(exist_ok=True)
        files = [HDL / (top + '.v')] + [HDL / name for name in dependencies]
        source = defaults(files[0].read_text(encoding='utf-8'), parameters)
        wrapper = narrow_probe(top, source) if case.startswith(('reader_', 'mixer_')) else ''
        source += '\n' + '\n'.join(path.read_text(encoding='utf-8') for path in files[1:])
        source += wrapper
        probe_top = 'signature_resource_probe' if wrapper else top
        (directory / 'probe.v').write_text(source, encoding='utf-8')
        script = f'''cd [file dirname [file normalize [info script]]]
if {{[catch {{
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    read_verilog -file probe.v -top {probe_top}
    optimize_rtl
    optimize_gate
    write_verilog logic.v
    legalize_phy_inst
    write_verilog mapped.v
    report_area -file resource.area
    puts "SIGNATURE_RESOURCE_PASS {case}"
}} detail]}} {{puts stderr "SIGNATURE_RESOURCE_FAIL: $detail";exit 1}}
exit 0
'''
        (directory / 'measure.tcl').write_text(script, encoding='ascii')
        with (directory / 'console.log').open('w', encoding='utf-8') as log:
            process = subprocess.run([str(args.td_exe), 'measure.tcl'],
                                     cwd=directory, stdout=log, stderr=subprocess.STDOUT, timeout=600)
        text = (directory / 'console.log').read_text(encoding='utf-8', errors='replace')
        if process.returncode or f'SIGNATURE_RESOURCE_PASS {case}' not in text:
            raise RuntimeError(f'Probe failed: {directory / "console.log"}')
        area = (directory / 'resource.area').read_text(encoding='utf-8')
        values = {}
        for metric in ('slice', 'reg', 'eram', 'dsp', 'lut'):
            match = re.search(rf'(?m)^#{metric}\*?\s+(\d+)\b', area)
            if not match:
                raise ValueError(f'Missing {metric}: {directory}')
            values[metric] = int(match[1])
        values['source_sha256'] = {path.resolve().relative_to(ROOT).as_posix():
                                  hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
        values['parameters'] = parameters
        results[case] = values
        summary.write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
        print(f'SIGNATURE_RESOURCE_PASS {case}: ' + ', '.join(
            f'{key}={values[key]}' for key in ('slice', 'reg', 'eram', 'dsp', 'lut')), flush=True)


if __name__ == '__main__':
    main()
