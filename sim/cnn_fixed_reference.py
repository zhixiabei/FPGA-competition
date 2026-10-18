"""Independent arithmetic reference for the CNN's exported integer weights.

This verifies RTL arithmetic and the original exported parameter values, not
recognition accuracy. The checkpoint does not include its preprocessing
definition or labeled test images.
Weight byte zero is the least significant byte of the Verilog packed literal.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]
PIXELS = 32 * 32
# Digests of the original fpga_weights exports, normalized in address order.
# Bias values use four big-endian bytes; weights use one two's-complement byte.
EXPORT_SHA256 = {
    "w1": "a987fe609472062076e4b8bcd7081de3f97457efbb68adae805259c950efcc4b",
    "w2": "3810eab758ae3fcaeedca53c2646e3152c7e37df7e06a8cced22186655845b22",
    "wf": "aaabb4194f85599395e25108f6f44d657d7a2dd3b2ccdb686d05bd3b470e05e7",
    "b1": "4e7fa276c1e33a07b2ede9b076c775d7b39b8b82cb06d1e1cf35dd5495061ffe",
    "b2": "2a71686ce03f389f086366a0fefa175d94f72292a7b3f2a76c0cda652247e9ed",
    "bf": "0232a7a6c24375cb52e0616a487bc9c887e82ec68b4f5efafe11eaeec1a88b75",
}


@dataclass(frozen=True)
class Weights:
    w1: tuple[int, ...]
    w2: tuple[int, ...]
    wf: tuple[int, ...]
    b1: tuple[int, ...]
    b2: tuple[int, ...]
    bf: tuple[int, ...]


@dataclass(frozen=True)
class FixedResult:
    capture: tuple[int, ...]
    conv1: tuple[int, ...]
    conv2: tuple[int, ...]
    pool: tuple[int, ...]
    logits: tuple[int, ...]
    class_index: int
    conv1_saturated: int
    conv2_saturated: int
    c1_shift: int
    c2_shift: int


def verify_weight_provenance(weights: Weights) -> dict:
    tensors = {}
    for name, expected in EXPORT_SHA256.items():
        values = getattr(weights, name)
        width = 1 if name.startswith("w") else 4
        mask = (1 << (width * 8)) - 1
        raw = b"".join((value & mask).to_bytes(width, "big") for value in values)
        digest = hashlib.sha256(raw).hexdigest()
        if digest != expected:
            raise ValueError(
                f"{name}: RTL parameters do not match the pinned original export; "
                "refusing to generate a golden reference from damaged weights"
            )
        tensors[name] = {"count": len(values), "sha256": digest}
    return tensors


def verify_original_exports(directory: Path, weights: Weights) -> None:
    for name in EXPORT_SHA256:
        bits = 8 if name.startswith("w") else 32
        raw = tuple(int(word, 16) for word in (directory / f"{name}.mem").read_text().split())
        if any(value < 0 or value >= 2**bits for value in raw):
            raise ValueError(f"{name}.mem: value does not fit {bits} bits")
        values = tuple(value if value < 2**(bits - 1) else value - 2**bits for value in raw)
        rtl = getattr(weights, name)
        if len(values) != len(rtl):
            raise ValueError(f"{name}.mem: count {len(values)} != RTL count {len(rtl)}")
        for index, (exported, actual) in enumerate(zip(values, rtl)):
            if exported != actual:
                raise ValueError(
                    f"{name}[{index}]: original export {exported} != RTL {actual}"
                )


def load_weights(path: Path | str = ROOT / "user_source/hdl_source/cnn/cnn_weights.v") -> Weights:
    text = Path(path).read_text(encoding="utf-8")

    def packed(name: str, count: int) -> tuple[int, ...]:
        match = re.search(
            r"localparam\s*\[\s*8\*(\d+)-1:0\s*\]\s*"
            + re.escape(name)
            + r"\s*=\s*(\d+)'h([0-9a-fA-F_]+)",
            text,
        )
        if match is None:
            raise ValueError(f"Missing packed weight {name}")
        declared_bytes, literal_bits = int(match[1]), int(match[2])
        digits = match[3].replace("_", "")
        if declared_bytes != count or literal_bits != count * 8:
            raise ValueError(f"{name}: expected {count} bytes / {count * 8} bits")
        if len(digits) != count * 2:
            raise ValueError(
                f"{name}: expected exactly {count * 2} hex digits, got {len(digits)}; "
                "refusing silent Verilog padding or MSB truncation"
            )
        return tuple(v if v < 128 else v - 256 for v in bytes.fromhex(digits)[::-1])

    def biases(name: str, count: int) -> tuple[int, ...]:
        values = []
        for index in range(count):
            match = re.search(
                rf"\b{name}_{index}\s*=\s*32'h([0-9a-fA-F]{{8}})\b", text
            )
            if match is None:
                raise ValueError(f"Missing signed bias {name}_{index}")
            value = int(match[1], 16)
            values.append(value if value < 2**31 else value - 2**32)
        return tuple(values)

    weights = Weights(
        packed("W1", 72), packed("W2", 1152), packed("WF", 80),
        biases("B1", 8), biases("B2", 16), biases("BF", 5),
    )
    verify_weight_provenance(weights)
    return weights


def _capture_values(image: Sequence[int]) -> tuple[int, ...]:
    values = tuple(int(v) for v in image)
    if len(values) != PIXELS or any(v < 0 or v > 127 for v in values):
        raise ValueError("Expected exactly 1024 captured grayscale codes in 0..127")
    return values


def _conv_same(
    inputs: Sequence[int | float],
    input_channels: int,
    outputs: int,
    weights: Sequence[int | float],
    biases: Sequence[int | float],
) -> list[int | float]:
    # This direct spatial implementation intentionally has no RAM timing or
    # kernel-counter state in common with the RTL implementation.
    result: list[int | float] = []
    for output in range(outputs):
        weight_base = output * input_channels * 9
        for y in range(32):
            for x in range(32):
                value = biases[output]
                for channel in range(input_channels):
                    for ky in range(3):
                        iy = y + ky - 1
                        if not 0 <= iy < 32:
                            continue
                        for kx in range(3):
                            ix = x + kx - 1
                            if 0 <= ix < 32:
                                value += (
                                    inputs[channel * PIXELS + iy * 32 + ix]
                                    * weights[weight_base + channel * 9 + ky * 3 + kx]
                                )
                result.append(value)
    return result


def _scale_bias(value: int, fractional_bits: int) -> int:
    difference = fractional_bits - 14
    return value << difference if difference >= 0 else value >> -difference


def fixed_forward(
    image: Sequence[int],
    weights: Weights | None = None,
    c1_shift: int = 8,
    c2_shift: int = 9,
) -> FixedResult:
    weights = weights or load_weights()
    capture = _capture_values(image)
    if not 0 <= c1_shift <= 14 or not 0 <= c2_shift <= 21 - c1_shift:
        raise ValueError("Unsupported shifts: activation fractional bits must stay nonnegative")

    # Captured pixels and weights have seven fractional bits. C1's
    # accumulator therefore has fourteen; C2 must use the new C1 scale.
    c1_fraction = 14 - c1_shift
    c2_fraction = c1_fraction + 7 - c2_shift
    c1_acc = _conv_same(capture, 1, 8, weights.w1, weights.b1)
    conv1 = tuple(min(127, max(0, int(value) >> c1_shift)) for value in c1_acc)
    b2 = tuple(_scale_bias(value, c1_fraction + 7) for value in weights.b2)
    c2_acc = _conv_same(conv1, 8, 16, weights.w2, b2)
    conv2 = tuple(min(127, max(0, int(value) >> c2_shift)) for value in c2_acc)

    # Retain the full spatial sum. Dividing by 1024 before FC would discard
    # ten bits and, with Q4 C2 output, most small feature differences.
    pool = tuple(sum(conv2[c * PIXELS:(c + 1) * PIXELS]) for c in range(16))
    fc_fraction = c2_fraction + 10 + 7
    logits = tuple(
        _scale_bias(weights.bf[output], fc_fraction)
        + sum(pool[c] * weights.wf[output * 16 + c] for c in range(16))
        for output in range(5)
    )
    if any(value >= 2**17 for value in pool):
        raise AssertionError("GAP sum overflowed the RTL's 17-bit storage")
    if any(not -(2**31) <= value < 2**31 for value in logits):
        raise AssertionError("FC accumulator overflowed signed 32-bit storage")
    return FixedResult(
        capture, conv1, conv2, pool, logits,
        max(range(5), key=lambda c: logits[c]),
        sum((int(value) >> c1_shift) > 127 for value in c1_acc),
        sum((int(value) >> c2_shift) > 127 for value in c2_acc),
        c1_shift, c2_shift,
    )


def float_forward(image: Sequence[int], weights: Weights | None = None) -> dict:
    """Continuous arithmetic on the *exported* coefficients, not model.pt."""
    weights = weights or load_weights()
    capture = tuple(value / 128.0 for value in _capture_values(image))
    conv1 = tuple(max(0.0, value) for value in _conv_same(
        capture, 1, 8, tuple(v / 128.0 for v in weights.w1),
        tuple(v / 16384.0 for v in weights.b1),
    ))
    conv2 = tuple(max(0.0, value) for value in _conv_same(
        conv1, 8, 16, tuple(v / 128.0 for v in weights.w2),
        tuple(v / 16384.0 for v in weights.b2),
    ))
    gap = tuple(sum(conv2[c * PIXELS:(c + 1) * PIXELS]) / PIXELS for c in range(16))
    logits = tuple(
        weights.bf[output] / 16384.0
        + sum(gap[c] * weights.wf[output * 16 + c] / 128.0 for c in range(16))
        for output in range(5)
    )
    return {"conv1": conv1, "conv2": conv2, "gap": gap, "logits": logits}


def sample_capture(sample: int) -> tuple[int, ...]:
    values = []
    for sy in range(32):
        for sx in range(32):
            red = (sx * 13 + sy * 7 + sample * 31) & 255
            green = (sx * 3 + sy * 17 + sample * 47) & 255
            blue = (sx * 19 + sy * 5 + sample * 61) & 255
            values.append(((red + 2 * green + blue) >> 2) >> 1)
    return tuple(values)


def _errors(codes: Sequence[int], reference: Sequence[float], fractional_bits: int) -> dict:
    errors = [abs(value / 2**fractional_bits - ref) for value, ref in zip(codes, reference)]
    return {
        "mean_absolute_error": sum(errors) / len(errors),
        "max_absolute_error": max(errors),
    }


def export_vectors(output_dir: Path, samples: int = 2) -> dict:
    weights = load_weights()
    output_dir.mkdir(parents=True, exist_ok=True)
    metadata = {
        "purpose": "Arithmetic regression only; synthetic inputs are not a recognition test set.",
        "original_export_tensors": verify_weight_provenance(weights),
        "weight_counts": {"W1": len(weights.w1), "W2": len(weights.w2), "WF": len(weights.wf)},
        "c1_shift": 8,
        "c2_shift": 9,
        "fractional_bits": {"capture": 7, "conv1": 6, "conv2": 4, "pool_as_gap": 14, "logits": 21},
        "layout": "channel, row, column; x changes fastest; packed RTL weight byte 0 is LSB",
        "samples": [],
    }

    def hex_file(name: str, values: Sequence[int], bits: int) -> None:
        digits = math.ceil(bits / 4)
        mask = (1 << bits) - 1
        (output_dir / name).write_text(
            "".join(f"{value & mask:0{digits}x}\n" for value in values), encoding="ascii"
        )

    for sample in range(samples):
        capture = sample_capture(sample)
        result = fixed_forward(capture, weights)
        continuous = float_forward(capture, weights)
        prefix = f"sample{sample}"
        hex_file(f"{prefix}_capture.hex", result.capture, 8)
        hex_file(f"{prefix}_c1.hex", result.conv1, 8)
        hex_file(f"{prefix}_c2.hex", result.conv2, 8)
        # gap.hex is a diagnostic floor(mean), not the FC input. pool.hex is
        # the exact unsigned spatial sum consumed by the fixed RTL FC.
        hex_file(f"{prefix}_gap.hex", tuple(value >> 10 for value in result.pool), 8)
        hex_file(f"{prefix}_pool.hex", result.pool, 32)
        hex_file(f"{prefix}_logits.hex", result.logits, 32)
        hex_file(f"{prefix}_class.hex", (result.class_index,), 8)
        metadata["samples"].append({
            "sample": sample,
            "class_index": result.class_index,
            "logits": result.logits,
            "pool": result.pool,
            "conv1_saturated_count": result.conv1_saturated,
            "conv2_saturated_count": result.conv2_saturated,
            "error_against_continuous_exported_coefficients": {
                "conv1": _errors(result.conv1, continuous["conv1"], 6),
                "conv2": _errors(result.conv2, continuous["conv2"], 4),
                "gap": _errors(result.pool, continuous["gap"], 14),
                "logits": _errors(result.logits, continuous["logits"], 21),
            },
        })
    (output_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="ascii"
    )
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir", "--output", dest="output_dir",
        type=Path, default=ROOT / "tmp/cnn_fixed_vectors",
    )
    parser.add_argument("--samples", type=int, default=2)
    parser.add_argument(
        "--verify-exports", type=Path,
        help="Also compare every RTL parameter with this original fpga_weights directory",
    )
    parser.add_argument(
        "--check-weights-only", action="store_true",
        help="Check parameter dimensions, exact literal lengths and original export digests",
    )
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("--samples must be positive")
    weights = load_weights()
    if args.verify_exports is not None:
        verify_original_exports(args.verify_exports, weights)
    if args.check_weights_only:
        print(json.dumps(verify_weight_provenance(weights), indent=2))
        print("CNN_WEIGHT_EXPORT_PASS scalars=1333")
        return
    metadata = export_vectors(args.output_dir, args.samples)
    print(json.dumps(metadata, indent=2))
    print(f"CNN_FIXED_REFERENCE_PASS vectors={args.output_dir.resolve()}")


if __name__ == "__main__":
    main()
