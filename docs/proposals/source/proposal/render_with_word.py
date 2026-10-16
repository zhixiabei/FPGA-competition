"""Use the skill renderer with the installed Word PDF engine on Windows."""
import importlib.util
import subprocess
import sys
from pathlib import Path

skill = Path(r'C:\Users\1\.codex\plugins\cache\openai-primary-runtime\documents\26.903.11726\skills\documents')
spec = importlib.util.spec_from_file_location('render_docx', skill / 'render_docx.py')
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

def word_pdf(doc_path, user_profile, convert_tmp_dir, stem, verbose):
    target = str(Path(convert_tmp_dir) / (stem + '.pdf'))
    ps = Path(__file__).with_name('export_word.ps1')
    result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(ps), '-InputDoc', doc_path, '-OutputPdf', target], capture_output=True, text=True, errors='replace', timeout=90)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    print(result.stdout.strip())
    return target, result.stdout

renderer.convert_to_pdf = word_pdf
renderer.main()
