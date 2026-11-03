# 当前代码导航

统一入口为 [主工程](../td_project/anlogic_edge_osd.al)；操作、模型依赖和验收状态见 [首页](../README.md)。

## 生产模块

下列路径相对于 `user_source/hdl_source/`。

| 模块 | 职责 |
|---|---|
| `design_top_wrapper.v` | 相机、ISP、DDR、显示、识别、称重及语音连接 |
| `isp/isp_top.v` | RAW 到 RGB 的图像处理及检测连接 |
| `auto_exposure_control.v`、`isp/ae_frame_stats_raw10_4x.v` | 曝光闭环与 RAW 统计 |
| `awb.v`、`isp/lsc_raw10_4x.v` | 白平衡和镜头阴影补偿 |
| `display_effect_control.v`、`display_effects_rgb888.v` | 显示模式控制与 RGB 特效 |
| `isp/scharr_edge_detect_96.v` | 边缘和相关空间处理 |
| `isp/target_detect_switch_96.v` | 颜色/运动检测切换及运动稳定处理 |
| `isp/red_target_detect_96.v` | 颜色检测、单目标轮廓和共享形状描述器 |
| `target_frame_bridge.v` | 检测结果和视频帧元数据交接 |
| `hdmi_mixer.v` | HDMI 画面、检测框与文字叠加 |
| `video_latency_timebase.v`、`video_latency_monitor.v`、`video_latency_osd.v` | 时间基准、帧延迟与显示 |
| `fruit_merged/fruitfixed_system.v` | 当前水果系统、固定 ROI 和识别控制 |
| `fruit_merged/handfixed_background.v`、`handfixed_preprocess.v` | RGB 背景比较和预处理 |
| `fruit_merged/fruitcnn128_core.v`、`handfixed_config.v` | RGB128 推理与模型配置 |
| `voice/` | 稳定结果判定、音频组合与 CX-SP5T UART |

`fruit_merged/` 内保留的 `handfixed_*` 名称是沿用的模块命名，不代表当前使用手势模型。旧独立 `handfixed/`、SC500 配置、重复 AWB/IP 及 RAW/IQ 调试显示已清理；`resnet/`、`resnet18/` 中被水果推理或测试引用的共享模块保留。

## 约束与检查

引脚约束在 `user_source/constraints_source/`，主时序约束在 `td_project/anlogic_edge_osd.sdc`。工程文件中的源文件列表是实际综合输入依据。

[静态检查](../verification/check_merge_readiness.py) 核对源文件存在性、模块接口、SW1/SW2 引脚与上游核心逻辑保护。[仿真索引](../sim/README.md) 列出当前回归入口。

形状处理集中在 `red_single_shape_engine`：受限地补齐内部小缺口，并将共享运算器的操作数选择与执行拆开。边界见 [形状说明](SINGLE_TARGET_COLOR_SHAPE.md)。
