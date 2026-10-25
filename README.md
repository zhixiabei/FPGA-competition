# FPGA 水果与手势识别

仅保留当前草莓五分类水果识别，以及最后的 hand7 手势识别（KEY4 启停、背景判断）。

## 下载文件

两份 bit 统一放在 `td_project/anlogic_edge_osd_Runs/best_result/`：

| 功能 | bit 文件 | 配套 DDR 权重 |
|---|---|---|
| 苹果、香蕉、葡萄、橘子、草莓 | `fruitfixed_candidate.bit` | `build/fruit/weights/model.bin` |
| PEACE、PUNCH、STOP；背景输出 NOTHING | `anlogic_edge_osd.bit` | `build/gesture/weights/model.bin` |

在 TD Programmer 下载所需功能的 bit 后，在根目录执行对应命令：

```powershell
# 水果
powershell -NoProfile -ExecutionPolicy Bypass -File verification/load_handfixed_uart.ps1 -Fruit -WinUsb
# 手势
powershell -NoProfile -ExecutionPolicy Bypass -File verification/load_handfixed_uart.ps1 -WinUsb
```

清空识别框，等待约 1～2 秒，再按 KEY4 启动。复位、断电或重新下载 bit 后需要重新加载权重。

## 保留的源码与模型

- 水果工程：`build/fruit/td/handfixed_candidate.al`，现有工程沿用原目录名。
- 手势主工程：`td_project/anlogic_edge_osd.al`；最终冻结工程及物理报告在 `build/gesture/td/`。
- 当前水果训练权重：`build/fruit/training/model.pt`。
- 最后手势训练权重：`build/gesture/training/model.pt`。
- 水果数据集：`E:\aaa\FPGA-competition-main\fruits5_strawberry_clean_20261025`。
- 手势数据集：`build/gesture/data/`。

水果训练在 PyCharm 直接运行 `verification/train_fruitcnn128.py`，解释器使用 `.conda/fruitcuda/python.exe`；默认已指向草莓数据集。摄像头测试配置为 **Test Fruits Camera CUDA**。

`build/` 顶层仅保留 `fruit/` 和 `gesture/` 两个目录，分别收纳当前两版的模型、工程源码、测试证据及必要数据，不保存 bit。旧水果版本、试训模型和重复训练启动入口已删除。清理清单及文件哈希在 `build/fruit/records/`。

说明见 [水果上板](docs/FRUITCNN128_FPGA.md)、[水果训练](docs/FRUITCNN128_TRAINING.md)、[手势使用](docs/HANDCNN_FIXED_ROI_BACKGROUND.md)。
