"""Freeze a fixed-region CNN candidate project; synthesis only, no bitstream."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model', type=Path, default=ROOT/'build/gesture/weights')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--key4', action='store_true', help='KEY4 toggles continuous recognition; reset stopped')
    p.add_argument('--background', action='store_true', help='Freeze the latest complete paused background at KEY4 start')
    args = p.parse_args()
    args.key4 = args.background = True  # Current KEY4/background configuration only.
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output.resolve()
    sources = out/'sources'
    project = (ROOT/'td_project/anlogic_edge_osd.al').read_text(encoding='utf-8')
    section = re.search(r'<Source_Files>.*?</Source_Files>', project, re.S).group()
    xml = ET.fromstring(section.replace('P&R', 'P_R'))
    inventory = []
    replaced = {p.name for p in (ROOT/'user_source/hdl_source/handfixed').glob('*.v')}
    replaced.update({'handfixed_program.v','handfixed_config.v'})
    for group in xml:
        for element in list(group):
            original = element.attrib['Path']
            source = Path(original)
            if not source.is_absolute(): source = (ROOT/'td_project'/source).resolve()
            if source.name in replaced:
                group.remove(element)
                continue
            target = sources/source.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            # Only IP needs sibling files. Copying the SDC parent would also
            # copy historical runs and bitstreams into this candidate folder.
            if group.tag == 'IP_FILE':
                shutil.copytree(source.parent, target.parent, dirs_exist_ok=True)
            data = source.read_bytes()
            target.write_bytes(data)
            element.attrib['Path'] = target.as_posix()
            inventory.append(dict(source=str(source), snapshot=str(target), sha256=hashlib.sha256(data).hexdigest()))
    verilog = xml.find('Verilog')
    paths = sorted((ROOT/'user_source/hdl_source/handfixed').glob('*.v'))
    paths += [args.model/'handfixed_program.v', args.model/'handfixed_config.v']
    for order, source in enumerate(paths):
        target = sources/'candidate'/source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        element = ET.SubElement(verilog, 'File', Path=target.as_posix())
        info = ET.SubElement(element, 'FileInfo')
        for key, value in [('UsedInSyn', 'true'), ('UsedInP&R', 'true'), ('BelongTo', 'design_1'), ('CompileOrder', str(1000+order))]:
            ET.SubElement(info, 'Attr', Name=key, Val=value)
        inventory.append(dict(source=str(source.resolve()), snapshot=str(target), sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
    section = ET.tostring(xml, encoding='unicode').replace('P_R', 'P&R').replace('&amp;', '&')
    project = re.sub(r'<Source_Files>.*?</Source_Files>', lambda m: section, project, flags=re.S)
    project = re.sub(r'<Project Version="3" Minor="2" Path="[^"]*">', lambda m: f'<Project Version="3" Minor="2" Path="{out.as_posix()}">', project)
    project = project.replace('<Name>anlogic_edge_osd</Name>', '<Name>handfixed_candidate</Name>')
    def constraint(match):
        path = Path(match.group(1))
        if not path.is_absolute(): path = (ROOT/'td_project'/path).resolve()
        return 'Path="'+path.as_posix()+'"'
    project = re.sub(r'Path="([^"]+\.(?:sdc|adc|fdc))"', constraint, project, flags=re.I)
    (out/'handfixed_candidate.al').write_text(project, encoding='utf-8')
    (out/'sources.json').write_text(json.dumps(inventory, indent=2), encoding='utf-8')
    config = dict(key4_control=args.key4, reset_recognition='stopped' if args.key4 else 'continuous', roi=[400,120,480])
    if args.background: config['background_control'] = True
    (out/'candidate_config.json').write_text(json.dumps(config, indent=2), encoding='utf-8')
    tcl = '''# Synthesis only. Do not place, route or write bit.
set root [file dirname [file normalize [info script]]]
cd $root
if {[catch {
import_device ph1_35p.db -package PH1P35MDG324 -speed 3
open_project handfixed_candidate.al -single_run
load_run_param -run syn_1
commit_param -step design
elaborate -top design_top_wrapper
read_adc PROJECT_ROOT/user_source/constraints_source/pin.adc
read_ip_adc -ip ddr2 -file $root/sources/user_source/hdl_source/ph1p35_ddr/ddr2/src/adc/ddr2.adc
read_sdc PROJECT_ROOT/td_project/anlogic_edge_osd.sdc
read_sdc -ip ddr2 $root/sources/user_source/hdl_source/ph1p35_ddr/ddr2/src/sdc/ddr2.sdc
read_sdc -ip w128_d512_fifo $root/sources/user_source/ip_source/w128_d512_fifo/w128_d512_fifo.tcl
commit_param -step rtl
optimize_rtl
report_area -file fixed_rtl.area
set_param -run syn_1 gate map_mode area_prior
set_param -run syn_1 gate pack_effort high
load_run_param -run syn_1
commit_param -step gate
optimize_gate -packarea fixed_gate.area
write_verilog fixed_gate.v
puts "HANDFIXED_SYNTHESIS_ONLY_PASS"
} detail]} {puts stderr "HANDFIXED_SYNTHESIS_ONLY_FAIL: $detail";exit 1}
exit 0
'''.replace('PROJECT_ROOT', sources.as_posix())
    (out/'synthesis_only.tcl').write_text(tcl, encoding='ascii')
    print(out)


if __name__ == '__main__': main()
