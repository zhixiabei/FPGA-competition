# 草莓替换数据集

数据集位于 `E:\aaa\FPGA-competition-main\fruits5_strawberry_clean_20261025`。

当前五类为苹果、香蕉、葡萄、橘子、草莓。原有四类的数据划分保留，梨已移除。草莓经过人工图片审查、去重，排除插画、饮料和菜品等图片。

| 类别 | 训练 | 验证 | 测试 |
|---|---:|---:|---:|
| apple | 280 | 61 | 61 |
| banana | 246 | 52 | 52 |
| grape | 61 | 13 | 13 |
| orange | 219 | 48 | 48 |
| strawberry | 69 | 15 | 15 |
| 合计 | 875 | 189 | 189 |

数据集包含实际 PNG 图片、`data_manifest.json` 和审查/导出报告。训练方式见 [PyCharm 训练说明](FRUITCNN128_TRAINING.md)。当前用户训练权重为 `build/fruit/training/model.pt`；其他试训版本已删除。
