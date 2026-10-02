# 安路 PH1P35 边缘检测 + OSD 合并工程

## 当前版本：SC520CS（2026-10-02）

已按新提供的 SC520CS Lab2 例程更新摄像头配置、曝光/增益、启动时序、MIPI 参数和时序约束，保留原合并工程的 DDR、HDMI 和 OSD。

**直接使用主工程 `td_project/anlogic_edge_osd.al`**：彩色图像经过 ISP、DDR 和 OSD 后由开发板 HDMI 输出。已与提供的 SC520CS Lab1 彩色例程核对，当前生效的摄像头配置、曝光/增益、RAW10 解包、去马赛克、AWB 和打包逻辑与其一致；本次实际源码改动是将主工程复位默认模式设为彩色，继续使用已有 K1 切换。
`td_project/anlogic_edge_osd.al` 顶层仍为 `design_top_wrapper`，现在上电默认输出彩色图像加 OSD；按 **板载 K1** 可切换到边缘检测，再按一次切回彩色。彩色入口仍保留，两个工程共用同一条 SC520 彩色 ISP 链路。首次使用新默认模式需要重新编译下载；之后按 K1 即可切换。接法、测试和验证范围见 [彩色/边缘切换说明](VIDEO_MODE_SWITCH.md)。

TD 用于编译工程；视频显示在 HDMI 接收设备上。用户已确认基础版本的摄像头实时画面、边缘检测和 OSD 能正常显示。新增 K1 切换功能已完成独立仿真，尚需重新编译后的最终时序检查和上板验证；旧 bit 不包含新功能。此前 SC520CS 适配与验证记录见下文及 SC520CS_TEST.md。

工程入口、修改清单及接线待确认事项见 [SC520CS 使用说明](SC520CS_TEST.md)。原资料包含不同板卡版本，尚不能据此确认实物排线兼容；接线前应核实板卡与模块的配套排线/转接关系。

## 第一次看代码，从这里开始

这个工程实现的是“摄像头采集 → 图像处理 → DDR 帧缓存 → 文字/Logo 叠加 → HDMI 显示”。文件多，是因为同时包含算法、硬件接口以及 IP 配套文件。

先按下面顺序打开 5 个文件。详细的模块作用、数据流、参数修改位置、同名文件区别和 TD 登记文件索引，见 **[代码与配置导航](CODE_MAP.md)**。

| 顺序 | 文件 | 先看什么 |
|---|---|---|
| 1 | [design_top_wrapper.v](user_source/hdl_source/design_top_wrapper.v) | 系统顶层：摄像头、ISP、DDR、HDMI 怎么连接 |
| 2 | [isp_top.v](user_source/hdl_source/isp/isp_top.v) | 图像处理流水线：彩色重建、白平衡、边缘检测、数据打包 |
| 3 | [edge_detect_96.v](user_source/hdl_source/isp/edge_detect_96.v) | 边缘算法：灰度、相邻像素平均、Sobel、阈值判断 |
| 4 | [hdmi_mixer.v](user_source/hdl_source/hdmi_mixer.v) | 在图像上加 Logo、文字和帧计数；设置显示位置与调试画面 |
| 5 | [tb_edge_detect.sv](sim/tb_edge_detect.sv) | 不接板子时如何送入测试图像、检查算法输出 |

注意：当前边缘阈值由 **isp_top.v 中的 `.EDGE_TH(11'd80)`** 设置。只修改 edge_detect_96.v 中的默认值，会被这个实例参数覆盖。仿真测试台还独立设置了 THRESHOLD。

### 各目录用来做什么

| 目录或文件 | 用途 |
|---|---|
| [td_project/](td_project/) | TD 工程入口 `.al` 和当前顶层时序约束 `.sdc` |
| [user_source/hdl_source/](user_source/hdl_source/) | HDL 源码，既有算法，也有摄像头、DDR、HDMI 接口与配套 IP |
| [user_source/hdl_source/isp/](user_source/hdl_source/isp/) | 图像处理模块；注意当前使用的 AWB 源文件在上一层 |
| [user_source/ip_source/](user_source/ip_source/) | PLL、FIFO、RAM、除法器的 IP 配置与生成源码 |
| [user_source/constraints_source/](user_source/constraints_source/) | 板卡引脚等约束；当前使用 pin.adc |
| [sim/](sim/) | 仿真测试台和启动脚本；运行方法见 [仿真说明](sim/README.md) |
| [verification/](verification/) | TD 检查脚本和历史验证记录；生成日志及报告留在本地 |
| [.gitignore](.gitignore) | 上传时过滤运行缓存和输出文件 |
| [GITHUB_WORKFLOW.md](GITHUB_WORKFLOW.md) | 首次上传、后续更新、导出干净 ZIP 的操作步骤 |

源码里保留了同名模块的其他版本。以 `.al` 的文件路径和 TD 展开的模块层次为准；不要把整个 hdl_source 目录重复添加到工程。具体容易混淆的路径见 [代码导航](CODE_MAP.md)。

## Vivado 图形界面仿真入口

在 Vivado 中打开 [sim/vivado/edge_gui.xpr](sim/vivado/edge_gui.xpr)，点击 **Run Simulation → Run Behavioral Simulation**，即可运行边缘模块测试并查看预设波形。无需手工运行脚本。操作步骤和图片结果位置见 [GUI 仿真说明](sim/VIVADO_GUI.md)。

## TD 打开入口

在 TD 中选择 File → Open Project，打开：

    td_project/anlogic_edge_osd.al

目标器件：PH1P35MDG324，速度等级 -3。顶层：design_top_wrapper。
原工程及本次检查使用 TD 6.2.168116。

## 合并内容

以 Lab2（lab_ex2_edge）为基础，保留原有摄像头、RAW10 解包、ISP、边缘检测、DDR 和 HDMI 通路。
使用 Lab3 的 hdmi_mixer.v 替换显示混合模块，并加入 anlogic_logo_rom.v、osd_char_lib.v。
当前输出通路：SC520CS → ISP → 彩色/边缘帧边界选择 → DDR → 安路 Logo / 字符 / 帧计数叠加 → HDMI。边缘模块持续运行；彩色通路增加一拍延迟与其对齐。
分辨率保持 1280×720；顶层 DEBUG_MODE 保持 0。

已复制全部 user_source，工程文件引用均指向本文件夹内的文件。
新工程名称为 anlogic_edge_osd；原来的两个例程未修改。
未复制原工程的历史运行目录、旧下载文件和旧编译成功标记。
综合使用默认生成脚本，便于 TD 按当前工程源文件清单重新编译。

## 打开后操作

1. 打开 td_project/anlogic_edge_osd.al，不需要重新创建工程或手工添加文件。
2. 检查目标器件和顶层名称，然后运行 Synthesis。
3. 再运行布局布线，查看资源和时序报告；通过后生成下载文件。
4. 没有开发板也可以编译；下载和摄像头、HDMI 实物验证需要 HX1P35A。

不要把整个源码文件夹中的所有 .v 再加入工程：其中有历史版本和同名模块。
特别是 data_96bit_to_128bit 模块已经由 isp/data96_128/data96_128.v 提供，不能再添加根目录的同名模块文件。
有效引脚约束为 user_source/constraints_source/pin.adc；有效顶层时序约束为 td_project/anlogic_edge_osd.sdc。

## 验证记录

verification/source_check.txt：文件引用、合并文件一致性和重复模块检查。
verification/check_td.tcl：使用实际 .al 工程做 TD 源码解析和层次展开。
verification/synth_td.tcl：TD 综合资源检查脚本。
verification/synthesis_console.log：本次综合完整输出，以末尾 PASS/FAIL 标志及资源报告为准。

目前合并保留了原例程的算法和时序行为，不代表完成了功能仿真或实物验证。
原例程中的未连接输入、位宽等告警需要结合后续仿真和上板调试审查。
OSD 中的运行计数按显示帧递增，不是秒计时。
## 初次 TD 命令行综合记录（2026-09-23，旧 SC500CS 版本）

- 工程打开、源码分析和层次展开：通过。
- RTL 优化、门级综合、物理实例合法化：完成，synthesis_console.log 末尾为 MERGED_PROJECT_SYNTHESIS_PASS。
- 综合阶段资源：Slice 13510/21216（63.68%），ERAM 40/108（37.04%），DSP 9/40（22.50%），寄存器 13768/42432（32.45%）。均未超出报告容量；最终用量以布局布线为准。
- 综合时序估计：Setup WNS = -1.477 ns，Hold WNS = 0.114 ns，STA coverage = 95.32%。综合完成不等于时序通过。请继续布局布线，检查最终时序以及未约束路径。
- 原 PLL 配置保持不变。综合报告显示 HDMI 像素时钟约 75.002 MHz；不是重新生成的标准 74.25 MHz 配置。
- 此处记录的是初次命令行综合检查，当时未执行布局布线、下载文件生成、功能仿真或实物验证；后续独立边缘模块仿真见下一节。
- 完整资源报告：verification/merged_gate.area；综合时序报告：verification/merged_gate.timing。

本次检查还报告了原边缘模块 RAM_STYLE 设置未按预期采用、部分原例程信号未连接和位宽等告警。保留日志供后续审查，未为消除告警改写原算法。
## 新增：边缘模块无板仿真（2026-09-23）

已添加 sim 文件夹，不影响 TD 综合工程和算法源码。
双击 sim/run_xsim.cmd 可运行 320×180 测试；双击 sim/run_720p.cmd 可运行 1280×720 测试。
两种尺寸都已在本机 XSim 2021.1 通过，每种 5 帧逐像素比较。
双击 sim/open_wave.cmd 查看小尺寸波形；在 sim/out 或 sim/out_720p 打开 BMP 查看图像。
使用说明见 sim/README.md，验证范围见 sim/validation.txt。仅验证独立边缘模块，整机功能尚未验证。
