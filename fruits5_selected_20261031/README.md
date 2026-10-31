# 五类水果筛选数据集

整理日期：2026-10-31。共 998 张。

| 文件夹 | 类别 | 张数 |
|---|---|---:|
| apple | 苹果 | 291 |
| banana | 香蕉 | 258 |
| grape | 葡萄 | 108 |
| orange | 橘子 | 247 |
| strawberry | 草莓 | 94 |

仅使用以下三处图片：

- `E:\aaa\FPGA-competition-main\fruits`
- `E:\aaa\FPGA-competition-main\图片`
- `E:\aaa\FPGA-competition-main\fruits5_strawberry_clean_20261025\train`

逐页检查候选图片缩略图，排除非目标类别、明显模糊、插画、混合水果等不适合单类识别的图片，并跨来源去重。保留同类多枚水果和清楚的切面照片。

图片统一为 RGB JPEG，最长边不超过 2048 像素，保持比例、校正方向，不裁剪、不放大。HEIC 已转换。原始文件未改动。

本文件夹是分类后的数据总集，未划分训练/验证/测试集，未生成增强图片。原数据集的测试集可能与 fruits 原图重合；后续训练应基于本总集重新按拍摄组划分数据。

`dataset_manifest.json` 记录每张图片的类别、来源和哈希。`input_audit.csv` 记录所有输入图片的去向，`selection_report.json` 记录数量和筛选原因。
