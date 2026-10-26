"""Create a self-contained five-fruit TD project from the fixed-ROI design."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f'Expected one occurrence of {old!r}, found {source.count(old)}')
    return source.replace(old, new, 1)


def snapshot(path, text, inventory, source):
    path.write_text(text, encoding='utf-8')
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    for row in inventory:
        if Path(row['snapshot']) == path:
            row.update(source=str(source.resolve()), sha256=digest)
            return
    inventory.append(dict(source=str(source.resolve()), snapshot=str(path), sha256=digest))


def project_file(xml, basename):
    matching = [element for element in xml.iter('File')
                if Path(element.attrib['Path']).name == basename]
    if len(matching) != 1:
        raise ValueError(f'Expected one TD source named {basename}, got {len(matching)}')
    return matching[0]


def add_file(verilog, path, order):
    element = ET.SubElement(verilog, 'File', Path=path.as_posix())
    info = ET.SubElement(element, 'FileInfo')
    for name, value in [('UsedInSyn', 'true'), ('UsedInP&R', 'true'),
                        ('BelongTo', 'design_1'), ('CompileOrder', str(order))]:
        ET.SubElement(info, 'Attr', Name=name, Val=value)


def make_system(text):
    text = replace_once(text, 'module handfixed_system #(', 'module fruitfixed_system #(')
    text = replace_once(text, 'handfixed_decode decode(', 'fruitfixed_decode decode(')
    text = replace_once(text, 'handfixed_result_filter result_filter(',
                        'fruitfixed_result_filter result_filter(')
    text = replace_once(text, 'wire [47:0] logits;', 'wire [79:0] logits;')
    # Keep the video DDR client free for the first UART weight transfer. The
    # paused background scan begins after the model CRC has been accepted.
    text = replace_once(text,
                        'wire monitor_enabled=run_enabled || (BACKGROUND_CONTROL!=0);',
                        'wire monitor_enabled=(run_enabled || (BACKGROUND_CONTROL!=0)) && model_ready;')
    old = '''assign status_packet={wait_cycles[15:0],mac_cycles,core_cycles,last_processing_cycles,logits,
                          result_frame,result_count,capture_failures,(KEY4_CONTROL!=0),run_enabled,old_work_draining,
                          (BACKGROUND_CONTROL!=0),background_ready,result_class,flags,8'd1,32'h31584648};'''
    new = '''assign status_packet={mac_cycles[15:0],core_cycles,last_processing_cycles,logits,
                          result_frame,result_count,capture_failures,(KEY4_CONTROL!=0),run_enabled,old_work_draining,
                          (BACKGROUND_CONTROL!=0),background_ready,result_class,flags,8'd1,32'h31555246};'''
    text = replace_once(text, old, new)
    return text


def make_display(text, labels):
    text = replace_once(text, 'parameter integer HANDCNN_DYNAMIC_ROI = 0,',
                        'parameter integer HANDCNN_DYNAMIC_ROI = 0,\n    parameter integer FRUIT_CNN = 0,')
    text = replace_once(text, "I_cnn_class <= 3'd4", "I_cnn_class <= (FRUIT_CNN != 0 ? 3'd6 : 3'd4)")
    text = replace_once(text, 'I_cnn_class<=4', 'I_cnn_class<=(FRUIT_CNN != 0 ? 6 : 4)')
    text = replace_once(text,
                        'SHOW_RESNET_RUNTIME != 0 ? 256 : 192))',
                        'SHOW_RESNET_RUNTIME != 0 ? 256 : FRUIT_CNN != 0 ? 208 : 192))')
    cases = '\n'.join(
        f"                        3'd{i+2}: S_cnn_char=F_fruit_char(56'h{label.encode('ascii').hex()},S_cnn_char_index-6);"
        for i, label in enumerate(labels))
    label_logic = f'''        if (FRUIT_CNN != 0) begin
            case (S_cnn_char_index)
                0: S_cnn_char="F";
                1: S_cnn_char="R";
                2: S_cnn_char="U";
                3: S_cnn_char="I";
                4: S_cnn_char="T";
                5: S_cnn_char=" ";
                6,7,8,9,10,11,12: begin
                    case (S_cnn_class)
{cases}
                        default: S_cnn_char=F_fruit_char(56'h554e4b4e4f574e,S_cnn_char_index-6);
                    endcase
                end
                default: S_cnn_char=" ";
            endcase
        end
'''
    helper = '''    function [7:0] F_fruit_char;
        input [55:0] label;
        input [4:0] position;
        begin F_fruit_char=label[55-position*8 -: 8];end
    endfunction

'''
    text = replace_once(text, '    function [7:0] F_probe_hex;', helper + '    function [7:0] F_probe_hex;')
    text = replace_once(text, '        if (SHOW_RESNET_PROBE != 0) begin',
                        label_logic + '        if (SHOW_RESNET_PROBE != 0) begin')
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, default=ROOT/'build/fruit/weights')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    model = args.model.resolve()
    out = args.output.resolve()
    if out.parent != ROOT/'build/fruit':
        raise ValueError('TD candidate must be a direct child of build/fruit/')
    config = json.loads((model/'model.json').read_text())
    classes = config['classes']
    labels = config.get('display_labels', [name.upper()[:7].ljust(7) for name in classes])
    if (len(classes) != 5 or len(set(classes)) != 5 or len(labels) != 5 or
            any(len(label) != 7 or not label.isascii() for label in labels) or
            config['format'] != 'HFIXCNN1' or
            config['model_sha256'] != hashlib.sha256((model/'model.bin').read_bytes()).hexdigest()):
        raise ValueError('Expected the audited five-fruit model bundle')
    subprocess.run([sys.executable, str(ROOT/'verification/prepare_handfixed_project.py'),
                    '--model', str(model), '--output', str(out)], check=True)
    inventory_path = out/'sources.json'
    inventory = json.loads(inventory_path.read_text())
    sources = out/'sources'
    project_path = out/'handfixed_candidate.al'
    project = project_path.read_text(encoding='utf-8')
    section = re.search(r'<Source_Files>.*?</Source_Files>', project, re.S)
    xml = ET.fromstring(section.group().replace('P&R', 'P_R'))
    verilog = xml.find('Verilog')

    system_source = ROOT/'user_source/hdl_source/handfixed/handfixed_system.v'
    system_target = sources/'candidate/fruitfixed_system.v'
    snapshot(system_target, make_system(system_source.read_text(encoding='utf-8')), inventory, system_source)
    project_file(xml, 'handfixed_system.v').attrib['Path'] = system_target.as_posix()

    top_source = ROOT/'user_source/hdl_source/design_top_wrapper.v'
    top_target = sources/'user_source/hdl_source/design_top_wrapper.v'
    top = top_target.read_text(encoding='utf-8')
    top = replace_once(top, 'handfixed_system #(.KEY4_CONTROL(1),.BACKGROUND_CONTROL(1),',
                       'fruitfixed_system #(.KEY4_CONTROL(1),.BACKGROUND_CONTROL(1),')
    top = replace_once(top, 'parameter integer FRUIT_SWITCH_CONTROL = 0,',
                       'parameter integer FRUIT_SWITCH_CONTROL = 1,')
    top = replace_once(top, '.HANDCNN_DYNAMIC_ROI(ENABLE_HANDCNN != 0),',
                       '.HANDCNN_DYNAMIC_ROI(ENABLE_HANDCNN != 0),\n        .FRUIT_CNN(1),')
    top = replace_once(top, '.SHOW_RESNET_RUNTIME ( ENABLE_HANDCNN != 0 ? 1 : 0 ),',
                       '.SHOW_RESNET_RUNTIME ( 0 ),')
    snapshot(top_target, top, inventory, top_source)

    display_source = ROOT/'user_source/hdl_source/hdmi_mixer.v'
    display_target = sources/'user_source/hdl_source/hdmi_mixer.v'
    snapshot(display_target, make_display(display_source.read_text(encoding='utf-8'), labels), inventory, display_source)
    confidence = model/'handcnn_confidence.v'
    confidence_target = sources/'candidate/handcnn_confidence.v'
    snapshot(confidence_target, confidence.read_text(encoding='utf-8'), inventory, confidence)
    project_file(xml, 'handcnn_confidence.v').attrib['Path'] = confidence_target.as_posix()
    for order, name in enumerate(['fruitfixed_decode.v', 'fruitfixed_result_filter.v'], start=1100):
        source = model/name if name == 'fruitfixed_decode.v' and (model/name).is_file() else ROOT/'user_source/hdl_source/fruitfixed'/name
        target = sources/'candidate'/name
        snapshot(target, source.read_text(encoding='utf-8'), inventory, source)
        add_file(verilog, target, order)
    updated = ET.tostring(xml, encoding='unicode').replace('P_R', 'P&R').replace('&amp;', '&')
    project = project[:section.start()] + updated + project[section.end():]
    project_path.write_text(project)
    inventory_path.write_text(json.dumps(inventory, indent=2))
    (out/'candidate_config.json').write_text(json.dumps(dict(
        design='five_fruit_fixed_roi', classes=classes, display_labels=labels, roi=[400,120,480],
        key4_control=False, switch_control=True, switch_name='SW2', switch_pin='B4',
        switch_active_high=True, reset_recognition='switch_level_after_background',
        background_control=True, model_sha256=config['model_sha256'],
        model_directory=str(model), architecture=config.get('architecture'),
        classifier_sha256=config.get('classifier_sha256'),
        classifier_threshold=config['classifier_threshold'],
        confidence_exp_sum_max=config.get('confidence_exp_sum_max', 564617),
        model_bytes=config['model_bytes'], status_magic='FRU1', status_bytes=36,
        diagnostic_overlay=False, background_starts_after_model=True), indent=2))
    print(out)


if __name__ == '__main__':
    main()
