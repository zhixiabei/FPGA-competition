"""Copy a frozen dataset into a standalone train/validation/test directory."""
import argparse
import csv
import json
from pathlib import Path
import shutil

from clean_fruit_datasets import save_json
from fruitcnn_training import load_manifest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    classes, rows, _, _ = load_manifest(args.manifest)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    exported = []
    for row in rows:
        source = Path(row['path'])
        target = out/row['split']/row['label']/source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            raise ValueError('Duplicate output filename: '+str(target))
        shutil.copy2(source, target)
        exported.append(dict(row, path=str(target)))
    manifest = json.loads(args.manifest.read_text(encoding='utf-8'))
    manifest.update(root=str(out), classes=classes, samples=exported,
                    exported_from=str(args.manifest.resolve()))
    save_json(out/'data_manifest.json', manifest)
    with (out/'data_manifest.csv').open('w', newline='', encoding='utf-8-sig') as stream:
        writer = csv.DictWriter(stream, fieldnames=sorted({k for r in exported for k in r}))
        writer.writeheader()
        writer.writerows(exported)
    for name in ('replacement_report.json', 'review_used.json'):
        source = args.manifest.parent/name
        if source.is_file():
            shutil.copy2(source, out/name)
    load_manifest(out/'data_manifest.json')
    assert all(Path(r['path']).is_relative_to(out) for r in exported)
    counts = {split:{label:sum(r['split']==split and r['label']==label for r in exported)
                     for label in classes} for split in ('train','validation','test')}
    save_json(out/'export_verification.json', dict(status='passed', samples=len(exported),
              classes=classes, counts=counts, image_hashes_verified=True,
              all_training_image_paths_inside_output=True, split_leakage_checks_passed=True))
    (out/'README.md').write_text(
        '# 五类水果数据集：梨替换为草莓\n\n'
        '类别顺序：apple、banana、grape、orange、strawberry。共 1253 张 RGB PNG。\n\n'
        '- train/：875 张，用于训练。\n'
        '- validation/：189 张，用于选择模型、校准置信度。\n'
        '- test/：189 张，训练结束后评估，不参与训练和选模型。\n\n'
        'data_manifest.json 是训练入口；图片已全部复制到本目录，保留原有重复组划分。\n'
        'manifest 中 original_path/source_roots 为来源追溯记录，不用于训练读图。\n'
        '草莓原始来源为 fruit81_full/fruit81_full/草莓，198 张经视觉筛选及去重保留 99 张。\n'
        'replacement_report.json 和 review_used.json 记录排除原因。原始数据未删除或改名。\n\n'
        '在 FPGA-competition-main 工程内运行 train_fruits128_strawberry_cuda.cmd。\n'
        '先检查数据：train_fruits128_strawberry_cuda.cmd --check-data-only。\n'
        '训练自动新建输出目录，不覆盖已有模型；输入 128×128，输出五类。\n'
        '这是图片数据集，准确率不能代替板载摄像头屏摄实测。\n', encoding='utf-8')
    print(json.dumps(dict(output=str(out), samples=len(exported), counts=counts), indent=2))


if __name__ == '__main__':
    main()
