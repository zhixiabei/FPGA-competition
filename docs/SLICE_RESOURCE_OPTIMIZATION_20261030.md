# 总工程 Slice 压缩实施记录（2026-10-30）

本轮接续 [总工程资源压缩方案](proposals/RESOURCE_COMPRESSION_VOICE_MAIN.md)，以已完成语音优化的完整工程为基线。保留 1280×720、每拍四像素、全部显示模式、颜色/形状检测、计价和播报、Flash 启动，以及 CNN 的 24 路 MAC、权重和数值精度。实际保留项按同配置综合、布局布线和功能验证结果选择。

## 工程入口与基线

生产入口为 [td_project/anlogic_edge_osd.al](../td_project/anlogic_edge_osd.al)。开始执行时，该文件有 10 个失效文件引用，包括不存在的 `unified_fruit` 源码和约束文件。原工程已备份到 `build/slice_optimization/entry_before_repair/`；现在恢复为完整工程配置，110 个文件引用全部存在。相对本轮冻结工程只改变工作区路径，器件仍为 PH1P35MDG324、速度等级 -3。

基线源码为 `build/slice_optimization/baseline/input/`，冻结前核验全部 269 个 `user_source` 文件的 SHA256，与前轮语音优化构建完全一致。综合源版本为 `src-e8478fbc7389`。本轮生产源和约束的最终校验清单见 `build/slice_optimization/final_source_sha256.json`，机器可读结果见 `build/slice_optimization/comparison.json`。

最终核验覆盖 271 个生产输入：269 个 `user_source` 文件逐字节 SHA256 一致；工程配置允许工作区路径变化；SDC 文本完全一致，仅工作区 CRLF 与冻结 Git 原件 LF 的换行格式不同。

最终选定构建源版本为 `src-28a427acf299`。布局布线数据库另存于 `build/slice_optimization/eram_shape_static/route/system_pr.db`（SHA256：`e6e6662119db260c5d286ae6fe06504aab70b0498338e3174a4695c822415d18`），避免验证结果只存在于临时目录。

`td_project/fruit_scale_voice_Runs/volume30/` 中旧的 16,362 Slice 报告来自另一套裁剪工程，不参与本轮对比。综合 `system_gate.area` 的 `#slice*` 为布局前估算，最终面积仅采用同一阶段 `system_phy.area` 的 `#slice`。

## 实施内容

1. **CNN 权重缓存全部使用 ERAM。** `fruitcnn128_core.v` 原本将 576×192 位缓存拆为 512 行 ERAM 加 64 行分布式 RAM。现在采用单一 576 行同步 ERAM，消除 192 个分布式 RAM LUT、尾部读寄存器和 192 位输出选择。增加 5 块 ERAM，读写拍数、DDR 协议、合法描述符范围和 24 路 MAC 保持一致。
2. **归一化表映射为同步块 ROM。** `handcnn_normalize.v` 的 case 表改为 1024×12 位 ROM，存放原始精确值，输出保持 16 位符号扩展和一拍延迟。mode=0、未使用通道仍返回零。实际综合映射为 1 块 ERAM、6 个逻辑 LUT、1 个 FF；原表为 180 个逻辑 LUT、12 个 FF。
3. **形状描述器静态分段选择。** `red_target_detect_96.v` 中四处 `value >> (limb_index*13)` 改为常量切片和索引译码。状态、位宽和完成拍数保持一致。此项整机综合估算比仅 ERAM 版少 84 Slice，最终物理比较少 103 Slice，因此保留；模块自身逻辑 LUT 从 948 变成 954，不能声称局部 LUT 一定减少。

两项 ERAM 调整共使用额外 6 块 ERAM，整机为 100/108；DSP 仍为 39/40。语音 RTL 保留本轮开始时已有的优化版本。

## 面积与时序

所有候选使用冻结的完整工程、相同约束和 TD 6.2.168116；三个参与最终比较的版本都从各自综合数据库启动，place seed 固定为 1。运行目录相互独立，验证过程不写入 GUI 的构建目录。

| 版本 | 综合 Slice 估算 | 综合 FF | ERAM | DSP | 处理 |
|---|---:|---:|---:|---:|---|
| 本轮基线，已有语音优化 | 23,333 | 20,322 | 94 | 39 | 冻结对照 |
| 权重缓存和归一化表使用 ERAM | 22,956 | 20,118 | 100 | 39 | 参与物理比较 |
| ERAM 加形状静态分段 | 22,872 | 20,118 | 100 | 39 | 参与物理比较 |
| 上项加漫画专用延迟 | 22,891 | 20,119 | 100 | 39 | 已撤回 |
| ERAM、形状加共用 BCD | 22,924 | 20,124 | 100 | 39 | 已撤回 |
| ERAM、形状、漫画加共用 BCD | 23,055 | 20,125 | 100 | 39 | 已撤回 |

<!-- FINAL_PHYSICAL_RESULTS -->
| 版本 | 布局结束 Slice（`place.qor`） | 最终布线 Slice（`system_phy.area`） | 最终 setup 余量 | 最终 hold 余量 |
|---|---:|---:|---:|---:|
| 本轮基线 | 20,461 | 未完成 | 未取得 | 未取得 |
| 仅 ERAM 替换 | 20,009 | 20,009 | +0.105 ns | +0.021 ns |
| **ERAM 加形状静态分段，最终保留** | **19,906** | **19,906** | **+0.110 ns** | **+0.020 ns** |

同一布局阶段的 Slice 减少 **555（2.71%）**。最终保留版已完成完整布局布线：Slice **19,906/21,216（93.83%）**，LUT6 **19,721**，FF **19,769**，ERAM **100/108**，DSP **39/40**。Slice 余量为 **1,310**，ERAM 余量为 8；距离建议的 19,000 Slice 目标仍差 906。

基线 seed=1 的完整对照运行在 **90.55 分钟**处达到本轮设定的 90 分钟上限并停止，当时仍在高拥塞的时序修复/重新布线阶段。完整日志、`place.qor`、布局时序及中止状态保留在 `build/slice_optimization/baseline/route/`。**基线没有最终布线面积和时序报告，因此本轮没有最终布线后前后面积差值，也无法据此判断基线最终时序。555 的减少量仅来自同阶段布局报告。** 最终优化版本身的完整布线、setup/hold 和约束覆盖均已通过。

最终版五组 CDC 规则覆盖路径数依次为：display effect 4、frame context 412、detector result 193、display snapshot 160、AE statistics 24。全部路径受原来的 13/20 ns 限制，shadowed/ignored 均为 0。
<!-- END_FINAL_PHYSICAL_RESULTS -->

## 未保留的尝试

- **漫画中心/最终延迟专用化：** 尝试将只消费中心像素的通用窗口替换成专用延迟。便携模型与厂商 RAM 模型的逐拍对照通过，独立像素参考通过，但当前器件每实例仍需要 2 块 ERAM，整机综合估算反而增加 19 Slice。生产 `scharr_edge_detect_96.v` 已恢复为冻结基线。
- **语音共用 BCD：** 利用组句等待时间分时处理重量、金额，逐拍输出对照、计价和串口测试通过。但整机综合估算增加 52 Slice；与漫画候选叠加时增加 164 Slice。生产 `scale_voice_phrase.v` 已恢复为冻结基线，保留原有语音优化。

上述候选的综合输入、哈希和报告分别保留在相应 trial 的 `input/` 和报告目录中；被撤回的 BCD 仿真日志位于 `verification/*_rejected_bcd/`，与最终语音回归日志分开存放。漫画测试脚本增加厂商 RAM 模型选项及 PowerShell 5 进程退出码处理，保留为后续验证工具。

## 验证证据

以下目录均相对于 `build/slice_optimization/verification/`。

| 检查 | 结果与覆盖 | 日志 |
|---|---|---|
| CNN 数值参考，厂商 ERAM 与 DSP 模型 | 23 个案例；576 权重尾段、多输出组、三种 DDR 响应及背压、池化、饱和/ReLU、挂起响应时复位、无复位切层 | `cnn_vendor_numeric/console.log` |
| 归一化表与冻结基线逐拍比较 | 2048 地址升序和降序，4096 次检查，一拍延迟 | `eram_norm_final/simulation.log` |
| 形状描述器新旧对照 | 4800 组，STABLE_INPUTS=0/1，结果和中间计算一致，clear/reset 取消一致，全部完成拍差为 0 | `shape_descriptor_equivalence/console.log` |
| 720p 集成，厂商 ERAM 模型 | 25 个场景、66 次结果、159 项检查通过；含超过 1024 的坐标、三色形状、稳定/丢失保持、部分帧中止、clear/reset、空拍和连续行 | `single_shape_720p_complete/simulation.log` |
| 最终语音逐拍对照 | 16384 个 14 位值、1024 组 24 位随机值、160000 拍控制、0～31 字节传输 | `voice_equivalence_final/simulation.log` |
| 最终计价、语音和串口集成 | 五种单价、105 组句、稳定、串口线级解码、播放超时和链路测试通过 | `scale_voice_tests_final/simulation.log` |

720p 集成首次运行的 `single_shape_720p/` 在 600 秒墙钟上限处停止，当时图形场景及 temporal 检查均已通过，没有功能断言失败。完整重跑使用 1800 秒上限，已全部通过；首次运行不计为完整通过证据。

归一化测试归档时修复了 Windows 文本写入导致空行重复的问题，并以当前源码逐字节一致的快照重跑 `eram_norm_final`，4096 次检查再次通过。生产 RTL 未因此改变。

物理验收还要求 setup/hold 余量非负、0 条失效约束、0 条无路径约束。对显示效果 CDC（13 ns）、frame context（20 ns）、检测结果（20 ns）、显示快照（13 ns）和 AE 统计（20 ns），逐条检查路径数大于零、全部受约束、无 shadowed/ignored 路径，并确认兼容 AWB 无多余 hold 例外。时钟、管脚和 CDC 约束采用基线原件。

## 复现

在仓库根目录执行；本机 Python 为 `.conda/fruitcuda/python.exe`，TD 为 `E:/TD_6.2.1_Engineer_6.2.168.116/bin`，ModelSim 为 `E:/modelsim/modelsim_ase/win32aloem`。

```powershell
# 当前 RTL 的新综合：名称必须全新，已有基线和候选不覆盖。
.conda/fruitcuda/python.exe -B verification/run_slice_resource_check.py new_trial
.conda/fruitcuda/python.exe -B verification/run_slice_route_check.py new_trial

# 归一化逐拍比较；720p 集成。
.conda/fruitcuda/python.exe -B verification/run_slice_equivalence.py new_norm_test
.conda/fruitcuda/python.exe -B verification/run_slice_equivalence.py new_shape_test --suite single_shape

# 使用实际厂商存储器和 DSP 的 CNN 数值参考。
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_fruit_core_numeric.ps1 `
    -MemoryModel Vendor -MacModel Vendor `
    -ModelSimBin E:/modelsim/modelsim_ase/win32aloem `
    -TdSimLib E:/TD_6.2.1_Engineer_6.2.168.116/sim_release/ph1p

# 对照本轮形状基线。
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_shape_descriptor_equivalence.ps1 `
    -ReferenceRtl build/slice_optimization/baseline/input/user_source/hdl_source/isp/red_target_detect_96.v `
    -ModelSimBin E:/modelsim/modelsim_ase/win32aloem -TimeoutSeconds 300

.conda/fruitcuda/python.exe -B verification/run_voice_equivalence.py
.conda/fruitcuda/python.exe -B verification/run_scale_voice_tests.py

# 核对最终生产输入、物理面积、时序、CDC 覆盖及测试证据，生成汇总。
.conda/fruitcuda/python.exe -B verification/summarize_slice_optimization.py --selected eram_shape_static
```

最终面积来自完整布局布线；本轮尚未生成新的 bit，也未进行上板验证。现有烧录文件仍对应此前版本，采用本轮源码上板时需重新生成。
