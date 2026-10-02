# K1 彩色与边缘模式切换

更新日期：2026-10-02。

基础摄像头、边缘检测和 OSD 已由用户确认能正常显示。本次增加板载 **K1** 切换，需重新编译、生成新 bit 并下载后才生效。

## 怎么用

1. 在 TD 打开 `td_project/anlogic_edge_osd.al`。如果仍在使用旧工程窗口，按下面的“一行修复命令”更新当前工程并启动综合。
2. 综合完成后继续布局布线，检查最终时序，通过后生成并下载新版 bit。
3. 上电默认显示边缘图。按一下 **K1** 切换到彩色，再按一下切回边缘。
4. 按下和松开均需稳定至少 20 ms；正常按一下即可。长按只切换一次。

`td_project/anlogic_sc520_capture.al` 也支持同样的操作，只是上电默认彩色。两个工程都保留原来的 Logo、文字和计数叠加。切换不需要重新配置摄像头或复位 DDR。

## Read Design 报错的处理

2026-10-02 21:58 和 22:14 的 GUI 运行均因缺失 `video_mode_control.v`、`rgb_edge_switch_96.v` 的文件注册而报黑盒错误。22:14 的实际 `.prj` 仍使用旧列表。另有 `edge_detect_96.v` 的过时 `AutoExcluded` 标记，因此只添加两个新文件仍不足以恢复完整编译。此前独立脚本综合通过，不能证明已打开的 GUI 工程也已更新。

### 一行修复命令

关闭失败弹框，选 TD 下方的 **Tcl Console**，粘贴并回车：

```tcl
source D:/vivado_work/anlogic_edge_osd/verification/fix_video_mode_in_td.tcl
```

脚本会先关闭当前主工程，让旧状态的保存发生在修复之前；然后备份工程配置，补齐两个源文件注册，清除边缘模块的排除标记，启用默认综合脚本；最后重新打开修复后的工程并自动启动 `syn_1`。不需要再手动添加文件或反复关闭重开。执行前应保存自行编辑但尚未保存的 HDL 文件，并确认没有正在运行的综合/布局布线任务。

`VIDEO_MODE_GUI_SYNTHESIS_STARTED` 只表示任务已启动，最终结果看 `syn_1` 的 Optimize Gate 完成状态。真实运行目录是 `td_project/anlogic_edge_osd_Runs/syn_1/`，检查其中的 `run.log`、`.opt_gate.end.f` 和新生成的门级报告，不能仅凭任务启动器返回 success 判断通过。

已通过该修复脚本启动真实 `syn_1`：2026-10-02 22:34:08 开始，22:38:37 完成 Optimize Gate；三个综合阶段的完成标志、新门级数据库和实际日志均已核对。成功日志另存于 `verification/video_mode_gui_syn1_pass.log`。这不代表另一个已经打开的 TD 窗口自动更新了内存状态，该窗口仍需执行上面的命令。

独立综合检查命令（在项目根目录的 PowerShell 执行，Tcl 脚本路径使用 `/`）：

```powershell
& 'D:/TD/bin/td_commands_prompt.exe' 'verification/synth_video_mode.tcl'
```

该独立脚本读取主工程，运行 Read Design、RTL 优化和门级优化。成功标志为 `VIDEO_MODE_SYNTHESIS_PASS`；报告为 `verification/video_mode_rtl.area`、`verification/video_mode_gate.area` 和 `verification/video_mode_gate.timing`。它不更新已打开的 TD 窗口状态，不能代替上面的一行修复命令，也不运行布局布线或生成 bit。

## 按键名称与实际引脚

依据资料包《新HX1P35A开发板手册-HDL版2604.pdf》第 22–23 页：

| 板上按键 | FPGA 引脚 | 本次功能 |
|---|---|---|
| K1 / KEY1 | D5 | 彩色/边缘切换 |
| K2 / KEY2 | A9 | 本次未分配功能 |
| K3 / KEY3 | B9 | 本次未分配功能 |
| K4 / KEY4 | C7 | 本次未分配功能 |

新增顶层输入 `I_mode_key_n` 单独约束到 D5。原例程 `I_button[0]`=N2、`I_button[1]`=J14 是 GPIO 扩展口控制信号，不是板载 K1/K2；这两个原连接及其增益调节用途保持不变。不要为了切换而短接扩展口。

## 实现位置

- `user_source/hdl_source/video_mode_control.v`：在 50 MHz 板载时钟下进行两级输入同步、20 ms 按下/释放消抖，保存切换请求。
- `user_source/hdl_source/isp/rgb_edge_switch_96.v`：将请求同步到视频时钟域，仅在输入帧首锁存当前模式；边缘模块持续运行，彩色数据延迟一拍，对齐两种通路的像素和控制信号。
- `user_source/hdl_source/isp/isp_top.v`：将选择结果送给原来的 96/128 位打包模块。
- `user_source/constraints_source/pin.adc`：K1 / D5 输入约束。两个顶层 SDC 将异步机械按键输入路径排除出同步时序分析，后续同步器和消抖逻辑仍需正常满足时序。

`ENABLE_EDGE` 现在只表示复位默认值：1 为边缘，0 为彩色；不再用于综合时删除边缘模块。

当前 AWB 可能在有效像素之前给出帧首脉冲，因此模式更新不能要求 `tuser` 与 `tvalid` 同时为 1。请求恰好到达帧首、尚未通过同步器时，会推迟到后续帧生效。新画面还需要经过已有 DDR 缓冲，按键响应不是零延迟。

## 已完成的仿真

双击 `sim/run_video_mode.cmd` 运行小尺寸测试。720p 测试命令：

```bat
sim\run_video_mode.cmd --no-pause 720
```

使用 XSim 2021.1，64×24 和 1280×720 均测试两种复位默认模式，每种各 7 帧。720p 合计逐像素比较 12,902,400 个像素，并通过实际 `data_96bit_to_128bit` 模块核对 38,707,200 字节。

覆盖：按键抖动、释放抖动、长按不连发、复位恢复；帧中请求、请求恰好到达帧首、一帧内两次请求；帧首与有效像素同时/提前出现；合法打包边界的空拍；两种模式的图像、帧/行标记、固定延迟和打包字节序。

成功标志：`VIDEO_MODE_BUTTON_TEST_PASS`、`RGB_EDGE_SWITCH_TEST_PASS`，输出目录中的 `result.txt` 为 `PASS`。日志在 `sim/out_video_mode/` 和 `sim/out_video_mode_720p/`。

按键测试将消抖参数缩短为 8 个时钟周期以加速仿真；实际顶层使用 1,000,000 个 50 MHz 周期，即 20 ms。两个真实 TD 工程均已完成源码展开、引脚约束合法性检查和顶层 SDC 读取。

修复主工程源文件列表后，已用 TD 6.2.168116 对 `anlogic_edge_osd.al` 跑完 Read Design、RTL 优化及门级优化，实际综合通过；日志为 `verification/video_mode_synthesis.log`。门级资源报告包含按键控制和图像切换两个模块。此次修复没有修改此前通过仿真的 RTL。验证记录与源码 SHA-256 见 `verification/video_mode_check.txt`。综合通过不等于布局布线后的时序通过。

这些测试覆盖新增控制/选择模块、原边缘模块和实际打包模块，不包括真实摄像头、完整 ISP、DDR/HDMI 联合仿真或板上画面。原打包模块不支持任意位置的空拍，本次没有改变其协议。

## 上板验收

- 逐次按 K1，确认彩色与边缘交替显示，Logo/文字继续显示。
- 长按 K1，确认只切换一次；松开后再按才能再次切换。
- 视频运动过程中反复切换，观察是否有花屏、卡死或半帧混合。
- 复位后检查默认模式；检查模式切换不会改变摄像头增益。

本次未下载硬件、未生成新版 bit，也未重新做布局布线时序签核。旧构建报告曾存在建立时间违例，不能用旧 bit 或旧报告证明新增版本已经通过硬件或时序验证。
