# RAW 图像诊断

默认关闭九区 RAW 数字表，K1 循环十三种显示模式。自动曝光、LSC 和白平衡继续运行。九区表统计去马赛克及 AWB 前的 RAW10，不能用它代替最终 HDMI 图像的 RGB 测量。

## 九区表

诊断时将顶层 `design_top_wrapper.v` 的 `SHOW_RAW_STATS` 设为 1，再为该配置构建固件。主工程需要包含 `raw_region_stats.v` 和 `raw_stats_osd.v`。

用均匀照明的中性平面填满画面，避开反光。表中 R、GR、GB、B 分别为红、两种 Bayer 绿色和蓝通道，范围为 0～1023；不要先将两个绿色混为一个。每区统计 32×32 像素，每个通道 256 个样本。

```text
01 左上     02 上中     03 右上
04 左中     05 中心     06 右中
07 左下     08 下中     09 右下
```

`S` 表示该区至少一个样本达到 1023；低于 1023 不保证传感器内部没有限幅。`WAIT` 表示尚无完整结果，`STALE` 表示缺少新的完整结果，旧值不能当作当前测量。

E/G 是配置写完成的曝光控制码和增益档位，不是传感器回读或物理单位。AL/AW/AS 表示曝光统计更新状态，不能单独作为曝光已经收敛的证据。

## 其他诊断与验证

`isp/iq_diagnostic_stats.v` 提供独立的 RAW、LSC、AWB 阶段诊断；它与九区表属于不同统计路径。源帧统计不能直接声称与 DDR 当前显示帧一一对应。

```powershell
& './sim/run_raw_stats.ps1'
& './sim/run_iq_diagnostic_stats.ps1'
& './sim/run_isp_lighting_integration.ps1' -Diagnostics
```

工程引用检查使用 `python -B verification/check_merge_readiness.py`。当前版本状态见 [首页](../README.md)，此处不沿用旧诊断配置的面积和时序结论。
