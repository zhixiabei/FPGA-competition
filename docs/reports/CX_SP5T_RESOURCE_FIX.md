# 语音黑盒修复与资源优化

日期：2026-10-30。工作区基线为合并语音后的 `f850195`。本次仅修复语音工程清单、优化语音 RTL，并补充检查与仿真。没有运行布局布线、生成 bit、下载 FPGA 或写入 Flash。

## 黑盒原因与修复

现场 `HDL-7144 unknown module` / `HDL-8007 black box` 来自主工程 `td_project/anlogic_edge_osd.al` 漏掉五个语音源文件；文件本身仍在 `user_source/hdl_source/voice/` 中。已恢复这些文件的工程条目和综合启用标志。视频入口 `anlogic_sc520_capture.al` 原已包含这些条目。

`verification/check_merge_readiness.py` 现在检查实际 `.al` 中五个语音模块是否存在且启用，防止“仿真通过、真实工程漏文件”。新增 `test_voice_project_sources.py` 验证完整清单能通过，逐个移除、关闭综合或自动排除五个模块都会被拒绝。

若 TD 已打开旧工程，关闭并重新打开 `td_project/anlogic_edge_osd.al`，确认五个语音文件均出现在源文件列表，再重新综合和布局布线。

## 保留功能与优化方式

稳定窗口、样本新鲜度、去重、空秤重新使能、音量 30、TF 初始化、返回串口状态查询和播放超时均保留。语音接口仍为原有的 24 位重量/金额和 200 位组合播放接口。

- 生产适配层原始数据为 14 位，内部按 14 位计算；通用模块默认仍支持完整 24 位。
- 重量与金额顺序复用一套二进制转十进制电路。
- 语音编号使用紧凑移位缓存，再展开成原协议字节；生产最多 14 个音频片段。
- 串口缓存按生产音量和音频编号缩为每字节 5 个有效位、最多 14 字节。独立串口模块默认仍支持完整 8 位、25 字节。
- 毫秒计时器、样本计数和串口位置计数按实际参数缩短。

重量与金额的组合构建多用几十个时钟周期，在生产 66.666667 MHz 时钟下不到 2 微秒；串口波特率和播报内容不变。

## 本机同配置综合对比

两次均使用 `D:/TD/bin` 的 TD 6.2.168116、同一主工程和约束，仅运行 `run_image_quality_build.ps1 -SkipRoute`。两份源文件 SHA256 清单比较后，仅五个语音 RTL 文件不同。两次均得到 `IMAGE_QUALITY_SYNTHESIS_PASS`。

| 项目 | 修复清单后、优化前 | 优化后 | 减少 |
|---|---:|---:|---:|
| 语音层级 logic LUT | 708 | 541 | 167（23.6%） |
| 语音层级寄存器 | 675 | 457 | 218（32.3%） |
| 语音层级 ripple | 149 | 134 | 15 |
| 语音层级 F7 mux | 8 | 0 | 8 |
| 全工程估算 Slice `#slice*` | 23599 | 23374 | 225 |
| 全工程寄存器 | 20520 | 20302 | 218 |
| 全工程 ERAM | 94 / 108 | 94 / 108 | 0 |
| 全工程 DSP | 39 / 40 | 39 / 40 | 0 |

语音层级为 `handcnn_recognition$u_checkout_voice`，两版均使用 0 DSP、0 ERAM。子模块如下：

| 子模块 | logic LUT：优化前 → 后 | 寄存器：优化前 → 后 |
|---|---:|---:|
| `u_phrase` | 181 → 95 | 258 → 125 |
| `u_stable` | 253 → 235 | 110 → 110 |
| `u_transport` | 218 → 154 | 234 → 164 |

**这里的 Slice 是综合估算，不能当作最终物理占用。** 本项目此前同一套无语音源文件，综合估算为 22659 Slice，布局后为 19796 Slice，因此不能仅凭综合估算超过 21216 就判断放不下。本次尚未布局，能否容纳以及最终 setup/hold 均由本次新布局报告确认。

原始报告和快照：

- 优化前：`C:/Users/1/AppData/Local/Temp/anlogic_image_quality_66584441b7cc43ffbd072472b0447e45/`，指纹 `src-dc78d1482040`。
- 优化后：`C:/Users/1/AppData/Local/Temp/anlogic_image_quality_aae186227b2f4840b77b7f7ffd57dfc5/`，指纹 `src-f9909bc45e99`。
- 工作区报告副本：`build/voice_resource_fix_20261030/baseline_reports/` 和 `optimized_reports/`。

## 回归与复现

```powershell
python -B verification/run_scale_voice_tests.py --modelsim C:/altera/14.1/modelsim_ase/win32aloem
python -B verification/check_merge_readiness.py
python -B verification/test_voice_project_sources.py
powershell -NoProfile -ExecutionPolicy Bypass -File verification/run_image_quality_build.ps1 -TdBin D:/TD/bin -SkipRoute
```

本轮回归通过：

- 原五类计价、105 组音频组合、稳定/漂移/去重、陈旧数据、忙时等待、播报状态与超时。
- 实际计价模块与生产语音适配层联动：SW2、故障、计算间隙、精确零空秤、陈旧有效信号。
- 新增 1/14/24 位音频组合边界与随机测试，完整输出字节核对、自定义 255/254/253 录音编号。
- 新增独立串口线回归：默认 0/1/25 字节、8 位高位数据、非法长度和空组合、单播地址/校验/非法状态；生产 5 位 14 字节和音量 30。
- 主工程和视频工程均有五个启用语音模块；原有 13 个图像核心模块与 `origin/main` 一致。

本次检查没有替代上板验收。布局后检查新报告的最终 setup/hold slack，再使用该版本 bit 验证实际语音模块和 TF 卡播放。
