# 安路 PH1P35 边缘检测 + OSD 合并工程

## 当前试验版：彩色边缘与红色目标同时显示

打开现有 `td_project/anlogic_edge_osd.al`，重新综合、布局布线并生成 bit，
再使用原来的下载流程。K1 仍在两种画面之间切换：

- 彩色模式：摄像头彩色画面 + 红色目标框 + 黄色中心十字及坐标。
- 边缘模式：黑底白色轮廓 + 同一个红色目标的框、中心十字及坐标。

红色检测改在 **AWB 后、彩色/边缘选择之前** 并行运行，所以两种模式都使用
原始彩色信息判定红色。框和坐标按 DDR 实际写槽保存、按实际读槽选择，避免把
最新采集帧的坐标画在较早的显示帧上。重用槽会先清除旧结果；截断帧不会沿用
四帧前的框。坐标仍为**包围框中心**，并非目标质心。

新边缘模块保留亮度与 `R-G`、`B-G` 色度差，采用相邻像素平均、有符号彩色梯度、
四方向非极大值抑制、双阈值和一次 3×3 邻域强边缘连接。它是论文第二套思路的
**流式硬件简化版**：没有实现非线性 Lab 转换、迭代矢量全变分去噪或全帧递归
滞后追踪。官方 `edge_detect_96.v` 留作对照，已不在当前运行通路中。

每拍输入四个 RGB888 像素；边缘模块把相邻两像素平均为一个样本、结果复制为两
像素，水平细节因此只有半分辨率。RGB/边缘/帧首/行末/模式统一延迟 11 拍。
三个因果窗口使轮廓向右移 6 像素、向下移 3 行，边缘帧的框同步平移并在图像
边界夹紧；完整邻域不足的前 12 像素、前 6 行不输出边缘。

红色判断保留 `R>=80`、`R>=G+30`、`R>=B+30`，以及 3×3 多数判决
（至少五个命中）、最小 128 像素、宽高至少 8 像素筛选。阈值设置入口现在为
`isp_top.v` 的检测实例；边缘高阈值为 20、低阈值为 10。
彩色梯度幅值在比较前除以 4，所以对于纯亮度的水平或垂直梯度，高阈值 20
近似对应旧灰度 Sobel 的 80；斜向及色度边界不保证与旧算法有相同响应。
多个红色区域仍会合为一个总包围框，尚未加入连通域分离。
旧 `SHOW_RED_MASK` 参数保留接口兼容，目前不提供逐像素红色掩膜显示。

本次主要源码：

| 文件 | 本次作用 |
|---|---|
| [color_edge_detect_96.v](user_source/hdl_source/isp/color_edge_detect_96.v) | 新彩色边缘流水线及其行窗口 |
| [red_target_detect_96.v](user_source/hdl_source/isp/red_target_detect_96.v) | 四像素并行红色判定、去噪、每帧框统计 |
| [rgb_edge_switch_96.v](user_source/hdl_source/isp/rgb_edge_switch_96.v) / [isp_top.v](user_source/hdl_source/isp/isp_top.v) | 替换边缘模块、对齐两条视频通路、接出检测结果 |
| [design_top_wrapper.v](user_source/hdl_source/design_top_wrapper.v) | 坐标跨时钟握手、四槽结果表、边缘位置补偿 |
| [hdmi_mixer.v](user_source/hdl_source/hdmi_mixer.v) | 接收前端结果并复用框、十字、坐标 OSD；提前寄存 Logo 地址以缩短显示路径 |
| [video_in.v](user_source/hdl_source/video_in.v) / [video_out.v](user_source/hdl_source/video_out.v) | 仅增加实际写/读槽的状态输出，原 DDR 控制逻辑不变 |

两份 `.al` 已登记新算法源文件。摄像头初始化、曝光、白平衡算法、引脚、时钟、
下载配置及 K1 接法保持原设置。完整导航见 [CODE_MAP.md](CODE_MAP.md)。
本版上板验证重点：普通室内光下移动红色卡片，切换后目标框应保留，
其它非红色物品也应显示白色轮廓；移走红色卡片后对应显示帧应清框。

当前 20/10 阈值已通过 XSim 独立图像参考检查：彩色边缘 64×48 十三帧、
39,936 个像素及 720p 七帧、6,451,200 个像素，覆盖低对比度灰度边界、
等亮度色度边界及小扰动抑制；同一输入下，80/40 对照实例会漏掉这些弱边缘。
此前 ModelSim 验证了红色检测两种尺寸各九帧；720p 显示叠加检查八帧、
7,372,800 个输出像素，
覆盖黑白画面保留目标框、原 Logo/文字优先级和十进制坐标。
帧对应测试通过 30 次读写与显示，覆盖多槽回绕、无目标清框、截断帧、
异步时钟和边缘位置补偿；该测试使用受控 ISP 结果，不替代真实 MIPI/DDR 数据验证。
仿真源文件见 `sim/tb_color_edge_detect_96.sv`、`sim/tb_red_target_detect_96.sv`、
`sim/tb_target_frame_alignment.sv`、`sim/tb_color_target_mixer.sv`。
检查日志、脚本和中间产物放在系统 TEMP，不参加上板综合。
最终布局布线时序和摄像头实物效果仍需生成新版 bit 后验证。

阈值校准前的 80/40 版本已完成 TD 的展开、RTL 优化、门级综合、合法化和综合时序检查。
门级资源估计为 Slice 18,182/21,216（85.70%）、ERAM 40/108、DSP 9/40。
新边缘行缓存实际映射为分布式 RAM，尚未映射为 ERAM；六条 RAM 推断警告
说明了这一回退，不能将源码里的 `ram_style="bram"` 当作已经使用 ERAM。
摄像头时钟域最差建立时间余量为 +1.743 ns，没有建立时间违例；
全工程最差余量仍为 -0.580 ns，位于 HDMI 显示叠加路径，因此**综合完成不代表
时序通过**，应继续检查布局布线后的最终报告。Logo 地址提前寄存的改动另通过了
7,447,901 拍修改前后对照，HDMI 数据、同步和 OSD 行为完全一致。
上述 TD 报告属于 80/40 版本；当前 20/10 版本只重跑了功能仿真，
尚未重跑 TD 综合、布局布线或生成 bit。本次没有下载新版 bit。

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
| 3 | [color_edge_detect_96.v](user_source/hdl_source/isp/color_edge_detect_96.v) | 新边缘算法：保留色度的梯度、非极大值抑制、双阈值和连接 |
| 4 | [hdmi_mixer.v](user_source/hdl_source/hdmi_mixer.v) | 在图像上加 Logo、文字和帧计数；设置显示位置与调试画面 |
| 5 | [tb_color_edge_detect_96.sv](sim/tb_color_edge_detect_96.sv) | 新彩色边缘和切换器的独立图像参考、像素与时序检查 |

注意：当前边缘高阈值由 **isp_top.v 中的 `.EDGE_TH(11'd20)`** 设置，低阈值默认一半，即 10。官方 edge_detect_96.v 不在当前运行通路，修改它不会改变新算法。当前测试台分别为 DUT 和独立参考设置高/低阈值 20/10，不会自动读取系统实例的参数；另有 80/40 对照实例，用于复现未按幅值缩放调整阈值时的弱边缘丢失。

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

在 Vivado 中打开 [sim/vivado/edge_gui.xpr](sim/vivado/edge_gui.xpr)，点击 **Run Simulation → Run Behavioral Simulation**，可运行保留的官方灰度边缘对照测试并查看预设波形。该旧 GUI 工程不验证当前彩色边缘版本；新版本入口为 `sim/run_video_mode.cmd`。操作步骤和图片结果位置见 [GUI 仿真说明](sim/VIVADO_GUI.md)。

## TD 打开入口

在 TD 中选择 File → Open Project，打开：

    td_project/anlogic_edge_osd.al

目标器件：PH1P35MDG324，速度等级 -3。顶层：design_top_wrapper。
原工程及本次检查使用 TD 6.2.168116。

## 合并内容

以 Lab2（lab_ex2_edge）为基础，保留原有摄像头、RAW10 解包、ISP、边缘检测、DDR 和 HDMI 通路。
使用 Lab3 的 hdmi_mixer.v 替换显示混合模块，并加入 anlogic_logo_rom.v、osd_char_lib.v。
当前输出通路：SC520CS → ISP → 彩色/边缘帧边界选择 → DDR → 安路 Logo / 字符 / 帧计数叠加 → HDMI。边缘模块持续运行；两条视频通路延迟统一为 11 拍，红色检测独立取 AWB 彩色数据。
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

最初合并阶段保留了原例程的算法和时序行为；当前试验版已替换边缘模块，验证范围见本文开头，实物效果仍需新版 bit 上板确认。
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
