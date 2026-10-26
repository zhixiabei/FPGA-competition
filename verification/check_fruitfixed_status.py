"""Verify the FRU1 status reader against a fixed binary protocol fixture."""
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
payload = struct.pack('<4sBBBBHH5hIIH', b'FRU1', 1, 0x43, 0xDE, 0,
                      14, 9, 1, 2, 3, 4, 5, 100_000, 200_000, 300)
assert len(payload) == 32
response = payload + struct.pack('<I', zlib.crc32(payload))
with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory) / 'fruit_status.bin'
    fixture.write_bytes(response)
    command = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
               str(ROOT / 'verification/read_handfixed_status.ps1'),
               '-Fruit', '-ResponseFile', str(fixture),
               '-Project', str(ROOT/'build/fruit/td')]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    status = json.loads(result.stdout)
    assert status['last_display'] == 'STRAWBERRY', status
    assert status['logits'] == [1, 2, 3, 4, 5], status
    assert status['completed_results'] == 14, status
    assert status['processing_cycles'] == 100_000, status
    assert status['cumulative_core_cycles'] == 200_000, status
    assert status['cumulative_mac_issue_cycles'] == 300, status
    assert status['background_ready'] and status['recognition_enabled'], status
    wrong_firmware = subprocess.run(command[:6] + command[7:], capture_output=True, text=True)
    assert wrong_firmware.returncode != 0, wrong_firmware.stdout
print('FRUIT_STATUS_READER_PASS magic_crc_five_logits_counters_class')
