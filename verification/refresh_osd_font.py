"""Refresh only OSD bitmap data from regular, monochrome desktop fonts.

The RTL stores the generated rows; building the FPGA needs neither fonts nor
Pillow. --refresh is a mechanical rewrite of the existing glyph constants and
case-table rows. The default mode independently checks the checked-in data.
"""

import argparse
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "user_source/hdl_source/osd_char_lib.v"
CHINESE = dict(zip(
    ("AN", "LU", "PING", "GUO", "XIANG", "JIAO", "PU", "TAO",
     "JU", "ZI", "CAO", "MEI"),
    "安路苹果香蕉葡萄橘子草莓",
))
CHARACTERS = {
    **CHINESE,
    **{letter: letter for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"},
    **{str(digit): str(digit) for digit in range(10)},
    "COLON": ":",
    "DOT": ".",
    "HYPHEN": "-",
    "SLASH": "/",
    "LOWER_G": "g",
    "LOWER_K": "k",
}
PACKED_ASYNC = set(CHINESE) - {"AN", "LU"} | {
    "DOT", "HYPHEN", "SLASH", "LOWER_G", "LOWER_K",
}


def font_rows(chinese_font, ascii_font):
    chinese = ImageFont.truetype(str(chinese_font), 16)
    latin = ImageFont.truetype(str(ascii_font), 18)
    glyphs = {}
    for name, character in CHARACTERS.items():
        image = Image.new("1", (16, 16))
        draw = ImageDraw.Draw(image)
        draw.fontmode = "1"
        # Keep one common ASCII origin/baseline, including narrow I/1.
        # Move g up one row so its full descender fits in the 16-row cell.
        origin = (0, 0) if name in CHINESE else (3, -2 if name == "LOWER_G" else -1)
        draw.text(origin, character,
                  font=chinese if name in CHINESE else latin, fill=1)
        rows = [
            sum(int(bool(image.getpixel((x, y)))) << (15 - x)
                for x in range(16))
            for y in range(16)
        ]
        if not any(rows):
            raise ValueError(f"Font has no pixels for {character!r}")
        glyphs[name] = rows
    return glyphs


def packed(rows):
    # Row zero is the low 16 bits; the renderer uses bit 15 as the left edge.
    return "".join(f"{row:04x}" for row in reversed(rows))


def replace_data(text, glyphs):
    first, rest = text.split("endmodule", 1)
    for name, rows in glyphs.items():
        if name in PACKED_ASYNC:
            continue  # These already use packed constants in both modules.
        pattern = (rf"(CHAR_{name}: begin\s*case\(I_row\))"
                   r"\s*.*?(\s*endcase\s*end)")
        table = "\n".join(
            f"                    4'd{row}: O_row_bits = 16'h{value:04x};"
            for row, value in enumerate(rows)
        )
        replacement = (
            rf"\g<1>" + "\n" + table + "\n"
            "                    default: O_row_bits = 16'h0000;"
            r"\g<2>"
        )
        first, count = re.subn(pattern, replacement, first, flags=re.S)
        if count != 1:
            raise ValueError(f"Expected one asynchronous table for {name}: {count}")
    text = first + "endmodule" + rest
    for name, rows in glyphs.items():
        text, count = re.subn(
            rf"(localparam \[255:0\] GLYPH_{name} = 256'h)[0-9a-fA-F]+(;)",
            rf"\g<1>{packed(rows)}\g<2>", text,
        )
        expected = 2 if name in PACKED_ASYNC else 1
        if count != expected:
            raise ValueError(f"Expected {expected} packed constants for {name}: {count}")
    return text


def rtl_rows(text, strict=True):
    first, rest = text.split("endmodule", 1)
    glyphs = {}
    for name in CHARACTERS:
        if name in PACKED_ASYNC:
            constant = re.search(
                rf"GLYPH_{name} = 256'h([0-9a-fA-F]+)", first
            )
            if constant:
                data = int(constant.group(1), 16)
                glyphs[name] = [(data >> (16 * row)) & 65535 for row in range(16)]
            elif not strict:
                glyphs[name] = [
                    0x0180 if name == "DOT" and row in (12, 13) else 0
                    for row in range(16)
                ]
            else:
                raise ValueError(f"Missing packed glyph: {name}")
        else:
            block = re.search(
                rf"CHAR_{name}: begin\s*case\(I_row\)(.*?)endcase", first, re.S
            ).group(1)
            glyphs[name] = [
                int(value, 16)
                for _, value in re.findall(
                    r"4'd(\d+): O_row_bits = 16'h([0-9a-fA-F]+)", block
                )
            ]
        constant = re.search(
            rf"GLYPH_{name} = 256'h([0-9a-fA-F]+)", rest
        )
        if not constant and not strict:
            continue
        if not constant:
            raise ValueError(f"Missing synchronous glyph: {name}")
        sync = int(constant.group(1), 16)
        if packed(glyphs[name]) != f"{sync:064x}":
            raise ValueError(f"Combinational/synchronous glyph mismatch: {name}")
    return glyphs


def preview(path, old, new):
    rows = [
        ("CHINESE", list(CHINESE)),
        ("A-M", list("ABCDEFGHIJKLM")),
        ("N-Z", list("NOPQRSTUVWXYZ")),
        ("DIGITS", list("0123456789") + ["COLON", "HYPHEN", "SLASH"]),
        ("UNIT", ["LOWER_K", "LOWER_G"]),
    ]
    scale = 3
    image = Image.new("RGB", (960, 52 + len(rows) * 138 + 6), "#101418")
    draw = ImageDraw.Draw(image)
    label_font = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", 18)
    draw.text((20, 12), "Existing glyphs / Regular upright glyphs",
              font=label_font, fill="#ffffff")
    for index, (label, names) in enumerate(rows):
        y = 52 + index * 138
        draw.text((20, y), label, font=label_font, fill="#a8b3bb")
        for line, glyphs in enumerate((old, new)):
            for column, name in enumerate(names):
                x = 150 + column * 56
                tile = Image.new("1", (16, 16))
                for row, bits in enumerate(glyphs[name]):
                    for pixel in range(16):
                        tile.putpixel((pixel, row), bool(bits & (1 << (15 - pixel))))
                enlarged = tile.resize((16 * scale, 16 * scale), Image.Resampling.NEAREST)
                image.paste("#ffffff", (x, y + line * 57), enlarged)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chinese-font", type=Path,
                        default=Path("C:/Windows/Fonts/simsun.ttc"))
    parser.add_argument("--ascii-font", type=Path,
                        default=Path("C:/Windows/Fonts/consola.ttf"))
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--preview", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    desired = font_rows(args.chinese_font, args.ascii_font)
    text = RTL.read_text(encoding="utf-8-sig")
    old = rtl_rows((args.baseline or RTL).read_text(encoding="utf-8-sig"), strict=False)
    refreshed = replace_data(text, desired)
    if args.refresh:
        RTL.write_text(refreshed, encoding="utf-8", newline="\n")
    elif refreshed != text:
        raise ValueError("OSD rows differ from regular fonts; run with --refresh")
    actual = rtl_rows(refreshed)
    if actual != desired:
        raise ValueError("Generated OSD bitmap mismatch")
    if args.preview:
        preview(args.preview, old, actual)
        print(f"Preview: {args.preview.resolve()}")
    print(f"OSD_REGULAR_FONT_PASS glyphs={len(desired)} cell=16x16 "
          "chinese=SimSun16 ascii=Consolas18")


if __name__ == "__main__":
    main()
