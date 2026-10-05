# K1 彩色与边缘模式切换

更新日期：2026-10-05。

基础摄像头、边缘检测、OSD 和板载 **K1** 切换已由用户确认能运行。本次替换为 Scharr 边缘，需重新编译、生成新 bit 并下载后才生效。

## 怎么用

1. 在 TD 打开 `td_project/anlogic_edge_osd.al`，使用当前保存的源码重新综合。
2. 综合完成后继续布局布线，检查最终时序，通过后生成并下载新版 bit。
3. 上电默认显示彩色图。按一下 **K1** 切换到边缘，再按一下切回彩色。
4. 按下和松开均需稳定至少 20 ms；正常按一下即可。长按只切换一次。

`td_project/anlogic_sc520_capture.al` 也支持同样的操作，两个工程现在均上电默认彩色，并保留原来的 Logo、文字和计数叠加。切换不需要重新配置摄像头或复位 DDR。

## Read Design 报错的处理

本节记录 2026-10-02 旧灰度边缘版本的工程文件修复。下面的旧综合记录不代表当前 Scharr 版本已经完成综合或时序签核；当前版本需从保存的 TD 工程重新构建。两份当前工程已登记 Scharr，本次未运行本节的旧修复脚本。

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
- `user_source/hdl_source/isp/rgb_edge_switch_96.v`：将请求同步到视频时钟域，仅在输入帧首锁存当前模式；Scharr 边缘模块持续运行，彩色数据、选择模式和帧/行/有效标记统一延迟 **11 拍**，对齐两种通路。
- `user_source/hdl_source/isp/scharr_edge_detect_96.v`：四像素独立计算亮度、高斯、Scharr、四方向 NMS 和固定单阈值；窗口使用显式 ERAM。
- `user_source/hdl_source/isp/isp_top.v`：将选择结果送给原来的 96/128 位打包模块。
- `user_source/constraints_source/pin.adc`：K1 / D5 输入约束。两个顶层 SDC 将异步机械按键输入路径排除出同步时序分析，后续同步器和消抖逻辑仍需正常满足时序。

`ENABLE_EDGE` 现在只表示复位默认值：1 为边缘，0 为彩色；当前主工程默认值为 0，不再用于综合时删除边缘模块。

当前 Scharr 是固定单阈值第一版，没有自适应、色度边缘或 Canny 追踪。
单阈值 20 对应 `abs(Gx)+abs(Gy)>=320`，不要照搬旧算法参数。
轮廓相对原图向右、向下各移 3 像素，目标框已同步补偿。
红色检测独立读取 AWB 彩色数据，在两种显示模式中叠加目标框与坐标。

当前 AWB 可能在有效像素之前给出帧首脉冲，因此模式更新不能要求 `tuser` 与 `tvalid` 同时为 1。请求恰好到达帧首、尚未通过同步器时，会推迟到后续帧生效。新画面还需要经过已有 DDR 缓冲，按键响应不是零延迟。

## 已完成的仿真

双击 `sim/run_video_mode.cmd` 运行当前 Scharr 的 64×48 测试。它先运行按键测试，
再运行 `tb_scharr_edge_detect_96.sv` 的独立图像参考，同时核对边缘模块和选择器。
720p 命令保持不变：

```bat
sim\run_video_mode.cmd --no-pause 720
```

XSim 通过小尺寸 17 帧（含截断帧）、49,344 像素，720p 11 帧、10,137,600 像素。
覆盖暗灰度边界、两种斜边、奇偶位置的一像素线、等亮度颜色、均匀图、噪声、
RGB/边缘切换、提前帧首、连续帧、空拍、复位与 11 拍对齐。
成功标志为 `VIDEO_MODE_BUTTON_TEST_PASS`、`SCHARR_EDGE_TEST_PASS`，
`result.txt` 为 `PASS`。所有产物写入打印出的 `%TEMP%\anlogic_video_mode_<随机编号>/`。
720p 暗灰度竖边/横边分别为 714/1274 像素，两种相位细线均为 1428 像素；
等亮度颜色与四级灰度扰动均为零。这些是合成图功能结果，不证明真实暗光画质。

按键测试将消抖参数缩短为 8 个时钟周期以加速仿真；实际顶层使用 1,000,000 个 50 MHz 周期，即 20 ms。2026-10-02 的历史检查覆盖当时两个真实 TD 工程的源码展开、引脚约束合法性检查和顶层 SDC 读取。

2026-10-02 历史记录：旧灰度 Sobel 与一拍选择器在 64×24 和 1280×720 下各测试两种默认模式、每种 7 帧，通过实际 `data_96bit_to_128bit` 核对像素字节序。旧成功标志为 `RGB_EDGE_SWITCH_TEST_PASS`；`tb_rgb_edge_switch.sv` 保留为历史参考，当前入口不再执行它。

2026-10-02 历史综合记录：使用 TD 6.2.168116 对旧版本主工程跑完 Read Design、RTL 优化及门级优化，日志为 `verification/video_mode_synthesis.log`，记录与源码 SHA-256 见 `verification/video_mode_check.txt`。这些报告针对旧算法，不能证明当前新算法通过。

当前入口覆盖按键、Scharr 边缘和选择模块，不覆盖打包模块、真实摄像头、完整 ISP、DDR/HDMI 联合仿真或板上画面。原打包模块不支持任意位置的空拍，当前入口的算法空拍测试不能用于改变打包接口的既有协议。综合通过也不等于布局布线后的时序通过。

## 上板验收

- 逐次按 K1，确认彩色与边缘交替显示，Logo/文字继续显示。
- 长按 K1，确认只切换一次；松开后再按才能再次切换。
- 视频运动过程中反复切换，观察是否有花屏、卡死或半帧混合。
- 复位后检查默认模式；检查模式切换不会改变摄像头增益。

本轮 Scharr 的资源与时序结果见 README；旧彩色边缘报告不能证明本版通过。
本次没有生成或下载新版 bit。摄像头实物画质仍需使用重新构建的版本确认。
