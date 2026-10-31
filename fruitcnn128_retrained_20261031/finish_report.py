"""Render the completed run's results without modifying model weights."""
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parent


def read(path):
    return json.loads((ROOT / path).read_text(encoding='utf-8'))


def main():
    evaluation = read('training/evaluation.json')
    history = read('training/history.json')
    verified = read('verification_report.json')
    split = read('data/split_report.json')
    summary = dict(architecture=verified['architecture'], classes=split['classes'],
                   total_images=split['total'], split_totals=split['split_totals'],
                   epochs_completed=verified['epochs_completed'], best_epoch=verified['best_epoch'],
                   elapsed_seconds=history[-1]['elapsed_seconds'],
                   test_results={name:dict({k:metrics[k] for k in ['samples', 'accuracy', 'macro_recall',
                                                                   'rejected', 'accepted_correct', 'accepted_wrong', 'accepted_accuracy']},
                                            coverage=1 - metrics['rejected'] / metrics['samples'])
                                 for name, metrics in evaluation['test'].items()},
                   validation_results={name:{k:metrics[k] for k in ['samples', 'accuracy', 'macro_recall']}
                                       for name, metrics in evaluation['validation'].items()},
                   checkpoint_sha256=verified['checkpoint_sha256'])
    (ROOT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    epochs = [r['epoch'] for r in history]
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.2), dpi=160)
    for key, label in [('loss', 'Total'), ('classification_loss', 'Classification'),
                       ('shape_loss', 'Shape'), ('texture_loss', 'Texture')]:
        axes[0].plot(epochs, [r[key] for r in history], label=label, linewidth=1.3)
    axes[0].set(xlabel='Epoch', ylabel='Loss', title='Training losses (unweighted components)')
    for key, label in [('train_accuracy', 'Augmented training'), ('validation_accuracy', 'Validation'),
                       ('validation_macro_recall', 'Validation macro recall')]:
        axes[1].plot(epochs, [r[key] for r in history], label=label, linewidth=1.3)
    axes[1].axvline(verified['best_epoch'], color='black', linestyle='--', linewidth=1,
                   label=f"Selected epoch {verified['best_epoch']}")
    axes[1].set(xlabel='Epoch', ylabel='Fraction', ylim=(0, 1.02), title='Training and validation')
    for ax in axes:
        ax.grid(alpha=.2)
        ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(ROOT / 'training_curves.png')
    plt.close(fig)
    metrics = evaluation['test']['original']
    confusion = np.asarray(metrics['confusion'])
    classes = split['classes']
    fig, ax = plt.subplots(figsize=(6.5, 5.4), dpi=160)
    img = ax.imshow(confusion, cmap='Blues')
    ax.set(xticks=range(5), yticks=range(5), xticklabels=classes, yticklabels=classes,
           xlabel='Predicted class', ylabel='True class',
           title=f"Held-out test: {metrics['accuracy']:.1%} accuracy ({metrics['samples']} images)")
    plt.setp(ax.get_xticklabels(), rotation=30, ha='right')
    for i in range(5):
        for j in range(5):
            ax.text(j, i, str(confusion[i, j]), ha='center', va='center',
                    color='white' if confusion[i, j] > confusion.max() / 2 else 'black')
    fig.colorbar(img, ax=ax, shrink=.8)
    fig.tight_layout()
    fig.savefig(ROOT / 'test_confusion_matrix.png')
    plt.close(fig)
    names = dict(apple='苹果', banana='香蕉', grape='葡萄', orange='橘子', strawberry='草莓')
    lines = ['# 五类水果 CNN 重新训练结果', '',
             '基于 `fruits5_selected_20261031` 的全部 998 张筛选图片，从随机初始化开始训练。', '',
             '网络与原水果模型相同：`fruit_scharr_texture_rgb128_v1`，128×128 RGB 输入，'
             '七层 Conv/BN/ReLU，通道 12/12/24/32/48/64/96，4×4 平均池化，384→5 全连接，推理参数 110,393。', '',
             '形状使用固定正负 Scharr 梯度及原有形状辅助监督；纹理保留固定正负 Laplacian 特征及 4×4 单元 LBP 直方图辅助监督；'
             '颜色保留完整 RGB 输入、相同归一化和颜色增强。训练使用形状头 64 维、纹理头 160 维，推理权重按原规则移除辅助头。', '',
             '## 数据划分', '', '| 类别 | 训练 | 验证 | 测试 |', '|---|---:|---:|---:|']
    for c in classes:
        counts = split['class_splits'][c]
        lines.append(f"| {names[c]} ({c}) | {counts['train']} | {counts['validation']} | {counts['test']} |")
    lines += ['| 合计 | 698 | 150 | 150 |', '',
              '按重复组划分，各集合之间没有重复组、文件哈希或模型输入哈希重叠。142 张手机图片来自同批水果的连续拍摄，全部归入训练集，避免同一拍摄对象泄漏到验证或测试集。'
              '验证和测试结果因此反映留出的网络图片，不能作为独立手机拍摄准确率。', '',
              '## 训练与结果', '',
              '使用 RTX 4060 Laptop GPU / PyTorch 2.6.0+cu124。完整沿用原训练配置：AdamW、学习率 0.002、weight decay 0.002、batch 48、seed 20261024、'
              '160 轮上限、至少 60 轮、30 轮早停耐心值、AMP、每轮重复 2 次、形状/纹理损失权重各 0.1、苹果/橘子配对权重 0.15、异常样本权重 0.05、'
              '硬件缩放输入概率 0.5、拒识阈值 0.65；数据增强、类别加权、标签平滑、选模规则与原训练脚本相同。', '',
              f"实际完成 **{verified['epochs_completed']} 轮**，最佳权重来自 **第 {verified['best_epoch']} 轮**。仅使用验证集选模与校准温度，冻结权重后评估测试集。", '',
              '| 测试视图 | 准确率 | 宏平均召回率 |', '|---|---:|---:|']
    for view, title in [('original', '原始图像预处理'), ('hardware_resize', '模拟硬件缩放'),
                         ('grayscale', '灰度输入'), ('weak_light', '弱光模拟')]:
        r = evaluation['test'][view]
        lines.append(f"| {title} | {r['accuracy']:.2%} | {r['macro_recall']:.2%} |")
    lines += ['', '测试图像按原始类别的召回率：', '', '| 类别 | 数量 | 召回率 |', '|---|---:|---:|']
    for c in classes:
        r = evaluation['test']['original']['per_class'][c]
        lines.append(f"| {names[c]} | {r['samples']} | {r['recall']:.2%} |")
    original = evaluation['test']['original']
    lines += ['', f"上表准确率为 top-1 分类准确率。在 0.65 置信度阈值下，原图测试共拒识 {original['rejected']} 张，"
              f"接受且正确 {original['accepted_correct']} 张，接受但错误 {original['accepted_wrong']} 张。", '',
              '## 文件', '',
              '- `training/model.pt`：已经完成训练和校准的最佳推理权重。',
              '- `training/last.pt`：最后一轮训练状态，包含优化器、随机状态和辅助头，可断点续训。',
              '- `train.py`：使用相同配置重新训练；后续新训练自动使用新的 runs 子目录。',
              '- `predict.py`：默认加载本文件夹的新权重，支持图片或摄像头。',
              '- `source/`：本次训练使用的原实现快照。',
              '- `data/`：独立复制的 train/validation/test 图片、训练清单和分组记录。',
              '- `training/evaluation.json`、`training/test_predictions.csv`：详细测试结果。',
              '- `verification_report.json`：与原模型的结构、固定滤波器、预处理和训练参数一致性检查。',
              '- `training_curves.png`、`test_confusion_matrix.png`：训练曲线与测试混淆矩阵。',
              '- `logs/`：训练控制台日志。', '',
              '## 使用', '', '在项目根目录使用原来的 CUDA 解释器：', '', '```powershell',
              r'.\.conda\fruitcuda\python.exe fruitcnn128_retrained_20261031\predict.py --image "图片路径.jpg"',
              r'.\.conda\fruitcuda\python.exe fruitcnn128_retrained_20261031\predict.py --camera 0',
              r'.\.conda\fruitcuda\python.exe fruitcnn128_retrained_20261031\train.py',
              '```', '',
              '原脚本恢复训练会遵循断点内保存的训练配置；已完成的断点会直接报告完成，若要重新训练请直接运行 `train.py`。', '',
              '本次产物是浮点 CNN 权重及训练记录。尚未对新权重执行 FPGA 定点量化、综合或上板测试。原模型文件保留。']
    (ROOT / 'README.md').write_text('\n'.join(lines) + '\n', encoding='utf-8-sig')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
