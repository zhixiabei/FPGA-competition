# PH1P35 图像处理与水果识别

本次将 `main` 的图像处理链路与 `master` 的 RGB128 水果识别整合。保留 main 的曝光、白平衡、RAW 直方图、十三种显示模式、颜色与形状单目标检测、运动检测及延迟面板。多目标检测因资源不足保持关闭，待资源允许后再恢复。

水果识别使用 **SW2（B4）直接启停**。工程已加入 HX711 称重、五类水果计价和八位数码管显示，并完成五类价格 RTL 仿真；尚未执行完整综合、布局布线、生成 bit 或烧录，现有 bit 不包含此次修改。

## 控制方式

| 控件 | 功能 |
|---|---|
| K1（D5） | 循环 main 的十三种显示模式 |
| K2（A9） | SW2 ON：称重去皮；SW2 OFF：红色、绿色、蓝色、运动检测循环 |
| K3（B9） | SW2 ON：使用 227 g 参考物校准；SW2 OFF：保留 |
| SW1（A4） | 延迟面板显示/隐藏 |
| SW2（B4） | ON：五类水果识别、称重和计价；OFF：恢复 main 检测显示并停止计价 |
| K4（C7） | 水果工程无需按 K4；独立手势工程仍使用 K4 启停 |

水果五分类为苹果、香蕉、葡萄、橘子、草莓；低置信度输出 `UNKNOWN`，草莓标签为 `STRAWBR`。输入来自显示特效处理前的彩色 ISP 流，使用中央 480×480 固定框。切换显示在 HDMI 帧边界生效；关闭识别后，已开始的 DDR 工作完成后丢弃旧结果，不复位共享 DDR。

数码管 S0～S3 显示净重量 `x.xxx kg`，S4～S7 显示总价 `xx.xx 元`。单价分别为苹果 8、香蕉 6、葡萄 12、橘子 5、草莓 20 元/kg；总价按 `重量(g) × 单价(分/kg) ÷ 1000` 四舍五入到分。无有效识别、未校准、传感器故障或总价超过 99.99 元时，价格显示 `----`。

HX711 接到 GPIOA：DOUT 接 V2，SCK 接 V1。上电空秤约两秒后自动去皮；SW2 ON 时可用 K2 重新去皮，再放置 227 g 参考物并按 K3 校准。校准数据只保存在运行寄存器中，复位或断电后需重新校准。

## 工程入口

| 工程 | 内容 |
|---|---|
| `td_project/anlogic_edge_osd.al` | main 图像功能、五类水果识别、HX711 称重和计价 |
| `td_project/anlogic_sc520_capture.al` | 视频与称重入口，不启用水果识别，因而不显示价格 |
| `build/fruit/td_main_sw2/handfixed_candidate.al` | 本次新生成的 main + RGB128 水果 + SW2 工程，尚未编译 |
| `build/fruit/td/handfixed_candidate.al` | 先前冻结的水果工程与报告，原有 KEY4 版本 |
| `build/gesture/td/handfixed_candidate.al` | 先前冻结的独立手势工程与报告 |

`build/` 不进入 Git。新电脑需另行复制 `build/fruit/weights/` 模型包，再运行以下**仅生成文件**的命令。输出目录必须尚不存在，避免覆盖冻结工程：

```powershell
python -B verification/prepare_fruit128_project.py --model build/fruit/weights --output build/fruit/td_main_sw2
```

该入口只复制源码、转换 RGB128 模块并生成 `.al`、约束快照及清单，不调用 FPGA 工具。新工程同时包含 main 和水果逻辑，资源与时序尚未验证，不能沿用任一旧工程的物理验收结果。

仅做静态检查：

```powershell
python -B verification/check_merge_readiness.py --project build/fruit/td_main_sw2/handfixed_candidate.al
```

未来单独获准构建时，`build_firmware.cmd` 默认使用 main 图像工程；`-Fruit` 指向新的 `td_main_sw2`，`-Gesture` 指向旧手势工程。此次未执行这些构建入口。

## 模型与历史制品

- 水果模型：`build/fruit/training/model.pt`，配套量化包：`build/fruit/weights/`。
- 原水果 bit：`td_project/anlogic_edge_osd_Runs/best_result/fruitfixed_candidate.bit`。
- 原手势 bit：`td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit`。
- 旧 bit、权重和物理报告的对应关系见 [水果历史说明](docs/FRUITCNN128_FPGA.md) 与 [手势说明](docs/HANDCNN_FIXED_ROI_BACKGROUND.md)。旧 bit 的开关行为仍以旧版说明为准。

源码和 Git 合并准备说明见 [main/master 整合记录](docs/MASTER_MAIN_MERGE.md)，main 原有功能详见 [代码导航](docs/CODE_MAP.md)、[显示模式](docs/VIDEO_MODE_SWITCH.md)、[颜色与形状](docs/COLOR_SHAPE.md)。main 合并前首页保存在 [历史文档](docs/history/MAIN_BEFORE_FRUIT_MERGE.md)。
