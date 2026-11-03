"""Regression for missing/disabled TD voice files; no HDL tools required."""
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import xml.etree.ElementTree as ET

from check_merge_readiness import ROOT, check_project


class VoiceProjectSourcesTest(unittest.TestCase):
    def project(self, directory, omitted=None, disabled_syn=None,
                disabled_route=None, excluded=None):
        sources = ET.Element('Source_Files')
        verilog = ET.SubElement(sources, 'Verilog')
        voice = ROOT / 'user_source/hdl_source/voice'
        paths = [
            *(ROOT / 'user_source/hdl_source' / name for name in (
                'design_top_wrapper.v', 'pen_minimal.v', 'signature_control.v')),
            *sorted(voice.glob('*.v')),
        ]
        for path in paths:
            if path.name == omitted:
                continue
            entry = ET.SubElement(verilog, 'File', Path=path.as_posix())
            info = ET.SubElement(entry, 'FileInfo')
            ET.SubElement(info, 'Attr', Name='UsedInSyn',
                          Val='false' if path.name == disabled_syn else 'true')
            ET.SubElement(info, 'Attr', Name='UsedInP&R',
                          Val='false' if path.name == disabled_route else 'true')
            if path.name == excluded:
                ET.SubElement(info, 'Attr', Name='AutoExcluded', Val='true')
        project = Path(directory) / 'voice_sources.al'
        project.write_text(ET.tostring(sources, encoding='unicode'), encoding='utf-8')
        return project

    def test_complete(self):
        with TemporaryDirectory() as directory, redirect_stdout(StringIO()):
            check_project(self.project(directory))

    def test_missing_or_disabled(self):
        for name in ('cx_sp5t_uart', 'scale_voice_stable', 'scale_voice_phrase',
                     'scale_voice_auto', 'checkout_voice_bridge'):
            for state in ('omitted', 'disabled_syn', 'disabled_route'):
                with self.subTest(module=name, state=state), TemporaryDirectory() as directory:
                    project = self.project(directory, **{state: name + '.v'})
                    with self.assertRaisesRegex(ValueError, 'missing or disabled voice source ' + name):
                        check_project(project)

    def test_auto_excluded_cache_does_not_disable_source(self):
        for name in ('cx_sp5t_uart', 'scale_voice_stable', 'scale_voice_phrase',
                     'scale_voice_auto', 'checkout_voice_bridge'):
            with self.subTest(module=name), TemporaryDirectory() as directory:
                with redirect_stdout(StringIO()):
                    check_project(self.project(directory, excluded=name + '.v'))

    def test_auto_excluded_cache_does_not_override_flow_selector(self):
        for state in ('disabled_syn', 'disabled_route'):
            with self.subTest(state=state), TemporaryDirectory() as directory:
                project = self.project(directory, excluded='checkout_voice_bridge.v',
                                       **{state: 'checkout_voice_bridge.v'})
                with self.assertRaisesRegex(ValueError,
                                            'missing or disabled voice source checkout_voice_bridge'):
                    check_project(project)


if __name__ == '__main__':
    unittest.main()
