"""Camera/image preview of the FPGA fixed-region classifier. No MediaPipe."""
import argparse
import json
from pathlib import Path
import time

import cv2
import numpy as np
import torch
from handfixed_reference import DEFAULT_MODEL, CLASSES, load_config, infer, patch, snapshot
from handfixed_stability import LABELS, ResultFilter
from handcnn_camera import open_camera, read_image

TITLE = 'Fixed ROI + hand7 CNN | FPGA integer model'


def render(rgb, result, config):
    frame = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    x, y, side = config['roi']
    cv2.rectangle(frame, (x, y), (x+side, y+side), (0, 230, 255), 3)
    cv2.putText(frame, 'Put ONE complete hand inside the square', (x-70, y-24),
                cv2.FONT_HERSHEY_SIMPLEX, .7, (0, 230, 255), 2)
    cv2.putText(frame, result['label'], (28, 52), cv2.FONT_HERSHEY_SIMPLEX, 1.3, (60, 240, 120), 3)
    canvas = np.full((720, 1600, 3), 25, dtype=np.uint8)
    canvas[:, :1280] = frame
    lines = ['Fixed ROI: 480 x 480', 'Input: 96 x 96 RGB', 'Frozen hand7: 156,675',
             f"Processing: {result['milliseconds']:.1f} ms", '',
             'Raw CNN probabilities:',
             *[f'{c}: {p:.1%}' for c, p in zip(CLASSES, result['probabilities'])],
             f"Raw result: {result.get('raw_label', result['label'])}",
             'Confirm: acquire 2 / switch 3' if 'raw_label' in result else 'Single image: raw result',
             'Reject: 3; flat: immediate', 'Threshold: 0.65', 'Q / Esc: exit']
    for i, text in enumerate(lines):
        cv2.putText(canvas, text, (1300, 40+29*i), cv2.FONT_HERSHEY_SIMPLEX, .53, (235, 235, 235), 1)
    canvas[500:692, 1338:1530] = cv2.resize(cv2.cvtColor(patch(rgb, config), cv2.COLOR_RGB2BGR), (192, 192), interpolation=cv2.INTER_NEAREST)
    return canvas


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', type=Path, default=DEFAULT_MODEL)
    p.add_argument('--camera', type=int, default=0)
    p.add_argument('--image', type=Path)
    p.add_argument('--save', type=Path)
    p.add_argument('--threads', type=int, default=4)
    args = p.parse_args()
    if args.threads < 1 or (args.save and not args.image): p.error('--save requires --image; threads must be positive')
    torch.set_num_threads(args.threads)
    cv2.setNumThreads(args.threads)
    config = load_config(args.manifest)
    def process(frame):
        started = time.perf_counter()
        rgb, _ = snapshot(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        result = infer(rgb, config)
        result['milliseconds'] = (time.perf_counter()-started)*1000
        return rgb, result
    if args.image:
        rgb, result = process(read_image(args.image))
        if args.save:
            args.save.parent.mkdir(parents=True, exist_ok=True)
            ok, data = cv2.imencode(args.save.suffix, render(rgb, result, config))
            if not ok: raise ValueError('Cannot encode preview')
            data.tofile(args.save)
        print(json.dumps(result))
        return
    cap, _ = open_camera(args.camera)
    result_filter = ResultFilter()
    try:
        cv2.namedWindow(TITLE, cv2.WINDOW_NORMAL)
        print('Window ready: '+TITLE, flush=True)
        while True:
            ok, frame = cap.read()
            if not ok: raise RuntimeError('Camera stopped delivering frames')
            rgb, result = process(frame)
            result['raw_label'] = result['label']
            result['raw_class_id'] = result['class_id']
            result['class_id'] = result_filter.update(result['class_id'], clear=not result['has_texture'])
            result['label'] = LABELS[result['class_id']-1]
            cv2.imshow(TITLE, render(rgb, result, config))
            if cv2.waitKey(1) & 255 in (27, ord('q')) or cv2.getWindowProperty(TITLE, cv2.WND_PROP_VISIBLE) < 1: break
    finally:
        cap.release()
        cv2.destroyAllWindows()


if __name__ == '__main__': main()
