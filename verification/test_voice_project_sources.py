"""Regression for missing/disabled TD voice files; no HDL tools required."""
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import xml.etree.ElementTree as ET

from check_merge_readiness import ROOT, check_project


class VoiceProjectSourcesTest(unittest.TestCase):
    def project(self, directory, omitted=None, disabled=None, excluded=None):
        sources = ET.Element('Source_Files')
        verilog = ET.SubElement(sources, 'Verilog')
        voice = ROOT / 'user_source/hdl_source/voice'
        paths = [ROOT / 'user_source/hdl_source/design_top_wrapper.v', *sorted(voice.glob('*.v'))]
        for path in paths:
            if path.name == omitted:
                continue
            entry = ET.SubElement(verilog, 'File', Path=path.as_posix())
            info = ET.SubElement(entry, 'FileInfo')
            ET.SubElement(info, 'Attr', Name='UsedInSyn', Val='false' if path.name == disabled else 'true')
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
            for state in ('omitted', 'disabled', 'excluded'):
                with self.subTest(module=name, state=state), TemporaryDirectory() as directory:
                    project = self.project(directory, **{state: name + '.v'})
                    with self.assertRaisesRegex(ValueError, 'missing or disabled voice source ' + name):
                        check_project(project)


if __name__ == '__main__':
    unittest.main()
