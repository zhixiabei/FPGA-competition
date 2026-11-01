# 仿真入口

在工程根目录运行以下命令。统一工程的水果 RTL 位于 `user_source/hdl_source/fruit_merged/`；旧独立手势流程已撤下。

测试通常输出到 TEMP 或脚本指定的 `build/` 目录，具体以脚本打印路径为准。回归不会生成生产 bit。ModelSim 和 XSim 路径可通过各脚本参数调整。

## 当前形状与水果逻辑

| 检查 | 命令 |
|---|---|
| 轮廓小孔修复，便携/厂商 RAM | `& './sim/run_single_shape_contour.ps1' -Mode Both` |
| 描述量与共享运算器短回归 | `& './sim/run_single_shape_contour.ps1' -Mode Portable -ProductionProbe` |
| 720p 生产参数 | `& './sim/run_single_shape_contour.ps1' -Mode Vendor -Width 1280 -Height 720 -ProductionProbe -TimeoutSeconds 900` |
| 单目标颜色/形状 | `& './sim/run_single_color_shape.ps1' -Mode Portable` |
| 单目标跟踪 | `& './sim/run_single_color_track_robust.ps1' -Mode Portable` |
| 单目标模式切换 | `& './sim/run_single_target_switch.ps1' -Mode Both` |
| RGB ROI 预处理与背景 | `& './sim/run_fruit_roi_preprocess.ps1'` |
| 水果确认、空框清除与结果保持 | `& './sim/run_fruit_roi_system.ps1'` |
| Flash 加载与 CRC | `& './sim/run_fruit_flash.ps1'` |

完整场景和已执行结果分别见 [形状修复记录](../verification/single_shape_contour_20261101.md) 与 [融合记录](../verification/github_merge_20261101.md)。本页列出的是可用入口，不表示每次修改都重新执行全部测试。

## 图像与显示

| 检查 | 命令 |
|---|---|
| K1 十三模式控制 | `& './sim/run_display_effect_control.ps1'` |
| RGB 特效 | `& './sim/run_display_effects_rgb888.ps1'` |
| 显示模式与像素 | `& './sim/run_display_effects_mixer.ps1'` |
| 镜头签名、暂停清空、帧配置和 720p 镜像 | `& './sim/run_signature.ps1'` |
| 自动曝光 | `& './sim/run_auto_exposure.ps1'` |
| RAW 直方图 | `& './sim/run_ae_histogram.ps1'` |
| 白平衡可信度 | `& './sim/run_awb_confidence.ps1'` |
| RAW/LSC/AWB 诊断 | `& './sim/run_iq_diagnostic_stats.ps1'` |
| ISP 多模式集成 | `& './sim/run_isp_lighting_integration.ps1' -AllModes` |
| 运动稳定性 | `& './sim/run_motion_stability.ps1' -Pipeline Stable -Mode Both -CheckBehavior` |
| 运动结果保持 | `& './sim/run_motion_result_stabilizer.ps1'` |
| 延迟测量 | `& './sim/run_video_latency.ps1'` |
| 延迟文字与面板 | `& './sim/run_video_latency_osd.ps1'` |
| 框与帧对齐 | `& './sim/run_target_frame_alignment.ps1'` |
| FIFO 图像完整性 | `& './sim/run_video_fifo_frame_integrity.ps1' -RawSource` |
| RAW 分区表 | `& './sim/run_raw_stats.ps1'` |

## 静态检查与语音

```powershell
python -B verification/check_merge_readiness.py
python -B verification/test_voice_project_sources.py
python -B verification/run_scale_voice_tests.py --modelsim C:/altera/14.1/modelsim_ase/win32aloem
```

静态检查不调用 FPGA 工具。语音回归调用 ModelSim。

## 测试输入

`reference/` 保留当前回归所需的器件仿真模型。旧实验基准及只用于这些基准的对比脚本已经成套移除；剩余测试使用当前源码，部分数学等价测试在脚本内生成参考。

`*_work/`、`out_*/`、`__pycache__/` 属于可再生成缓存。已执行的形状修复和融合验证见首页链接的两份记录。
