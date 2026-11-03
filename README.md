# PH1P35 图像处理与水果识别

当前主工程为 [anlogic_edge_osd.al](td_project/anlogic_edge_osd.al)，顶层 `design_top_wrapper`，器件 PH1P35MDG324。工程状态见 [当前工程说明](td_project/当前工程说明.md)。

源码以 Git `395967c` 为基线，保留 AE/AWB、RAW 直方图、Gamma、检测、识别和签名功能。

## 操作

| 控件 | 功能 |
|---|---|
| K1（D5） | 循环十三种显示模式 |
| K2（A9） | SW2 ON：去皮；SW2 OFF：红、绿、蓝、运动检测循环 |
| K3（B9） | SW2 ON：使用 227 g 参考物校准 |
| SW1（A4） | 显示或隐藏延迟面板 |
| SW2（B4） | 开启或关闭水果识别、称重和计价 |
| SW3（E11） | 开启镜像镜头签名；关闭时清空笔迹、恢复 K1 显示模式 |
| SW4（D11） | 签名暂停落笔，保留已有笔迹；关闭后继续写 |
| K4（C7） | 统一水果工程不使用此键启停 |

水果分类为苹果、香蕉、葡萄、橘子、草莓。ROI 起点为 `x=240, y=120`，大小为 `480×480`；图像来自显示特效前的彩色 ISP 流。低置信度显示 `UNKNOWN`，草莓显示 `STRAWBR`。当前多目标检测关闭。

镜头签名移植自 `Signature_Smooth_4x4` 的 `pen_minimal` 核心。开启 SW3 后，以画面中明显的红色标记中心书写，画面水平镜像，笔迹为红色；使用现有红色目标检测，标记需要满足其面积和连续确认条件。暂停、目标丢失或坐标大幅跳变时断笔，画布坐标的跳变门限约为 96 像素。签名时隐藏目标框和水果面板，SW1 延迟面板仍可用；SW2 的计算、称重与语音控制保持原样。签名使用内部模式 13，K1 原来的 0–12 模式保持不变，退出后检测恢复 K2 所选模式。

画布为 320×180 单色位图，每格对应 4×4 像素，不占 DDR 视频带宽。镜像复用原来的读地址与像素拆包，不增加彩色帧缓存；新增笔迹在 HDMI 时钟域完成。构建脚本只生成 bit，不操作板卡或 U30 中已经烧入的新权重。

单价依次为 8、6、12、5、20 元/kg。总价四舍五入到分，无有效识别、未校准、传感器故障或金额超过 99.99 元时不显示有效价格。HX711 接线、去皮、校准和自动播报见 [接线与语音说明](docs/CX_SP5T_MAIN_INTEGRATION.md)。

## 工程与目录

| 位置 | 用途 |
|---|---|
| `user_source/` | RTL、IP 和引脚约束 |
| `td_project/anlogic_edge_osd.al` | 当前统一工程 |
| `sim/`、`verification/` | 测试台、回归脚本、静态检查 |
| `fruitcnn128_retrained_20261031/` | 最佳模型检查点和少量归档信息，不参与主工程编译 |
| `docs/reference/hardware/` | 开发板与相机接口图片 |
| `td_project/anlogic_edge_osd_Runs/phy_1/` | 后续重新构建的布局布线输出 |

TD GUI 可直接打开 `td_project/anlogic_edge_osd.al`。工程已固定为 `CongestionHigh`、Place seed `1` 和压缩 bit；开始运行前应关闭旧 TD 窗口后重新打开工程，确保加载更新后的配置。`build_firmware.cmd` 保留为命令行验收入口。

## 模型与验证

当前模型配置要求 CRC32 `3a37bea7`。主工程上电从 U30 读取并校验权重，硬件编译不读取电脑中的训练检查点。详见 [Flash 模型说明](docs/FRUIT_FLASH_BOOT.md)。

仅检查源码、路径和接口：

```powershell
python -B verification/check_merge_readiness.py
```

局部测试位于 `sim/`，整机构建验收由 `verification/run_image_quality_build.ps1` 完成。固定发布 bit 位于 `td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit`。

## 文档入口

- [代码导航](docs/CODE_MAP.md)
- [单目标形状识别](docs/SINGLE_TARGET_COLOR_SHAPE.md)
- [运动检测](docs/MOTION_DETECTION.md)
- [延迟显示](docs/LATENCY_VISUALIZATION.md)
- [称重接线与语音](docs/CX_SP5T_MAIN_INTEGRATION.md)
- [水果模型加载](docs/FRUIT_FLASH_BOOT.md)
