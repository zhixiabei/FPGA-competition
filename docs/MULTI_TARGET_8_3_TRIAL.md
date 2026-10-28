# 多目标 8 候选、3 输出试验

日期：2026-10-27。默认配置已改为 8 个活动候选、最多 3 条输出轨迹。
本次只运行仿真和综合，没有布局布线，也没有更新生产 bit。

## 实现范围

- `red_target_detect_96` 和 `red_multi_run_engine` 新增
  `CANDIDATE_SLOTS=8`、`MAX_TARGETS=3` 参数；支持对照配置 16/4。
- 活动候选有效位从 16 位缩为 8 位，扫描、匹配和空槽索引从 4 位缩为 3 位。
- 候选 RAM 地址 0..7 保存活动区域，8..10 保存前三个目标的形状特征；
  RAM 逻辑深度从 32 改为 16，特征记录的精度不变。
- 目标框、面积、跟踪与形状稳定记录按 3 项分配；关联扫描改为 3×3，
  保持先轨迹、后检测的遍历顺序。
- 外部仍使用四路接口，未使用的第四路有效位、保持位、坐标和形状全部为零。
  DDR 的四个帧槽是另一种容量，本次没有缩减。
- 面积、周长、四方向跨度、一阶矩和原有形状判据保留。
  `color_shape_descriptor` 模块正文与修改前逐字一致。

候选不足和 FIFO 拥塞都沿用原来的整帧无效处理，不输出不完整的目标结果。
9 个同时存活的独立候选会超出本版容量。每帧先按实际过滤像素支持量选取前三，
再按原有轨迹关联、确认、漏检保持和形状稳定规则输出。
由于轨迹保留机制，显示中的编号不等于当前帧面积排名。

## 综合对比

综合工具：Tang Dynasty v6.2.168116，器件 PH1P35MDG324。
旧报告来自上一版形状优化后的 16/4 源码，新报告来自本次 8/3 源码。
对比源文件校验清单，只有 `red_target_detect_96.v` 发生变化。

| 范围与资源 | 原 16/4 | 新 8/3 | 差值 |
|---|---:|---:|---:|
| 多目标引擎 logic LUT，包含形状描述器 | 2316 | 2238 | -78 |
| 多目标引擎 ripple | 505 | 458 | -47 |
| 多目标引擎寄存器 | 1533 | 1354 | -179 |
| 多目标引擎 ERAM | 8 | 8 | 0 |
| 多目标引擎 DSP | 2 | 2 | 0 |
| 整机总 LUT | 30912 | 31100 | +188 |
| 整机寄存器 | 19826 | 19513 | -313 |
| 整机综合 Slice 估算 | 23836 | 23630 | -206 |
| 整机 ERAM | 99 | 99 | 0 |
| 整机 DSP | 40 | 40 | 0 |

`logic LUT`、`ripple` 与报告中的整机总 LUT 是不同统计列，不能混用。
改变容量后综合映射也会改变，总 LUT 本次增加了 188；不能声称所有资源都下降。
综合报告明确指出 Slice 估算不是最终布局值。没有本版实际布局 Slice，
也不能从之前的布局值 21117 直接减去 206。
本次收益主要体现在寄存器和综合 Slice 估算，幅度有限。
候选 RAM 按 40 位宽分为 6 个 ERAM，FIFO 使用另外 2 个；
减少浅 RAM 的深度没有减少这些物理 RAM 块。

报告与备份：

- 修改前检测源码：`build/multi_three/baseline/red_target_detect_96.v`。
- 旧综合报告：`build/multi_three/reports/baseline_gate.area`。
- 新综合报告：`build/multi_three/reports/trial_gate.area`。
- 新综合源校验清单：`build/multi_three/reports/source_sha256.csv`。
- 本次综合版本：`src-47db933a683b`。
- 本次综合目录：
  `C:/Users/1/AppData/Local/Temp/anlogic_image_quality_eb3d2dc9badd4f6a9ec07808c79223af`。

## 验证

以下测试已通过：

| 测试 | 配置与覆盖 |
|---|---|
| 多目标全回归 | 8/3，Portable 和 Vendor；34 帧、54 检查，面积取前三、移动跟踪、清除、拥塞和恢复 |
| 候选边界 | 实际到达 8 个活动候选；第 9 个触发整帧无效；容量错误帧 FIFO 峰值 7，区别于 FIFO 拥塞 |
| FIFO 拥塞 | 连通梳状输入产生大量行程段，FIFO 峰值 63，检查整帧拒绝和恢复 |
| 720p 吞吐 | Vendor，3 帧、9 检查；四条行程段、零行消隐、按面积选三、移动后槽位稳定，FIFO 峰值 1 |
| 多颜色形状 | Vendor，109 帧、215 检查；红绿蓝、方形/三角形/圆形/未知、30 个噪声样例、3 个几何探针 |
| 旋转回归 | Portable 和 Vendor；每种模型 60 帧、30 检查 |
| 形状稳定 | Portable 和 Vendor；各 52 帧、59 检查；连续确认、换类、过期、漏检、截帧、清除和错误恢复 |
| 颜色与运动切换 | Vendor；18 个结果、37 检查、3 次跨 SOF；保持原帧号与相邻完成的顺序 |
| ISP 720p 集成 | AWB、目标检测、显示流水和 DDR 打包；3 帧、6 个框/形状检查、3 次槽位保持，518400 个打包字 |
| 显示对齐 | 真实顶层、桥接、混合器，compact 和普通模式；各 23 次写帧、19 次显示，颜色/形状/保持/冻结/迟到结果对应检查 |
| 16/4 对照 | 多目标与切换 Vendor、形状与稳定 Portable 配置通过 |

上述容量、切换和形状测试检查未使用第四路的全部字段为零。
显示对齐测试保留四路注入，用于验证外部接口兼容；
其中相机算法、CNN 和物理 DDR 是测试边界，不代表 CNN 本次进行了功能回归。
完整 720p 多目标全回归曾主动停止，最终使用专门的 720p 吞吐测试，
配合小分辨率全回归和真实 ISP 集成测试验收，不能将停止的运行算作通过。

常用重跑命令：

```powershell
.\sim\run_red_multi_target.ps1 -Mode Both
.\sim\run_red_multi_target.ps1 -Mode Vendor -Width 1280 -Height 720 -RateOnly
.\sim\run_color_shape_target.ps1 -Mode Vendor -TimeoutSeconds 600
.\sim\run_color_shape_rotation.ps1 -Mode Both -TimeoutSeconds 600
.\sim\run_color_shape_stability.ps1 -Mode Both -TimeoutSeconds 600
.\sim\run_red_multi_switch.ps1 -Mode Vendor
.\sim\run_isp_red_multi.ps1
.\sim\run_red_multi_frame_alignment.ps1 -CompactMode
.\verification\run_image_quality_build.ps1 -SkipRoute
```

## 恢复容量

将检测器参数设为 `CANDIDATE_SLOTS=16`、`MAX_TARGETS=4` 可恢复容量。
两个模块均保留这组配置；仿真脚本支持
`-CandidateSlots 16 -MaxTargets 4`。
原始修改前源码另有独立备份，可用于逐项对照。

生产 bit 仍为：
`td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit`。
SHA256：
`6189CA22F268ADDC004386A2F75DE505016CADBF780D4329CED91A827CDDAEAF`。
