# CNN 与延迟文字时序修复（2026-10-31）

## 修改范围和原因

本次基线为颜色检测改动后的完整工程，不能与更早的多目标版本或旧布局布线资源直接相减。
基线综合 setup WNS 为 -1.050 ns，240 个违例端点，最差路径位于
`fruitcnn128_core` 的 `kernel_reg -> ky_reg`：

`坐标生成 -> 动态行偏移 -> 卷积地址 -> 四路缓存标签比较 -> 项目推进控制`。

本次生产代码只改两份文件：

- `user_source/hdl_source/fruit_merged/fruitcnn128_core.v`：
  在接受启动时与 `iw` 同拍预译码 13 种宽度；实时行偏移改为并行固定移位选择，
  非二次幂宽度共享精确的 10 位 `3*y`。原预取地址函数保留。
  不改变状态机、24 路 MAC、缓存容量、DDR 握手或计算周期。
- `user_source/hdl_source/video_latency_osd.v`：
  数字字符直接按固定屏幕列并行选择，去掉字符选择前的列减法，
  ASCII 数字改为等价拼接。字体、坐标、大小、面板、告警及输出寄存延迟不变。

第一次仅修改 CNN 后，该时钟域已无违例，WNS +1.189 ns；
但同一次全工程综合中，原 HDMI 延迟文字路径回退至 -0.258 ns。
两次综合的 271 项源清单只有 CNN 文件不同，实际快照逐项匹配清单。
这说明未修改的模块也可能因整体综合映射而得到不同的估计时序；
不能将其直接解释为物理布线拥堵。因此继续优化了文字路径。

未修改时钟频率、SDC、工程路径、Flash、权重格式或其他业务模块；
未新增假路径或多周期约束。未运行布局布线、生成 bit 或烧录。

## 全工程综合对比

工具：Tang Dynasty v6.2.168116，PH1P35MDG324，Slow/Fast 双角；
均为同一脚本 `verification/run_image_quality_build.ps1 -SkipRoute`。

| 综合时序指标 | 修改前 | 最终版本 |
| --- | ---: | ---: |
| 全工程 setup WNS | -1.050 ns | +0.155 ns |
| 全工程 setup TNS | -135.374 ns | 0 ns |
| setup 违例端点 | 240 | 0 |
| CNN / DDR usr_clk WNS | -1.050 ns | +0.984 ns |
| MIPI / 检测 WNS | +0.155 ns | +0.155 ns |
| HDMI 像素 WNS | +0.568 ns | +0.180 ns |
| 全工程 hold WNS | +0.114 ns | +0.114 ns |
| hold TNS / 违例端点 | 0 ns / 0 | 0 ns / 0 |

两次综合正常完成，133 条工具警告逐条相同，无新增警告。
最终源清单为 `src-057f4a12e916`，271 项仅上述两份生产文件不同。
时钟、引脚、工程参数及所有其他 RTL 一致。

| 资源（同为 Optimize-Gate） | 修改前 | 最终版本 | 增量 |
| --- | ---: | ---: | ---: |
| Slice 综合估算 | 23,205 | 23,244 | +39，约 +0.17% |
| 综合 LUT 总数 | 30,099 | 30,100 | +1 |
| 寄存器 | 19,866 | 19,865 | -1 |
| ERAM | 95 / 108 | 95 / 108 | 0 |
| DSP | 39 / 40 | 39 / 40 | 0 |

本次尽量控制资源，但没有做到 Slice 综合估算完全不增长。
这里采用 `system_gate.area` 的总量，不能用 `gate.qor` 中部分逻辑的
`#slices` / `#luts` 代替整个设计的资源。
报告明确说明 Optimize-Gate 的 Slice/LUT 不是最终数量；基线和最终估算
都超过器件 21,216 Slice，不能据此保证能放得下，也不能将其与旧布局布线
的 Slice 数直接比较。最终实际占用及创意功能余量由新的物理结果确认。

## 行为验证

CNN 使用原有独立数值 golden 测试，并新增差分、吞吐和行地址边界检查：

| 验证 | 结果 |
| --- | --- |
| Portable RAM / 行为 DSP | 基线、候选各 27 个数值案例通过 |
| TD Vendor ERAM、DRAM / Vendor DSP | 基线、候选各 27 个数值案例通过 |
| 输出写地址及数据 | 两种模型下均逐位一致 |
| 调度统计 | 每个案例 cycles、MAC、DDR 读写、等待、立即响应及队列峰值完全相同 |
| 24 路并行与 3×3 吞吐 | 每种模型各 10,829 次连续计算检查通过，保持每拍一个项 |
| 行地址 | 256 种宽度 × 256 个行号，共 65,536 组与数学乘积/默认零一致 |
| 译码生命周期 | 启动捕获、运行保持、复位和连续切换几何参数通过 |

数值案例覆盖 1×1/3×3、stride 1/2、padding、多输出组、576 项权重尾部、
pooling、DDR 背压/立即及延迟响应、未完成读取时复位和重启。
两种模型的基线与候选均运行至 492,620 ns，编译及运行零错误、零警告。

延迟文字使用独立像素 oracle，三种布局均通过：

| 布局 | 检查像素 |
| --- | ---: |
| 紧凑 280×64 | 183,689 |
| 放大 400×112 | 417,545 |
| 侧边栏放大 320×112 | 336,905 |
| 合计 | 938,139 |

包括数值、N/A、小数点、MS、溢出告警、边界、DE 门控及单拍输出寄存检查。
侧边栏预览已人工查看，字体及布局保持原样。
最终工程静态源清单、接口、语音源和引脚检查通过。

## 证据和复现

工程内归档：

- `build/cnn_control_timing_20261031/synthesis/before/`：修改前源文件和综合报告；
- `build/cnn_control_timing_20261031/synthesis/width_decode/`：仅 CNN 修改的中间结果；
- `build/cnn_control_timing_20261031/synthesis/final/`：最终源文件、时序、资源、警告和源清单；
- `build/cnn_control_timing_20261031/candidate_portable/validation_manifest.json`；
- `build/cnn_control_timing_20261031/candidate_vendor/validation_manifest.json`；
- `build/cnn_control_timing_20261031/osd_pixels/`：三种布局的仿真日志、源码快照和预览。

最终 CNN SHA256：
`97F5F7456157B4C18D074CBA3401C8AFB814F2755C8C596FAA863F8A9D61104C`。

最终延迟文字 SHA256：
`D7AA430881F9206905187DFB9C3BFA9CF5BD681939D5C4D657F622907AB0102E`。

在工程根目录运行：

```powershell
& ./sim/run_fruitcnn128_timing_equivalence.ps1 -MemoryModel Portable -MacModel Behavioral
& ./sim/run_fruitcnn128_timing_equivalence.ps1 -MemoryModel Vendor -MacModel Vendor
& ./sim/run_video_latency_osd.ps1
& D:\python\python.exe -B verification/check_merge_readiness.py
& ./verification/run_image_quality_build.ps1 -SkipRoute
```

差分脚本默认使用工程内冻结的原始 CNN：
`build/cnn_control_timing_20261031/reference/fruitcnn128_core.v`，
也可显式传入 `-ReferenceRtl`。不要把候选自身当作基线来证明等价。

## 布局布线验收

综合使用估计网线延迟，不能替代布局布线后的实际 setup/hold 检查。
后续由用户运行原工程布局布线，检查全工程 setup/hold WNS 非负、
TNS 为零且违例端点数为零，再确认实际 Slice、ERAM 和 DSP 数量。
创意功能余量也以该次物理资源报告为准。
