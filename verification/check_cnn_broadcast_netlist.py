"""Audit actual CNN DSP input connections in a flat TD gate Verilog export.

This is a deliberately strict parser for TD's structural export, not an RTL
elaborator. Unsupported expressions, undeclared nets, incomplete exports, or
ambiguous lane identities fail the audit instead of supplying partial counts.
"""

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import sys
import unittest


class AuditError(ValueError):
    pass


@dataclass(frozen=True)
class Bit:
    name: str = ""
    index: object = None
    constant: object = None

    def as_dict(self):
        if self.constant is not None:
            return {"constant": self.constant}
        return {"net": self.name, "bit": self.index}


IDENTIFIER = r"(?:\\[^\s]+|[A-Za-z_$][A-Za-z0-9_$]*)"
TOKEN = re.compile(
    r"\s+|\\[^\s]+|\d+'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+|"
    r"\d+|[A-Za-z_$][A-Za-z0-9_$]*|\"(?:\\.|[^\"\\])*\"|."
)
COMMENTS = re.compile(r'\\[^\s]+|"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)


def without_comments(text):
    # Escaped identifiers may themselves contain // or /* characters.
    return COMMENTS.sub(
        lambda match: " " + "\n" * match[0].count("\n")
        if match[0].startswith(("//", "/*")) else match[0], text
    )


def tokens(text):
    return [match[0] for match in TOKEN.finditer(text) if not match[0].isspace()]


def identifier(token):
    if not re.fullmatch(IDENTIFIER, token):
        raise AuditError("Expected identifier, got " + repr(token))
    return token[1:] if token.startswith("\\") else token


class Reader:
    def __init__(self, values):
        self.values = values
        self.pos = 0

    def peek(self):
        return self.values[self.pos] if self.pos < len(self.values) else None

    def take(self, expected=None):
        result = self.peek()
        if result is None or (expected is not None and result != expected):
            raise AuditError(f"Expected {expected!r}, got {result!r}")
        self.pos += 1
        return result

    def group(self, opening="(", closing=")"):
        self.take(opening)
        start = self.pos
        depth = 1
        while depth:
            value = self.take()
            if value == opening:
                depth += 1
            elif value == closing:
                depth -= 1
        return self.values[start:self.pos - 1]

    def end(self):
        if self.peek() is not None:
            raise AuditError("Unexpected token " + repr(self.peek()))


def index_range(first, last):
    return range(first, last + (1 if last >= first else -1), 1 if last >= first else -1)


def declared_nets(text):
    declarations = {}
    pattern = re.compile(r"(?m)^\s*(?:wire|input|output|inout)\s+([^;]+);")
    for match in pattern.finditer(text):
        reader = Reader(tokens(match[1]))
        while reader.peek() in ("wire", "signed"):
            reader.take()
        bounds = None
        if reader.peek() == "[":
            reader.take("[")
            first = int(reader.take())
            reader.take(":")
            last = int(reader.take())
            reader.take("]")
            bounds = (first, last)
        while True:
            name = identifier(reader.take())
            if name in declarations and declarations[name] != bounds:
                raise AuditError("Conflicting declaration for " + name)
            declarations[name] = bounds
            if reader.peek() != ",":
                break
            reader.take(",")
        reader.end()
    return declarations


def expression(reader, declarations):
    """Expand a connection to bits in Verilog MSB-to-LSB order."""
    token = reader.take()
    if token == "{":
        if reader.peek() and reader.peek().isdigit() and reader.values[reader.pos + 1:reader.pos + 2] == ["{"]:
            repeat = int(reader.take())
            if not 1 <= repeat <= 4096:
                raise AuditError("Invalid replication count")
            result = expression(reader, declarations) * repeat
        else:
            result = expression(reader, declarations)
            while reader.peek() == ",":
                reader.take(",")
                result += expression(reader, declarations)
        reader.take("}")
        return result
    if token == "(":
        result = expression(reader, declarations)
        reader.take(")")
        return result
    literal = re.fullmatch(r"(\d+)'[sS]?([bBoOdDhH])([0-9a-fA-F_xXzZ?]+)", token)
    if literal:
        width, radix, digits = int(literal[1]), literal[2].lower(), literal[3].replace("_", "").lower()
        if not 1 <= width <= 4096:
            raise AuditError("Invalid literal width")
        if radix == "d":
            if not digits.isdigit():
                raise AuditError("Unsupported unknown decimal literal")
            expanded = bin(int(digits))[2:]
        else:
            group_width = {"b": 1, "o": 3, "h": 4}[radix]
            expanded = ""
            for digit in digits:
                if digit in "xz?":
                    expanded += ("z" if digit == "?" else digit) * group_width
                else:
                    value = int(digit, 16)
                    if value >= 2 ** group_width:
                        raise AuditError("Digit out of range in " + token)
                    expanded += format(value, "0" + str(group_width) + "b")
        fill = expanded[0] if expanded[0] in "xz" else "0"
        return [Bit(constant=bit) for bit in expanded.rjust(width, fill)[-width:]]
    name = identifier(token)
    if name not in declarations:
        raise AuditError("Undeclared net " + name)
    bounds = declarations[name]
    if reader.peek() == "[":
        if bounds is None:
            raise AuditError("Bit-select on scalar " + name)
        reader.take("[")
        first = int(reader.take())
        last = first
        if reader.peek() == ":":
            reader.take(":")
            last = int(reader.take())
            if (first < last) != (bounds[0] < bounds[1]) and first != last:
                raise AuditError("Reversed part-select on " + name)
        reader.take("]")
        if not all(min(bounds) <= value <= max(bounds) for value in (first, last)):
            raise AuditError("Out-of-range select on " + name)
        return [Bit(name, bit) for bit in index_range(first, last)]
    return [Bit(name)] if bounds is None else [Bit(name, bit) for bit in index_range(*bounds)]


def expand(values, declarations):
    reader = Reader(values)
    result = expression(reader, declarations)
    reader.end()
    return result


def alias_map(text, declarations):
    aliases = {}
    for match in re.finditer(r"(?m)^\s*assign\s+([^;]+);", text):
        reader = Reader(tokens(match[1]))
        targets = expression(reader, declarations)
        reader.take("=")
        sources = expression(reader, declarations)
        reader.end()
        if len(targets) != len(sources):
            raise AuditError("Alias assignment width mismatch")
        for target, source in zip(targets, sources):
            if target.constant is not None or target in aliases:
                raise AuditError("Invalid or multiply assigned alias target")
            aliases[target] = source
    return aliases


def resolve(bit, aliases):
    seen = set()
    while bit in aliases:
        if bit in seen:
            raise AuditError("Cycle in wire aliases")
        seen.add(bit)
        bit = aliases[bit]
    return bit


def dsp_instances(text):
    for match in re.finditer(r"(?m)^\s*PH1P_PHY_DSPSIOU_V2\b", text):
        values = []
        position = match.end()
        while True:
            token_match = TOKEN.match(text, position)
            if token_match is None:
                raise AuditError("Truncated DSP instance")
            position = token_match.end()
            token = token_match[0]
            if token.isspace():
                continue
            values.append(token)
            if token == ";":
                break
        reader = Reader(values)
        if reader.peek() == "#":
            reader.take("#")
            reader.group()
        name = identifier(reader.take())
        connections = Reader(reader.group())
        reader.take(";")
        reader.end()
        ports = {}
        while connections.peek() is not None:
            connections.take(".")
            port = identifier(connections.take())
            if port in ports:
                raise AuditError("Duplicate port " + name + "." + port)
            ports[port] = connections.group()
            if connections.peek() is not None:
                connections.take(",")
                if connections.peek() is None:
                    raise AuditError("Trailing comma in DSP ports")
        yield name, ports


def parse_netlist(raw):
    text = without_comments(raw)
    if len(re.findall(r"(?m)^\s*module\b", text)) != 1 or len(re.findall(r"(?m)^\s*endmodule\b", text)) != 1:
        raise AuditError("Expected one complete flat module")
    if not re.search(r"\bendmodule\s*$", text):
        raise AuditError("Netlist is incomplete or contains trailing code")
    declarations = declared_nets(text)
    aliases = alias_map(text, declarations)
    lanes = {}
    prefixes = set()
    instance_names = set()
    for name, ports in dsp_instances(text):
        if name in instance_names:
            raise AuditError("Duplicate DSP instance " + name)
        instance_names.add(name)
        lane_match = re.fullmatch(r"(.*(?:^|/)core)/lanes\[(\d+)\](?:\$|/)mac/u_siou", name)
        if not lane_match:
            if "core/lanes[" in name:
                raise AuditError("Unrecognized CNN DSP identity " + name)
            continue
        lane = int(lane_match[2])
        prefixes.add(lane_match[1])
        if lane in lanes:
            raise AuditError("Duplicate CNN lane " + str(lane))
        item = {"instance": name}
        for port, width in (("xa", 27), ("ce", 4)):
            if port not in ports or not ports[port]:
                raise AuditError("Missing DSP connection " + name + "." + port)
            bits = expand(ports[port], declarations)
            if len(bits) != width:
                raise AuditError(f"{name}.{port} width {len(bits)}, expected {width}")
            item[port] = [resolve(bit, aliases) for bit in reversed(bits)]
        lanes[lane] = item
    if len(prefixes) != 1 or set(lanes) != set(range(24)):
        raise AuditError(f"Expected one CNN core with lanes 0..23, found {sorted(lanes)} in {sorted(prefixes)}")
    return lanes


def loads_for(lanes, port):
    loads = {}
    for lane, item in sorted(lanes.items()):
        for pin, bit in enumerate(item[port]):
            if bit.constant is None:
                loads.setdefault(bit, []).append((lane, pin))
    return loads


def load_report(loads, port):
    return [dict(bit.as_dict(), pin_count=len(pins),
                 lanes=sorted({lane for lane, _ in pins}),
                 groups=sorted({lane // 6 for lane, _ in pins}),
                 pins=[f"lane{lane}.{port}[{pin}]" for lane, pin in pins])
            for bit, pins in sorted(loads.items(), key=lambda item: (-len(item[1]), repr(item[0])))]


def candidate_errors(lanes, activation_layout="full"):
    if activation_layout not in ("full", "sign-only"):
        raise AuditError("Unsupported activation layout " + activation_layout)
    errors = []
    activation_loads, enable_loads = loads_for(lanes, "xa"), loads_for(lanes, "ce")
    if activation_layout == "full":
        for bit, pins in activation_loads.items():
            if len({lane // 6 for lane, _ in pins}) != 1:
                errors.append("Activation net crosses six-lane groups: " + repr(bit))
    else:
        low_nets = []
        for pin in range(11):
            bits = [lanes[lane]["xa"][pin] for lane in range(24)]
            if len(set(bits)) != 1 or bits[0].constant is not None:
                errors.append(f"Shared xa[{pin}] must use one nonconstant net across all 24 lanes")
                continue
            net = bits[0]
            low_nets.append(net)
            if set(activation_loads[net]) != {(lane, pin) for lane in range(24)}:
                errors.append(f"Shared xa[{pin}] net has extra/missing loads")
        if len(set(low_nets)) != 11:
            errors.append(f"Expected eleven distinct shared low-bit nets, found {len(set(low_nets))}")
    for port, first, width, loads in (("xa", 11, 16, activation_loads), ("ce", 0, 4, enable_loads)):
        group_nets = []
        for group in range(4):
            pins = [lanes[lane][port][pin] for lane in range(group * 6, group * 6 + 6)
                    for pin in range(first, first + width)]
            if len(set(pins)) != 1 or pins[0].constant is not None:
                errors.append(f"Group {group} {port} must use one nonconstant net across {width * 6} pins")
                continue
            net = pins[0]
            group_nets.append(net)
            expected = {(lane, pin) for lane in range(group * 6, group * 6 + 6)
                        for pin in range(first, first + width)}
            if set(loads[net]) != expected:
                errors.append(f"Group {group} {port} net has extra/missing loads: {len(loads[net])}, expected {width * 6}")
        if len(set(group_nets)) != 4:
            errors.append(f"Expected four distinct {port} group nets, found {len(set(group_nets))}")
    return errors


def audit_file(path, candidate=False, activation_layout="full"):
    data = path.read_bytes()
    lanes = parse_netlist(data.decode("utf-8-sig"))
    activation = load_report(loads_for(lanes, "xa"), "xa")
    enables = load_report(loads_for(lanes, "ce"), "ce")
    return {
        "file": str(path.resolve()), "sha256": hashlib.sha256(data).hexdigest(),
        "lane_count": len(lanes), "activation_pin_count": 24 * 27, "enable_pin_count": 24 * 4,
        "max_activation_net_pins": max((item["pin_count"] for item in activation), default=0),
        "max_enable_net_pins": max((item["pin_count"] for item in enables), default=0),
        "activation_nets": activation, "enable_nets": enables,
        "lanes": [{"lane": lane, "instance": item["instance"],
                   "xa_lsb_first": [bit.as_dict() for bit in item["xa"]],
                   "ce_lsb_first": [bit.as_dict() for bit in item["ce"]]}
                  for lane, item in sorted(lanes.items())],
        "errors": candidate_errors(lanes, activation_layout) if candidate else [],
    }


def fixture(grouped=True, sign_only=False):
    lines = ["module test;", "wire [10:0] payload0, payload1, payload2, payload3;",
             "wire sign0,sign1,sign2,sign3,enable0,enable1,enable2,enable3;"]
    for lane in range(24):
        group = lane // 6 if grouped else 0
        low_group = 0 if sign_only else group
        lines.append(f"PH1P_PHY_DSPSIOU_V2 #(.XAREG(\"0\")) \\top/core/lanes[{lane}]$mac/u_siou  ("
                     f".xa({{{{16{{sign{group}}}}},payload{low_group}[10:0]}}),.ce({{4{{enable{group}}}}}));")
    return "\n".join(lines + ["endmodule\n"])


class ParserTests(unittest.TestCase):
    def test_grouped_and_shared(self):
        self.assertEqual(candidate_errors(parse_netlist(fixture())), [])
        baseline = parse_netlist(fixture(False))
        self.assertEqual(max(map(len, loads_for(baseline, "xa").values())), 384)
        self.assertEqual(max(map(len, loads_for(baseline, "ce").values())), 96)
        self.assertTrue(candidate_errors(baseline))

    def test_aliases_are_resolved(self):
        text = fixture().replace("wire sign0", "wire alias0;\nassign alias0=sign0;\nwire sign0")
        text = text.replace("16{sign1}", "16{alias0}")
        self.assertTrue(candidate_errors(parse_netlist(text)))

    def test_sign_only_layout_is_explicit(self):
        lanes = parse_netlist(fixture(sign_only=True))
        self.assertEqual(candidate_errors(lanes, "sign-only"), [])
        self.assertTrue(candidate_errors(lanes))
        self.assertTrue(candidate_errors(parse_netlist(fixture()), "sign-only"))
        self.assertTrue(candidate_errors(parse_netlist(fixture(False)), "sign-only"))

    def test_sign_only_rejects_incorrect_low_or_group_wiring(self):
        original = fixture(sign_only=True)
        for old, new in (("payload0[10:0]", "payload1[10:0]"),
                         ("payload0[10:0]", "11'b0"),
                         ("payload0[10:0]", "{payload0[10:1],payload0[1]}"),
                         ("payload0[10:0]", "{payload0[10:1],sign0}"),
                         ("16{sign0}", "16{sign1}"),
                         ("4{enable0}", "4{enable1}")):
            with self.subTest(old=old, new=new):
                lanes = parse_netlist(original.replace(old, new, 1))
                self.assertTrue(candidate_errors(lanes, "sign-only"))

    def test_escaped_identifier_comments_and_ranges(self):
        declarations = {"a//b": (0, 2), "low": (4, 0)}
        values = expand(tokens(without_comments("{\\a//b [0:2], /*x*/ low[4:3], 2'h3}")), declarations)
        self.assertEqual([bit.index for bit in values[:5]], [0, 1, 2, 4, 3])
        self.assertEqual([bit.constant for bit in values[-2:]], ["1", "1"])

    def test_missing_duplicate_and_truncated(self):
        original = fixture()
        for text in (original.replace("lanes[23]", "lanes[24]"),
                     original.replace("lanes[23]", "lanes[22]"), original.replace("endmodule", ""),
                     original.replace(".ce(", ".unused(", 1),
                     original.replace(".ce({4{enable0}})", ".ce({3{enable0}})", 1),
                     original.replace("16{sign0}", "16{unknown}", 1),
                     original.replace("16{sign0}", "16{sign0 & sign1}", 1)):
            with self.subTest(text=text[-50:]), self.assertRaises(AuditError):
                parse_netlist(text)

    def test_wrong_sign_or_enable(self):
        for old, new in (("16{sign0}", "16{1'b0}"), ("16{sign0}", "15{sign0}"),
                         ("4{enable0}", "4{enable1}")):
            text = fixture().replace(old, new, 1)
            try:
                self.assertTrue(candidate_errors(parse_netlist(text)))
            except AuditError:
                pass


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", nargs="?", type=Path)
    parser.add_argument("candidate", nargs="?", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--activation-layout", choices=("full", "sign-only"), default="full")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ParserTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.baseline is None or args.candidate is None or args.output is None:
        parser.error("baseline candidate --output are required")
    report = {"audit": "CNN_DSP_BROADCAST", "status": "FAIL", "activation_layout": args.activation_layout}
    try:
        report["baseline"] = audit_file(args.baseline)
        report["candidate"] = audit_file(args.candidate, candidate=True, activation_layout=args.activation_layout)
        if not report["candidate"]["errors"]:
            report["status"] = "PASS"
    except (AuditError, OSError, UnicodeError, ValueError) as error:
        report["error"] = str(error)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("CNN_DSP_BROADCAST_" + report["status"] + " " + str(args.output))
    for name in ("baseline", "candidate"):
        if name in report:
            print(f"{name}: lanes={report[name]['lane_count']} "
                  f"max_xa_loads={report[name]['max_activation_net_pins']} "
                  f"max_ce_loads={report[name]['max_enable_net_pins']}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
