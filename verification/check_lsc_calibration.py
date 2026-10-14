"""Recompute neutral gains from the recorded white-field measurements.

The two exposures are normalized separately; no phone RGB pixels are used.
Optional simulation fixtures are derived from the CSV, not from DUT ROMs.
"""
import argparse
import csv
import json
import re
from pathlib import Path
from statistics import mean

ROOT = Path(__file__).resolve().parents[1]


def calibration(profile_source=None):
    with (ROOT / "verification/lsc_white_field_20261014.csv").open() as f:
        rows = list(csv.DictReader(f))
    gains = {
        c: [int(256 * mean(int(r["R"]) / int(r[c]) for r in rows
                          if int(r["region"]) == i) + .5)
            for i in range(1, 10)] for c in ("Gr", "Gb", "B")
    }
    source = (profile_source or ROOT / "user_source/hdl_source/isp/isp_top.v").read_text(encoding="utf-8")
    for c, values in gains.items():
        match = re.search(r"LSC_MESH_" + c.upper() + r"_Q8\s*=\s*\{([^}]+)\}", source)
        actual = [int(s) for s in re.findall(r"\d+'d(\d+)", match[1])] if match else []
        assert actual == values, (c, actual, values)
    worst = max(abs(int(r[c]) * gains[c][int(r["region"])-1] / 256 / int(r["R"]) - 1)
                for r in rows for c in gains)
    assert worst < .025, worst
    print("LSC_CALIBRATION_PASS measured_photos=2 nodes=9 max_node_error=%.3f%%" % (100*worst))
    print(json.dumps(gains))
    return gains


def row_knots(gains, y, curve_enabled=True):
    band = 0 if y < 359.5 else 1
    t = max(0., min(1., (y - (31.5 + 328*band)) / 328))
    knots = {}
    for c in gains:
        knots[c] = []
        for x in range(3):
            a, b = gains[c][3*band+x], gains[c][3*band+x+3]
            value = a*b/(b*(1-t)+a*t) if curve_enabled else a*(1-t)+b*t
            knots[c].append(int(value+.5))
    return knots


def midpoint(a, b):
    return int((a-b)**2/(2*(a+b))+.5)


def row_words(gains, curve_enabled=True):
    words = []
    for y in range(720):
        word = 0
        knots = row_knots(gains, y, curve_enabled)
        for c, offset, bits, bias in (("Gr", 0, 7, 128), ("Gb", 21, 7, 128), ("B", 42, 6, 240)):
            for x in range(3):
                value = knots[c][x]-bias
                assert 0 <= value < 1 << bits, (c, y, value)
                word |= value << (offset+bits*x)
        for c, offset, bits in (("Gr", 60, 4), ("Gb", 68, 4), ("B", 76, 2)):
            for side in range(2):
                value = midpoint(*knots[c][side:side+2]) if curve_enabled else 0
                assert value < 1 << bits, (c, y, value)
                word |= value << (offset+bits*side)
        words.append(word)
    return words


def audit_netlist(path, gains, curve_enabled):
    text = path.read_text(encoding="utf-8")
    blocks = re.findall(r"(?s)// u_isp_top/u_lsc/ramread.*?\);", text)
    assert len(blocks) == 4, f"Expected four physical mesh ERAMs, got {len(blocks)}"
    decoded = [0]*720
    coverage = set()
    for block in blocks:
        assert 'PH1P_PHY_ERAM_V2' in block
        for name in ("A", "B"):
            assert f'.DATA_WIDTH_{name}("20")' in block
            assert f'.WE{name}MUX("0")' in block
            address = re.search(r"\.addr"+name.lower()+r"\(([^)]+)\)", block)[1]
            assert re.sub(r"\s", "", address) == r"{\u_isp_top/u_lsc/mesh$current_y,4'b1111}"
        init = {k: int(v, 16) for k, v in re.findall(r"\.(INITP?_[0-9A-F]{2})\(256'h([0-9A-Fa-f]+)\)", block)}
        for port, width, prefix in (("dob", 16, "INIT"), ("dob_extra", 4, "INITP")):
            concat = re.search(r"\."+port+r"\(\{([^}]+)\}\)", block)[1]
            bit = width-1
            mapping = []
            for token in concat.split(","):
                if re.fullmatch(r"open_n\d+", token.strip()):
                    bit -= 1
                    continue
                match = re.fullmatch(r"\s*\\u_isp_top/u_lsc/mesh\$channel\[([012])\]\$((?:left|mid|right)_(?:code|gain)|curve_left|curve_right)\s+(?:\[(\d+)(?::(\d+))?\])?\s*", token)
                assert match, f"Unrecognized ROM output: {token}"
                ch = int(match[1])
                name = match[2]
                is_curve = name.startswith("curve_")
                logical_width = (2 if ch == 2 else 4) if is_curve else (6 if ch == 2 else 7)
                # Adding the bias preserves only these low bits of each gain.
                if name.endswith("_gain"):
                    assert match[3] is not None, f"Unselected gain alias: {token}"
                    alias_width = 4 if ch == 2 else 7
                else:
                    alias_width = logical_width
                hi = int(match[3]) if match[3] is not None else logical_width-1
                lo = int(match[4] or match[3]) if match[3] is not None else 0
                assert 0 <= lo <= hi < alias_width, f"Invalid ROM output range: {token}"
                for n in range(hi, lo-1, -1):
                    if not is_curve:
                        knot = ("left", "mid", "right").index(name.split("_")[0])
                        logical = (0, 21, 42)[ch] + knot*logical_width+n
                    else:
                        side = ("curve_left", "curve_right").index(name)
                        logical = (60, 68, 76)[ch] + side*logical_width+n
                    assert logical not in coverage, logical
                    coverage.add(logical)
                    mapping.append((bit, logical))
                    bit -= 1
            assert bit == -1, (port, bit)
            for row in range(720):
                words = 256//width
                value = (init[f"{prefix}_{row//words:02X}"] >> (width*(row%words))) & ((1<<width)-1)
                for physical, logical in mapping:
                    decoded[row] |= ((value>>physical)&1) << logical
    assert coverage == set(range(80)), coverage
    for y, (actual, expected) in enumerate(zip(decoded, row_words(gains, curve_enabled))):
        assert actual == expected, f"Mesh ROM mismatch row={y} got={actual:020x} expected={expected:020x}"
    print("LSC_NETLIST_ROM_PASS mesh_rows=720 logical_bits=80 physical_eram=4 all_nodes_and_addresses_matched")


def check_interiors(gains):
    # Only a spatial model: the CSV has no measurements between its nine nodes.
    with (ROOT / "verification/lsc_white_field_20261014.csv").open() as f:
        rows = list(csv.DictReader(f))
    peaks = [0., 0.]
    squares = [0., 0.]
    count = 0
    for photo in (1, 2):
        nodes = [[int(r[c]) for c in ("R", "Gr", "Gb", "B")]
                 for r in rows if int(r["photo"]) == photo]
        for y in range(32, 689, 41):
            by = 0 if y < 359.5 else 1
            ty = max(0., min(1., (y-(31.5+328*by))/328))
            for group in range(8, 313, 4):
                x = 4*group+1.5
                bx = 0 if x < 639.5 else 1
                tx = max(0., min(1., (x-(31.5+608*bx))/608))
                raw = [sum(nodes[3*(by+j)+bx+i][c] *
                           (tx if i else 1-tx)*(ty if j else 1-ty)
                           for j in (0, 1) for i in (0, 1)) for c in range(4)]
                side = 0 if group < 160 else 1
                t = max(0., min(1., (group-(8+152*side))/152))
                for mode in (0, 1):
                    knots = row_knots(gains, y, bool(mode))
                    for c, channel in enumerate(("Gr", "Gb"), 1):
                        a, b = knots[channel][side:side+2]
                        gain = int(a*(1-t)+b*t+.5)
                        if mode:
                            gain -= (midpoint(a, b)*int(64*t*(1-t)+.5)+8)//16
                        error = raw[c]*gain/(256*raw[0])-1
                        peaks[mode] = max(peaks[mode], error)
                        squares[mode] += error*error
                count += 2
    assert peaks[1] < .03 and peaks[1] < peaks[0]*.5, peaks
    assert squares[1] < squares[0]*.25, squares
    print("LSC_INTERPOLATION_MODEL_PASS green_peak=%.3f%%->%.3f%% green_rms=%.3f%%->%.3f%%" %
          (100*peaks[0], 100*peaks[1], 100*(squares[0]/count)**.5, 100*(squares[1]/count)**.5))


def white_fixtures(directory):
    # Independent test scene: interpolate the measured RAW values, not gains.
    # This is a test assumption for unmeasured space, not additional camera data.
    with (ROOT / "verification/lsc_white_field_20261014.csv").open() as f:
        readings = list(csv.DictReader(f))
    for photo in (1, 2):
        nodes = [[int(r[c]) for c in ("R", "Gr", "Gb", "B")]
                 for r in readings if int(r["photo"]) == photo]
        x_positions = []
        for x in range(1280):
            col = 0 if x < 639.5 else 1
            t = max(0., min(1., (x-(31.5+608*col))/608))
            x_positions.append((col, t))
        with (directory / f"white{photo}.hex").open("w", encoding="ascii") as f:
            for y in range(720):
                band = 0 if y < 359.5 else 1
                t = max(0., min(1., (y-(31.5+328*band))/328))
                row = [[nodes[3*band+k][c]*(1-t)+nodes[3*band+k+3][c]*t
                        for c in range(4)] for k in range(3)]
                for group in range(320):
                    word = 0
                    for lane in range(4):
                        x = 4*group+lane
                        col, tx = x_positions[x]
                        c = (3, 2, 1, 0)[2*(y%2)+x%2]
                        value = int(row[col][c]*(1-tx)+row[col+1][c]*tx+.5)
                        word |= value << (10*lane)
                    f.write(f"{word:010x}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--sim-dir", type=Path)
    parser.add_argument("--white-fixtures", action="store_true")
    parser.add_argument("--netlist", type=Path)
    parser.add_argument("--profile-source", type=Path)
    args = parser.parse_args()
    gains = calibration(args.profile_source)
    source = (args.profile_source or ROOT / "user_source/hdl_source/isp/isp_top.v").read_text(encoding="utf-8")
    curve_enabled = bool(int(re.search(r"LSC_MESH_CURVE_ENABLE\s*=\s*(\d+)", source)[1]))
    check_interiors(gains)
    if args.netlist:
        audit_netlist(args.netlist, gains, curve_enabled)
    if args.sim_dir:
        args.sim_dir.mkdir(parents=True, exist_ok=True)
        lines = [f"localparam integer REF_CURVE_ENABLE = {int(curve_enabled)};"]
        for c, bits in (("Gr", 8), ("Gb", 8), ("B", 9)):
            literals = ",".join(f"{bits}'d{v}" for v in gains[c])
            lines.append(f"localparam [{9*bits-1}:0] REF_{c.upper()} = {{{literals}}};")
        (args.sim_dir / "lsc_mesh_reference.vh").write_text("\n".join(lines)+"\n", encoding="ascii")
        (args.sim_dir / "mesh_row_expected.hex").write_text(
            "".join(f"{v:020x}\n" for v in row_words(gains, curve_enabled)), encoding="ascii")
        if args.white_fixtures:
            white_fixtures(args.sim_dir)
