"""Use this bundle's new checkpoint on an image or camera."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'source'))
from predict_fruitcnn128 import main


if __name__ == '__main__':
    if '--checkpoint' not in sys.argv:
        sys.argv[1:1] = ['--checkpoint', str(ROOT / 'training/model.pt')]
    main()
