# 资源压缩记录

本文保留 2026-10-20 20:05 发布的上一轮记录。后续从 `src-f87677ec3bf9`
继续降低 Slice、LUT 和 FF 的结果见 [Slice 压缩实施记录](SLICE_COMPRESSION_RESULTS.md)。
复核本轮历史版本请使用冻结报告或文末原证据包；当前发布身份见
`build/release/release_manifest.json`。

本轮保留十三种显示模式、红/绿/蓝/运动选择、最多四个颜色/形状框、运动稳定器及延迟面板。
优化基线是任务开始时的实际发布 `src-ce2c2ba521ae`；
当时全部 222 个生产构建输入与发布清单一致，包含已有的紧凑延迟面板。
不使用 README 中更早的形状版资源数作为本轮基线。

本历史版最终资源以 [冻结布局布线报告](../build/slice_compression/baseline_release/release/system_phy.area) 为准，
时序见 [冻结最终时序报告](../build/slice_compression/baseline_release/release/system_pr.timing)，
源码、版本和烧录文件身份见 [冻结发布清单](../build/slice_compression/baseline_release/release/release_manifest.json)。
门级报告中的 `#slice*` 是布局前估算，不能与最终 Slice 数混用。

## 最终采用结果

本轮以 **Slice 和 LUT6 同时降低** 为验收条件，采用已完成最终布线的
`src-f87677ec3bf9`，构建时间为 2026-10-20 20:05:30（北京时间）。

| 项目 | 优化前 `src-ce2c2ba521ae` | 最终采用 `src-f87677ec3bf9` | 变化 |
|---|---:|---:|---:|
| Slice | 18,958 / 21,216（89.36%） | 18,929 / 21,216（89.22%） | −29 |
| LUT6 | 18,318 | 18,200 | −118 |
| 寄存器 | 17,783 | 17,784 | +1 |
| ERAM | 79 / 108 | 79 / 108 | 0 |
| DSP | 15 / 40 | 15 / 40 | 0 |
| 建立 / 保持余量 | +0.108 / +0.020 ns | +0.103 / +0.020 ns | 均通过 |

显示配置 13 ns 约束覆盖 4 条有效路径，目标帧上下文 / 结果 / 显示快照的
20/20/13 ns 约束分别覆盖 4,192 / 4,318 / 257 条有效路径，
无无效约束或无路径约束。全部 222 个生产构建输入与采用版本的发布清单一致。
烧录文件 SHA256 为
`C7198DCA1EF63A4C81B6E53D3C4830F4CC88F6F6250D1082F3D101F085EEB2F1`。

## 保留的改动

1. `target_detect_switch_96.v` 的坐标平滑改为共享有符号差值、偏置和算术右移。
   保持死区、四分之一步进和正负方向的原有舍入，不改变三帧确认及漏检保持策略。
2. `scharr_edge_detect_96.v` 的四个重叠形态学窗口共享每行 `(b,c)`、`(d,e)` 的最小/最大值。
   横向比较表达由 48 次减为 36 次，沿用原寄存器和固定 11 拍流水；
   Scharr、浮雕、漫画、形态学的输出接口和参数不变。
3. `target_frame_bridge.v` 对四个物理槽分别使用静态结果写口，
   以互斥掩码合并当前结果和缓存结果，保持写帧开始的优先级、有效位及跨时钟协议。
   门级面积没有单独改善，最终三项组合以实际布线结果验收。

没有增加 DDR 图像访问或整帧缓存。RGB 延迟 RAM 保留原 DP 实现；
寄存器的 +1 是最终物理实现计数，门级寄存器总数不变。

## 功能验证

| 检查 | 本轮结果与范围 |
|---|---|
| `run_motion_smoothing_equivalence.ps1` | 默认死区 8 穷举全部 16,777,216 组 12 位坐标；死区 0/1/7/16/64/4095/4096 另核对 682,294 组边界；独立加权平均参考，新旧实现分别通过 |
| `run_motion_result_stabilizer.ps1` | 66 次输入、65 次输出及 1 次复位取消；确认、保持和平滑通过 |
| `run_motion_stability.ps1 -Pipeline Stable -Mode Both -CheckBehavior` | 两种 RAM 各 406 帧、14 场景；静止/干扰误触 0/168，要求稳定检出 120/120；逐帧 CSV 完全一致 |
| `run_scharr_morphology_equivalence.ps1` | 4 个尺寸/参数配置逐拍对照原版，分别运行 628、829、7,195、28,272 拍；四路图像及控制一致，覆盖空拍、提前 SOF、连续/截断帧、奇数帧高和复位 |
| 同脚本的独立图像参考 | 默认 Gaussian=1，28 帧、77,376 像素、21,427 拍；Scharr、浮雕、漫画、反色选择及形态学通过，九个 min/max 极值位置全覆盖 |
| 帧槽桥与两项系统帧对齐回归 | `run_target_frame_bridge.ps1` 的 30 项检查，以及 `run_target_frame_alignment.ps1`、`run_red_multi_frame_alignment.ps1` 全部通过，实际桥源码与采用版本一致 |
| `run_target_frame_bridge_slot_writes.ps1` | 最终静态槽写法通过 11 项检查，覆盖并发来源、重复物理槽、写入优先级、清有效位和复位 |
| `run_video_latency_osd.ps1` | 25 项状态、88,966 个面板像素、5,602 个字形像素及 3,584 个告警像素检查通过 |
| `run_latency_display_toggle.ps1` | 8 帧、2,867,200 像素、41 项检查通过 |
| `run_isp_motion_camera.ps1 -LineBlanking 32 -MovePixels 4` | 采用版本的 DP 源码、真实 RAW 输入与安路 RAM 模型；6 帧、1,382,400 组 RAW/AWB、1,036,800 个打包字；第 4 帧确认、第 5 帧保持及 13 拍结果延迟通过 |

平滑与形态学测试入口见 [仿真说明](../sim/README.md)。
形态学差分脚本默认使用 `build/resource_optimization/baseline/scharr_edge_detect_96.v`，
也可通过 `-ReferenceRtl` 指定原版；该原版 SHA256 为
`1C6FC90569DC5E6417329A478D18ED40AFF054FC054ADBAC43D2EB2C66B07905`。

现有独立图像参考的 Gaussian=0 选择器断言，在优化前后均于 cycle=4300 失败。
该测试限制的原版诊断日志单独归档，不算通过项；
Gaussian=0 的等价性由 20×17/TH=0 和 1280×9/TH=21 两组原版差分覆盖。
这些仿真验证数字行为；实拍画质、物理摄像头、DDR 和 HDMI 器件仍需上板确认。

原始日志、实际执行源码、基线和最终报告见
[资源压缩证据包](../build/verification/resource_optimization_regression.zip)。

## 未采用的 RAM 方案

曾验证 RGB 延迟 RAM 的 PDPW 实现，其局部 ERAM 从 5 块降到 3 块，
厂商模型对照及 RAW 回归通过。全工程 `src-117f57456f5a` 的最终布线却为
Slice 18,989、LUT6 18,188、ERAM 77；Slice 比优化前增加 31，
不满足本轮验收条件，已撤回，当前生产源码与 bitstream 均不含该改动。
后续组合试验也已取消。相关报告仅在证据包的诊断目录保留，
不作为最终结果或主通过项。
