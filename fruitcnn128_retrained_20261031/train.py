"""Train the original shape/color/texture CNN using this bundle's frozen split."""
import contextlib
from datetime import datetime
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'source'))
from train_fruitcnn128 import main


class Tee:
    def __init__(self, console, log):
        self.console, self.log = console, log

    def write(self, text):
        self.console.write(text)
        self.log.write(text)
        self.log.flush()
        return len(text)

    def flush(self):
        self.console.flush()
        self.log.flush()


if __name__ == '__main__':
    supplied = sys.argv[1:]
    config = json.loads((ROOT / 'previous_model_config.json').read_text(encoding='utf-8'))
    args = []
    for key, value in config['training'].items():
        if key in {'manifest', 'output', 'resume', 'stop_after', 'check_data_only'}:
            continue
        option = '--' + key.replace('_', '-')
        args.extend([option if value else '--no-' + key.replace('_', '-')]
                    if isinstance(value, bool) else [option, str(value)])
    if '--resume' not in supplied:
        output = ROOT / 'training'
        if output.exists() and '--check-data-only' not in supplied:
            output = ROOT / 'runs' / datetime.now().strftime('%Y%m%d_%H%M%S_%f')
        args += ['--manifest', str(ROOT / 'data/data_manifest.json'), '--output', str(output)]
    logs = ROOT / 'logs'
    logs.mkdir(exist_ok=True)
    with (logs / datetime.now().strftime('train_%Y%m%d_%H%M%S_%f.log')).open('w', encoding='utf-8') as log:
        with contextlib.redirect_stdout(Tee(sys.stdout, log)), contextlib.redirect_stderr(Tee(sys.stderr, log)):
            main(args + supplied)
