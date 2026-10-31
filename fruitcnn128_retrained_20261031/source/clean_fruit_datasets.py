"""Clean both fruit sources without changing originals; freeze one global split.

Only conservative duplicate/quality rules are automatic. Semantic exclusions
are explicit, reviewed entries in fruit_cleaning_review.json, not a guessed
image classifier. Near duplicates are connected across both sources BEFORE
splitting, and one representative per group is retained for combined training.
"""
import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path
import random

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / 'build/fruits_clean_v1'
EXTENSIONS = {'.jpg', '.jpeg', '.png', '.bmp', '.webp'}
SPLITS = ('train', 'validation', 'test')


def digest(payload):
    return hashlib.sha256(payload).hexdigest()


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def rgb_image(path):
    with Image.open(path) as source:
        source.load()
        image = ImageOps.exif_transpose(source)
        # Transparent images should not acquire a black fruit-shaped background.
        if image.mode in ('RGBA', 'LA') or 'transparency' in image.info:
            rgba = image.convert('RGBA')
            background = Image.new('RGBA', image.size, 'white')
            image = Image.alpha_composite(background, rgba)
        return image.convert('RGB')


def training_input_hash(image):
    padded = ImageOps.pad(image, (96,96), method=Image.Resampling.BILINEAR,
                          color=(124,116,104))
    # Manifest loader hashes CHW torch tensors; grouping hashes above are HWC.
    return digest(np.asarray(padded).transpose(2,0,1).tobytes())


def describe(path):
    image = rgb_image(path)
    width, height = image.size
    rgb = np.asarray(image.resize((96, 96), Image.Resampling.BILINEAR))
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    thumbnail = np.asarray(image.resize((16, 16)), dtype=np.int16)
    dh = np.asarray(image.convert('L').resize((9, 8)))
    padded = ImageOps.pad(image, (96, 96), method=Image.Resampling.BILINEAR,
                          color=(124, 116, 104))
    spread = float(gray.std())
    blur = float(cv2.Laplacian(gray, cv2.CV_32F).var())
    hard = []
    if min(width, height) < 32:
        hard.append('dimension_below_32')
    if spread < 2 and int(gray.max()) - int(gray.min()) < 12:
        hard.append('nearly_constant_image')
    flags = []
    if min(width, height) < 96:
        flags.append('low_resolution')
    if blur < 8:
        flags.append('low_detail_or_blur')
    if max(width, height) / min(width, height) > 3:
        flags.append('extreme_aspect_ratio')
    return dict(width=width, height=height, gray_std=spread, laplacian_variance=blur,
                hard_reasons=hard, review_flags=flags,
                original_sha256=digest(path.read_bytes()),
                input_sha256=digest(padded.tobytes()),
                _thumb=thumbnail,
                _dhash=int.from_bytes(np.packbits(dh[:, 1:] > dh[:, :-1]).tobytes(), 'big'))


def duplicate_groups(rows):
    parent = list(range(len(rows)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    exact = {}
    links = []
    for i, row in enumerate(rows):
        h = row['input_sha256']
        if h in exact:
            parent[find(i)] = find(exact[h])
        else:
            exact[h] = i
        for j in range(i):
            other = rows[j]
            if h == other['input_sha256']:
                continue
            if (row['_dhash'] ^ other['_dhash']).bit_count() <= 4:
                distance = float(np.abs(row['_thumb'] - other['_thumb']).mean())
                if distance <= 12:
                    parent[find(i)] = find(j)
                    links.append(dict(a=other['key'], b=row['key'], rgb16_mae=distance))
    groups = defaultdict(list)
    for i in range(len(rows)):
        groups[find(i)].append(i)
    return list(groups.values()), links


def assign_splits(rows, groups, seed):
    rng = random.Random(seed)
    for label in sorted({r['label'] for r in rows}):
        eligible = [g for g in groups if rows[g[0]]['label'] == label
                    and all(not rows[i]['exclusion_reasons'] for i in g)]
        if len(eligible) < 15:
            raise ValueError('Need at least 15 independent groups for ' + label)
        # Prioritize groups present in both sources, then fill each source's
        # class quotas. This makes standalone and combined splits usable while
        # preserving the global no-overlap invariant.
        rng.shuffle(eligible)
        eligible.sort(key=lambda g: -len({rows[i]['dataset'] for i in g}))
        sources = sorted({rows[i]['dataset'] for g in eligible for i in g})
        totals = {s: sum(any(rows[i]['dataset'] == s for i in g) for g in eligible) for s in sources}
        counts = {s: Counter() for s in sources}
        for group in eligible:
            present = {rows[i]['dataset'] for i in group}
            targets = {'train': .70, 'validation': .15, 'test': .15}
            split = max(SPLITS, key=lambda sp: sum(
                (targets[sp] * totals[s] - counts[s][sp]) / max(1, targets[sp]*totals[s])
                for s in present))
            for i in group:
                rows[i]['split'] = split
            for s in present:
                counts[s][split] += 1


def contact_sheets(rows, output, prefix, page_size=120):
    output.mkdir(exist_ok=True)
    for page, start in enumerate(range(0, len(rows), page_size), 1):
        selected = rows[start:start+page_size]
        sheet = Image.new('RGB', (1200, 140*((len(selected)+9)//10)), 'white')
        draw = ImageDraw.Draw(sheet)
        for k, row in enumerate(selected):
            x, y = (k % 10)*120, (k//10)*140
            try:
                image = rgb_image(row['original_path'])
                image.thumbnail((114, 108))
                sheet.paste(image, (x+(114-image.width)//2, y))
            except (OSError, ValueError):
                continue
            # Numeric position maps to the complete CSV, filenames remain ASCII.
            text = f"{start+k+1} {row['dataset'][:1]} {row['label']}\n{Path(row['original_path']).name[:18]}"
            draw.text((x+2, y+109), text, fill='black')
        sheet.save(output/f'{prefix}_{page:02d}.jpg', quality=88)


def write_manifest(output, rows, roots, group_policy):
    output.mkdir(parents=True, exist_ok=True)
    classes = sorted({r['label'] for r in rows})
    samples = []
    for row in sorted(rows, key=lambda r: r['key']):
        image = rgb_image(row['original_path'])
        image.thumbnail((1024, 1024), Image.Resampling.LANCZOS)
        path = output/'images'/row['label']/(row['original_sha256'][:24]+'.png')
        path.parent.mkdir(parents=True, exist_ok=True)
        image.save(path)
        sample = dict(path=str(path.resolve()), target=classes.index(row['label']),
                      label=row['label'], source_class=row['source_class'],
                      source_sha256=digest(path.read_bytes()),
                      input_sha256=training_input_hash(image),
                      split=row['split'], group=row['group'], dataset=row['dataset'],
                      original_path=row['original_path'], original_sha256=row['original_sha256'])
        samples.append(sample)
    manifest = dict(root=str((output/'images').resolve()), classes=classes, samples=samples,
                    source_roots=roots, cleaning='clean_fruit_datasets_v1',
                    split_policy='global cross-source stratified duplicate-group split 70/15/15',
                    group_policy=group_policy)
    save_json(output/'data_manifest.json', manifest)
    with (output/'data_manifest.csv').open('w', newline='', encoding='utf-8-sig') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(samples[0]))
        writer.writeheader()
        writer.writerows(samples)
    audit = dict(usable=len(samples), classes=classes, counts={sp: dict(Counter(
        r['label'] for r in samples if r['split'] == sp)) for sp in SPLITS},
        cleaning_report=str((output.parent/'cleaning_report.json').resolve()))
    save_json(output/'audit.json', audit)
    return audit


def clean(sources, output, seed=20261024, review=None):
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    reviews = (review or {}).get('exclude', {})
    rows, invalid = [], []
    for dataset, root in sources.items():
        if not root.is_dir():
            raise FileNotFoundError(str(root))
        for folder in sorted(p for p in root.iterdir() if p.is_dir()):
            label = folder.name.lower()
            if label not in {'apple', 'banana', 'grape', 'orange', 'pear'}:
                raise ValueError('Unexpected source class: ' + str(folder))
            for path in sorted(folder.rglob('*')):
                if not path.is_file() or path.suffix.lower() not in EXTENSIONS:
                    continue
                key = dataset + ':' + path.relative_to(root).as_posix()
                try:
                    row = dict(key=key, dataset=dataset, label=label, source_class=folder.name,
                               original_path=str(path.resolve()), **describe(path))
                    row['exclusion_reasons'] = list(row['hard_reasons'])
                    if key in reviews:
                        row['exclusion_reasons'].append('visual_review: '+reviews[key])
                    rows.append(row)
                except (OSError, ValueError, SyntaxError) as exc:
                    invalid.append(dict(key=key, path=str(path), error=str(exc)))
    unknown = set(reviews) - {r['key'] for r in rows}
    if unknown:
        raise ValueError('Review keys do not exist: ' + str(sorted(unknown)))
    groups, links = duplicate_groups(rows)
    for group in groups:
        keys = sorted(rows[i]['key'] for i in group)
        name = digest('\n'.join(keys).encode())[:20]
        conflict = len({rows[i]['label'] for i in group}) > 1
        semantic_reasons = sorted({reason for i in group for reason in rows[i]['exclusion_reasons']
                                   if reason.startswith('visual_review:')})
        for i in group:
            rows[i]['group'] = name
            if conflict:
                rows[i]['exclusion_reasons'].append('cross_label_duplicate_group')
            rows[i]['exclusion_reasons'] = sorted(set(rows[i]['exclusion_reasons'] + semantic_reasons))
        # A bad-quality duplicate does not invalidate a good-quality original.
    eligible_groups = [[i for i in g if not rows[i]['exclusion_reasons']] for g in groups]
    eligible_groups = [g for g in eligible_groups if g]
    assign_splits(rows, eligible_groups, seed)
    selected = {name: [] for name in [*sources, 'combined']}
    for group in eligible_groups:
        def rank(i):
            row = rows[i]
            return (min(row['width'], row['height'], 1024),
                    min(row['laplacian_variance'], 500), row['key'])
        best = max(group, key=rank)
        selected['combined'].append(rows[best])
        for dataset in sources:
            members = [i for i in group if rows[i]['dataset'] == dataset]
            if not members:
                continue
            winner = max(members, key=rank)
            selected[dataset].append(rows[winner])
            for i in members:
                rows[i]['disposition'] = 'kept' if i == winner else 'duplicate_removed'
                if i != winner:
                    rows[i]['duplicate_of'] = rows[winner]['key']
                    rows[i]['duplicate_kind'] = ('exact_rgb96' if rows[i]['input_sha256'] ==
                                                 rows[winner]['input_sha256'] else 'near_group')
    for row in rows:
        row.setdefault('disposition', 'quarantined')
    roots = {k: str(v.resolve()) for k, v in sources.items()}
    audits = {name: write_manifest(output/name, kept, roots, 'one representative per near group')
              for name, kept in selected.items()}
    public = [{k: v for k, v in r.items() if not k.startswith('_')} for r in rows]
    report = dict(version=1, seed=seed, source_roots=roots, original_images=len(rows)+len(invalid),
                  invalid=invalid, datasets=audits, near_duplicate_links=links,
                  rules=dict(exact='identical RGB96 letterbox pixels',
                             near='dHash <=4 AND RGB16 MAE <=12, transitive global groups',
                             quality='min dimension <32 or almost constant gray image',
                             output='EXIF applied, RGB PNG, longest side <=1024',
                             semantic='explicit visual review; reasons propagated to duplicate groups'),
                  by_source={s: dict(Counter(r['disposition'] for r in rows if r['dataset']==s)) for s in sources},
                  limitation='Perceptual matching cannot detect all crops or capture sessions. '
                             'Review flags are advisory, not automatic semantic truth.',
                  samples=public)
    save_json(output/'cleaning_report.json', report)
    save_json(output/'review_used.json', review or {})
    with (output/'cleaning_log.csv').open('w', newline='', encoding='utf-8-sig') as stream:
        fields = sorted({k for r in public for k in r})
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(public)
    contact_sheets(sorted(selected['combined'], key=lambda r:r['key']), output/'contact_sheets', 'kept')
    contact_sheets([r for r in rows if r['disposition']=='quarantined'], output/'contact_sheets', 'quarantine')
    print(json.dumps({k: v for k, v in report.items() if k in
                      ('original_images', 'by_source', 'datasets')}, ensure_ascii=False, indent=2), flush=True)
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--old', type=Path, default=ROOT.parent/'fruits/fruits')
    p.add_argument('--recognition', type=Path,
                   default=ROOT.parent/'Fruit-recognition-master/Fruit-recognition-master/fruits')
    p.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    p.add_argument('--seed', type=int, default=20261024)
    p.add_argument('--review', type=Path, default=Path(__file__).with_name('fruit_cleaning_review.json'))
    args = p.parse_args()
    review = json.loads(args.review.read_text(encoding='utf-8')) if args.review.is_file() else {}
    clean({'old':args.old, 'recognition':args.recognition}, args.output, args.seed, review)


if __name__ == '__main__':
    main()
