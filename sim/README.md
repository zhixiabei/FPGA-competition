# 仿真入口

以下命令均在项目根目录执行。测试会将编译产物和日志写到打印出的 TEMP 目录，
测试台与脚本留在本目录，不生成或更新 `firmware` 中的烧录文件。

## 常用检查

| 内容 | 命令 |
|---|---|
| 运动稳定性：生产参数、两种 RAM 模型 | `& './sim/run_motion_stability.ps1' -Pipeline Stable -Mode Both -CheckBehavior` |
| 三帧确认、短暂保持、平滑和复位 | `& './sim/run_motion_result_stabilizer.ps1'` |
| 真实 RAW 全链路六帧、连续 4 像素右移 | `& './sim/run_isp_motion_camera.ps1' -LineBlanking 32 -MovePixels 4` |
| 运动分支与 ISP 打包 | `& './sim/run_isp_lighting_integration.ps1' -Motion` |
| 红色分支与 ISP 打包 | `& './sim/run_isp_lighting_integration.ps1'` |
| 原始帧差与模式选择器 | `& './sim/run_motion_target_detect.ps1' -Mode Both` |
| 原始帧差慢移图像参考 | `& './sim/run_motion_realistic.ps1' -RequireDetections` |
| 自动曝光、RAW 统计和闭环 | `& './sim/run_auto_exposure.ps1'` |
| 白平衡与连续行尾 | `& './sim/run_awb_frame_adaptation.ps1'` |
| RAW 解包和去马赛克 | `& './sim/run_demosaic_quality.ps1' -CsiSource -Width 1280 -Height 720` |
| FIFO 图像完整性 | `& './sim/run_video_fifo_frame_integrity.ps1' -RawSource` |
| RAW10 分区统计与 HDMI 数字表 | `& './sim/run_raw_stats.ps1'` |
| 红色检测照明场景 | `& './sim/run_red_target_lighting.ps1'` |

按键、Scharr 和显示切换：

```powershell
.\sim\run_video_mode.cmd --no-pause 720
```

摄像头 I2C 配置、帧槽和 HDMI 目标叠加：

```powershell
.\sim\run_sc520.cmd --no-pause
```

## 当前结果与边界

2026-10-16 运动稳定性测试在便携 RAM、厂商 ERAM 下各通过 406 帧：
静止/干扰误触 0/168，8 组要求运动在前两帧确认后检出 120/120。
真实 RAW 六帧回归通过，每帧保留 720 个行尾。
完整规则、灵敏度和跟随延迟见 [运动检测说明](../docs/MOTION_DETECTION.md)。
日志和逐帧 CSV 归档在 [当前验证记录](../build/release/validation.zip)。

原始帧差测试直接实例化 `motion_target_detect_96` 的历史 6/8 默认参数，
选择器兼容测试关闭稳定器；它们不能代替生产 10/12 参数的稳定性回归。
测试不模拟 MIPI/HDMI 电气、真实 DDR 器件或传感器感光响应；
综合与时序另由 [构建入口](../build_firmware.cmd) 检查。

详细历史数字与旧版验证范围见 [仿真历史](../docs/history/SIMULATION.md)。
