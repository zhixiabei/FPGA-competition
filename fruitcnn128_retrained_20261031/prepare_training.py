"""Freeze the selected dataset and original RGB128 training implementation."""
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path
import random
import shutil
import sys

import cv2
import numpy as np
from PIL import Image, ImageOps

ROOT = next(p for p in Path(__file__).resolve().parents if (p / 'verification/train_fruitcnn128.py').is_file())
SELECTED = ROOT / 'fruits5_selected_20261031'
BUNDLE = ROOT / 'fruitcnn128_retrained_20261031'
CLASSES = ['apple', 'banana', 'grape', 'orange', 'strawberry']
SEED = 20261024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    cv2.setNumThreads(1)
    BUNDLE.mkdir(exist_ok=False)
    source = BUNDLE / 'source'
    source.mkdir()
    names = ['train_fruitcnn128.py', 'fruitcnn128.py', 'fruitcnn.py', 'fruitcnn_training.py',
             'handcnn_model.py', 'handcnn_training_utils.py', 'handfixed_math.py',
             'clean_fruit_datasets.py', 'fruit_cleaning_review.json', 'predict_fruitcnn128.py']
    for name in names:
        shutil.copy2(ROOT / 'verification' / name, source / name)
    manifest = json.loads((SELECTED / 'dataset_manifest.json').read_text(encoding='utf-8'))
    inventory = {r['id']: r for r in json.loads((ROOT / 'build/fruit_dataset_review_20261031/inventory.json').read_text(encoding='utf-8'))}
    parent = list(range(len(manifest['samples'])))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i, j):
        parent[find(i)] = find(j)

    rows, known = [], {}
    for i, sample in enumerate(manifest['samples']):
        path = SELECTED / sample['path']
        assert sha(path.read_bytes()) == sample['sha256']
        with Image.open(path) as im:
            image = ImageOps.exif_transpose(im).convert('RGB')
            pixel96 = ImageOps.pad(image, (96, 96), method=Image.Resampling.BILINEAR, color=(124, 116, 104))
            thumb = np.asarray(image.resize((16, 16)), dtype=np.int16)
            gray = np.asarray(image.convert('L').resize((9, 8)))
            dct = cv2.dct(np.asarray(image.convert('L').resize((32, 32)), dtype=np.float32))[:8, :8]
            dhash = int.from_bytes(np.packbits(gray[:, 1:] > gray[:, :-1]).tobytes(), 'big')
            phash = int.from_bytes(np.packbits(dct > np.median(dct.flatten()[1:])).tobytes(), 'big')
        row = dict(sample, input_sha256=sha(np.asarray(pixel96).transpose(2, 0, 1).tobytes()),
                   _thumb=thumb, _dhash=dhash, _phash=phash)
        rows.append(row)
        group_keys = [('file', sample['sha256']), ('input96', row['input_sha256'])]
        for alias in sample['source_aliases']:
            previous = inventory[alias['id']].get('previous_group')
            if previous:
                group_keys.append(('previous_group', previous))
            if alias['source'] == 'pictures':
                group_keys.append(('phone_capture', sample['label']))
        for key in group_keys:
            if key in known:
                union(i, known[key])
            else:
                known[key] = i
        for j, other in enumerate(rows[:i]):
            dh = (dhash ^ other['_dhash']).bit_count()
            ph = (phash ^ other['_phash']).bit_count()
            if dh <= 6 or ph <= 6:
                distance = float(np.abs(thumb - other['_thumb']).mean())
                if (dh <= 6 and distance <= 14) or (ph <= 6 and distance <= 10):
                    union(i, j)
    groups = defaultdict(list)
    for i, row in enumerate(rows):
        groups[find(i)].append(row)
    rng = random.Random(SEED)
    split_counts, group_report = {}, []
    for label in CLASSES:
        class_groups = [g for g in groups.values() if g[0]['label'] == label]
        assert all({r['label'] for r in g} == {label} for g in class_groups)
        total = sum(map(len, class_groups))
        n_holdout = round(total * .15)
        targets = dict(train=total - 2 * n_holdout, validation=n_holdout, test=n_holdout)
        counts = Counter()
        pinned, remaining = [], []
        for group in class_groups:
            (pinned if any(any(a['source'] == 'pictures' for a in r['source_aliases']) for r in group) else remaining).append(group)
        rng.shuffle(remaining)
        remaining.sort(key=lambda g: -len(g))
        pinned_ids = {id(g) for g in pinned}
        for group in pinned + remaining:
            split = 'train' if id(group) in pinned_ids else min(targets, key=lambda sp: sum(
                (counts[k] + (len(group) if k == sp else 0) - targets[k]) ** 2 for k in targets))
            counts[split] += len(group)
            group_id = 'selected_' + sha('\n'.join(sorted(r['path'] for r in group)).encode())[:20]
            for row in group:
                row['split'], row['group'] = split, group_id
            group_report.append(dict(group=group_id, label=label, split=split, size=len(group),
                                     paths=[r['path'] for r in group], phone_capture=id(group) in pinned_ids))
        split_counts[label] = dict(counts)
        assert all(counts[s] for s in targets)
    samples = []
    for row in rows:
        relative = Path(row['split']) / row['path']
        target = BUNDLE / 'data' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SELECTED / row['path'], target)
        samples.append(dict(path=str(target.resolve()), target=CLASSES.index(row['label']), label=row['label'],
                            source_class=row['label'], source_sha256=row['sha256'], input_sha256=row['input_sha256'],
                            split=row['split'], group=row['group'], dataset=row['source'],
                            original_path=str((SELECTED / row['path']).resolve()),
                            original_sha256=row['source_sha256'], selected_id=row['source_id']))
    data_manifest = dict(root=str((BUNDLE / 'data').resolve()), classes=CLASSES, samples=samples,
                         source_roots={'selected': str(SELECTED.resolve())}, seed=SEED,
                         split_policy='stratified target 70/15/15 by duplicate groups; all phone capture sequences pinned to train',
                         group_policy='previous duplicate groups plus file/RGB96 hashes and conservative dHash/pHash with RGB similarity; all phone photos of each class one capture group')
    save(BUNDLE / 'data/data_manifest.json', data_manifest)
    with (BUNDLE / 'data/data_manifest.csv').open('w', encoding='utf-8-sig', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(samples[0]))
        writer.writeheader()
        writer.writerows(samples)
    save(BUNDLE / 'data/split_groups.json', group_report)
    split_report = dict(total=len(samples), classes=CLASSES, class_splits=split_counts,
                        split_totals=dict(Counter(s['split'] for s in samples)),
                        groups=len(group_report), selected_manifest_sha256=sha((SELECTED / 'dataset_manifest.json').read_bytes()),
                        phone_policy='All phone photos are training-only because the same fruit specimens were photographed repeatedly in both lighting settings; held-out metrics use web photos.')
    save(BUNDLE / 'data/split_report.json', split_report)
    old = json.loads((ROOT / 'build/fruit/training/run_config.json').read_text(encoding='utf-8'))
    save(BUNDLE / 'previous_model_config.json', old)
    save(BUNDLE / 'source_snapshot.json', {name:sha((source / name).read_bytes()) for name in names})
    save(BUNDLE / 'baseline_checkpoint.json', dict(path=str((ROOT / 'build/fruit/training/model.pt').resolve()),
         sha256=sha((ROOT / 'build/fruit/training/model.pt').read_bytes()), used_for_initialization=False))
    shutil.copy2(__file__, BUNDLE / 'prepare_training.py')
    print(json.dumps(split_report, indent=2))


if __name__ == '__main__':
    main()
