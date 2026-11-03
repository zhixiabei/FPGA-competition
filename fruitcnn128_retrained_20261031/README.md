# 当前水果模型归档

保留最佳模型检查点及少量配置和评估记录。训练图片、重复数据、训练脚本及旧检查点已从工作区清理；历史内容仍可从 Git 提交 `71ce808` 查阅。

| 文件 | 用途 |
|---|---|
| `training/model.pt` | 最佳训练检查点 |
| `training/run_config.json` | 当时的训练配置和来源记录 |
| `training/evaluation.json` | 当时的评估结果 |
| `training/fpga_requirements.json` | 模型的硬件需求记录 |
| `summary.json` | 训练摘要 |

架构定义保留在 `verification/fruitcnn128.py` 及其依赖 `handcnn_model.py`。配置中的 E 盘路径记录当时的训练环境，不是当前 FPGA 的运行依赖。

主工程按 CRC32 `3a37bea7` 校验 U30 模型。此检查点不等于 Flash 定点导出包，当前硬件编译不读取本目录。
