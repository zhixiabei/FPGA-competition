"""Replace pear in a frozen manifest, retaining the other four class splits."""
import argparse
from collections import Counter
import csv
import json
from pathlib import Path

from clean_fruit_datasets import (EXTENSIONS, assign_splits, describe, digest,
                                  duplicate_groups, rgb_image, save_json,
                                  training_input_hash)
from fruitcnn_training import load_manifest

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', type=Path, default=ROOT/'build/fruits_clean_v1/combined/data_manifest.json')
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--label', choices=['pineapple', 'blueberry', 'strawberry'], required=True)
    p.add_argument('--review', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    classes, original, _, _ = load_manifest(args.base)
    if classes != ['apple', 'banana', 'grape', 'orange', 'pear']:
        raise ValueError('Expected the original five-fruit manifest')
    classes[-1] = args.label
    retained = [dict(r) for r in original if r['label'] != 'pear']
    review = json.loads(args.review.read_text(encoding='utf-8'))
    exclusions = review['exclude_sha256']
    rows, rejected = [], []
    for r in retained:
        rows.append(dict(key='base:'+r['path'], label=r['label'], dataset='base',
                         original_path=r['path'], exclusion_reasons=[], **describe(Path(r['path']))))
    base_count = len(rows)
    for path in sorted(args.source.rglob('*')):
        if not path.is_file() or path.suffix.lower() not in EXTENSIONS:
            continue
        try:
            details = describe(path)
        except (OSError, ValueError, SyntaxError) as exc:
            rejected.append(dict(path=str(path), reason=str(exc)))
            continue
        reasons = details['hard_reasons'][:]
        if details['original_sha256'] in exclusions:
            reasons.append(exclusions[details['original_sha256']])
        rows.append(dict(key='fruit81:'+path.name, label=args.label, dataset='fruit81',
                         original_path=str(path.resolve()), exclusion_reasons=reasons, **details))
    groups, _ = duplicate_groups(rows)
    eligible = []
    for group in groups:
        new = [i for i in group if i >= base_count]
        if not new:
            continue
        reasons = sorted({s for i in new for s in rows[i]['exclusion_reasons']})
        if any(i < base_count for i in group):
            reasons.append('duplicate_of_existing_class')
        if reasons:
            rejected.extend(dict(path=rows[i]['original_path'], reason='; '.join(reasons)) for i in new)
            continue
        for i in new:
            rows[i]['group'] = 'fruit81_'+digest('\n'.join(sorted(rows[j]['key'] for j in new)).encode())[:20]
        eligible.append(new)
    # Only replacement groups get a new split. Existing four classes are frozen.
    new_rows = [rows[i] for group in eligible for i in group]
    remap = {id(row): i for i, row in enumerate(new_rows)}
    new_groups = [[remap[id(rows[i])] for i in g] for g in eligible]
    assign_splits(new_rows, new_groups, 20261025)
    args.output.mkdir(parents=True, exist_ok=False)
    samples = retained[:]
    for group in eligible:
        winner = max(group, key=lambda i: (min(rows[i]['width'], rows[i]['height']), rows[i]['key']))
        r = rows[winner]
        image = rgb_image(r['original_path'])
        image.thumbnail((1024, 1024))
        path = args.output/'images'/args.label/(r['original_sha256'][:24]+'.png')
        path.parent.mkdir(parents=True, exist_ok=True)
        image.save(path)
        samples.append(dict(path=str(path.resolve()), target=4, label=args.label,
                            source_class=args.source.name, source_sha256=digest(path.read_bytes()),
                            input_sha256=training_input_hash(image), split=r['split'], group=r['group'],
                            dataset='fruit81', original_path=r['original_path'], original_sha256=r['original_sha256']))
        rejected.extend(dict(path=rows[i]['original_path'], reason='duplicate_group',
                             representative=r['original_path']) for i in group if i != winner)
    base = json.loads(args.base.read_text(encoding='utf-8'))
    manifest = dict(base, classes=classes, samples=samples,
                    replacement=dict(removed='pear', added=args.label, source=str(args.source.resolve()),
                                     base_manifest_sha256=digest(args.base.read_bytes()),
                                     split_policy='existing four splits retained; replacement duplicate groups 70/15/15'))
    save_json(args.output/'data_manifest.json', manifest)
    with (args.output/'data_manifest.csv').open('w', newline='', encoding='utf-8-sig') as stream:
        writer = csv.DictWriter(stream, fieldnames=sorted({k for r in samples for k in r}))
        writer.writeheader()
        writer.writerows(samples)
    save_json(args.output/'review_used.json', review)
    report = dict(classes=classes, counts={s:dict(Counter(r['label'] for r in samples if r['split']==s))
                                         for s in ('train','validation','test')},
                  removed_pear=sum(r['label']=='pear' for r in original), rejected=rejected,
                  limitation='Near-duplicate matching cannot prove independent capture sessions; no screen-camera accuracy claim.')
    save_json(args.output/'replacement_report.json', report)
    load_manifest(args.output/'data_manifest.json')
    print(json.dumps({k:v for k,v in report.items() if k!='rejected'}, indent=2))


if __name__ == '__main__':
    main()
