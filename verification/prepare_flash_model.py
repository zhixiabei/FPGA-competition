"""Build temporary JTAG programmer ROM from the verified fruit model."""
import hashlib
import json
import zlib
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = Path(r'D:\vivado_work\fruit\fruit\weights\model.bin')
OUT = ROOT / 'build' / 'flash_model'
EXPECTED_SHA = 'b890089e104caf255f574c740732ab65b7eb14d369fdd7a6d31c2303eccc9db9'

def main():
    data = MODEL.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    assert sha == EXPECTED_SHA, 'Model changed: review matching RTL config first'
    assert len(data) == 170752 and zlib.crc32(data) == 0xbbd4adef
    OUT.mkdir(parents=True, exist_ok=True)
    text = ['// Generated temporary programmer ROM; not part of the main design.',
            'module fruit_flash_model_rom(input wire clk,input wire [17:0] address,output reg [7:0] data);',
            'reg [6:0] bank_q;', 'always @(posedge clk) bank_q<=address[17:11];']
    banks = (len(data) + 2047) // 2048
    for bank in range(banks):
        block = data[bank*2048:(bank+1)*2048].ljust(2048, b'\xff')
        text += [f'(* rom_style="bram" *) reg [7:0] rom_{bank}[0:2047];',
                 f'reg [7:0] q_{bank};', 'initial begin']
        text += [f"rom_{bank}[{i}]=8'h{value:02x};" for i, value in enumerate(block)]
        text += ['end', f'always @(posedge clk) q_{bank}<=rom_{bank}[address[10:0]];']
    text += ['always @* begin', 'case(bank_q)']
    text += [f"7'd{bank}:data=q_{bank};" for bank in range(banks)]
    text += ["default:data=8'hff;", 'endcase', 'end', 'endmodule']
    (OUT / 'fruit_flash_model_rom.v').write_text('\n'.join(text)+'\n', encoding='ascii')
    # Simulation image is raw model bytes followed by no padding.
    (OUT / 'model.hex').write_text('\n'.join(f'{b:02x}' for b in data)+'\n', encoding='ascii')
    manifest = dict(model=str(MODEL), size=len(data), sha256=sha, crc32='bbd4adef',
                    flash='U30 N25Q128 (independent user SPI)', address='0xF00000',
                    end_exclusive=f'0x{0xf00000+len(data):06X}', rom_banks=banks,
                    programming_policy='blank-only, no erase, exact readback')
    (OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    # Preserve the proven device/synthesis/physical options in a separate project.
    source = (ROOT / 'td_project/anlogic_edge_osd.al').read_text(encoding='utf-8')
    project = ET.fromstring(source.replace('UsedInP&R', 'UsedInP&amp;R').replace('BitgenProperty::', 'BitgenProperty_'))
    work = OUT / 'programmer'
    work.mkdir(exist_ok=True)
    project.set('Path', work.as_posix())
    project.find('Name').text = 'project'
    files = project.find('Source_Files')
    files.clear()
    verilog = ET.SubElement(files, 'Verilog')
    paths = [ROOT/'user_source/hdl_source/flash'/name for name in
             ['spi_flash_byte.v','flash_status_uart.v','fruit_flash_programmer.v','fruit_flash_program_top.v']]
    paths += [ROOT/'user_source/hdl_source/resnet18/resnet18_uart.v', OUT/'fruit_flash_model_rom.v']
    for order, path in enumerate(paths):
        f = ET.SubElement(verilog, 'File', Path=path.as_posix())
        info = ET.SubElement(f,'FileInfo')
        for name,value in [('UsedInSyn','true'),('UsedInP&R','true'),('BelongTo','design_1'),('CompileOrder',str(order))]:
            ET.SubElement(info,'Attr',Name=name,Val=value)
    rendered = ET.tostring(project,encoding='unicode').replace('UsedInP&amp;R','UsedInP&R').replace('BitgenProperty_','BitgenProperty::')
    (work/'project.al').write_text(rendered,encoding='utf-8')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
