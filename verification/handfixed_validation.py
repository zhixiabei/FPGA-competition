"""Shared helpers for the retained board protocol checks."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import zlib
ROOT=Path(__file__).resolve().parents[1]
CHECKS=ROOT/'build/gesture/checks'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_log(path):
    data = path.read_bytes()
    return data.decode('utf-16' if data.startswith(b'\xff\xfe') else 'utf-8', errors='replace')


def check_status():
    template = bytearray((ROOT/'build/gesture/weights/status_fixture.bin').read_bytes()[:32])
    cases = [
        ('legacy', 3, 2, False, True, False, 'PUNCH'),
        ('paused_boot', 0x81, 0, True, False, False, 'NOTHING'),
        ('started_boot', 0xc1, 0, True, True, False, 'NOTHING'),
        ('running', 0xc4, 2, True, True, False, 'STOP'),
        ('stopped_draining', 0xa1, 2, True, False, True, 'NOTHING'),
        ('restarted_draining', 0xe1, 2, True, True, True, 'NOTHING'),
        ('stopped_idle', 0x81, 2, True, False, False, 'NOTHING'),
    ]
    for name, class_byte, count, manual, enabled, draining, display in cases:
        packet = bytearray(template)
        packet[5] |= 64
        packet[6] = class_byte
        struct.pack_into('<H', packet, 8, count)
        packet.extend(struct.pack('<I', zlib.crc32(packet)))
        path = CHECKS/f'status_{name}.bin'
        path.write_bytes(packet)
        result = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                                 str(ROOT/'verification/read_handfixed_status.ps1'), '-ResponseFile', str(path)],
                                capture_output=True, check=True)
        parsed = json.loads(result.stdout)
        assert parsed['temporal_confirmation']
        assert parsed['manual_key4_control'] == manual, name
        assert parsed['recognition_enabled'] == enabled, name
        assert parsed['old_work_draining'] == draining, name
        assert not parsed['background_control'] and not parsed['background_ready'], name
        assert parsed['last_display'] == display, name
        assert parsed['logits'] == [-5680,10127,-3639], name
    return len(cases)


