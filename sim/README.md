# 无板仿真：先验证边缘检测模块

当前入口：双击 `run_video_mode.cmd`；720p 运行 `run_video_mode.cmd --no-pause 720`。
使用 XSim 2021.1，先验证按键，再运行 `tb_scharr_edge_detect_96.sv`。
独立参考在图像域计算灰度、高斯、Scharr 和 NMS，再补偿 (3,3) 坐标；
逐像素核对 DUT 与 RGB 选择器、帧行标记、11 拍延迟和帧首模式切换。
默认 `TH=20`，DUT 与参考均比较原始幅值是否达到 320。没有自适应或 Canny 追踪。

本轮通过：64×48，17 帧（含一次三行截断帧），49,344 像素；
720p，11 帧，10,137,600 像素。场景包括暗灰度边界、正反斜边、
奇偶一像素细线、红色物体、随机噪声、均匀图、等亮度颜色、小灰度扰动。
等亮度颜色边界应为零；红色识别来自独立 RGB 检测器，不是亮度边缘的能力。
小尺寸另外覆盖保留旧 RAM 内容的复位、截断帧和高斯旁路。
ModelSim 使用厂商 ERAM 模型也通过了上述 64×48、720p 和 64×49 高斯旁路测试，
无错误、无警告；64×49 还覆盖奇数行高帧的缓存奇偶行切换。
高斯旁路仅覆盖直接边缘实例，RGB 选择器仍运行默认高斯版本；
ModelSim 覆盖参数应写为 `-g/tb_scharr_edge_detect_96/GAUSSIAN_ENABLE=0`。

成功标志为 `VIDEO_MODE_BUTTON_TEST_PASS`、`SCHARR_EDGE_TEST_PASS`，
结果目录的 `result.txt` 应为 `PASS`。日志、中间文件只写入打印出的 TEMP 目录。
入口用 `SCHARR_PORTABLE_RAM` 行为 RAM 和移位寄存器；厂商模型检查需额外编译
`D:/TD/sim_release/ph1p/ph1p_logic_eram.v`、`ph1p_phy_gsr.v`，
不定义便携宏，并将 `PH1P_PHY_GSR` 与测试台一起作为仿真顶层。
生产工程不定义该宏，行窗口和彩色延迟直接使用安路 ERAM。
资源与最终时序结论见工程 README。

## 目标框与 DDR 帧对齐

`tb_target_frame_alignment.sv` 运行真实系统顶层、`video_in`、`video_out` 和 `hdmi_mixer`，根据实际 DDR 写/读基址建立独立参考，检查四槽轮换、完整/无目标/截断帧、邮箱 ACK、复位、边缘模式坐标补偿及 mixer 的帧首锁存。新增 14 项检查核对摄像头 4 位状态和 8 位错误码经诊断 CDC 后到达实际 mixer 输入。测试台以 `force` 提供 ISP 结果、诊断源值、图像标志和异步时钟，因此不覆盖摄像头 I2C/ISP 算法内部、真实 DDR 传输或完整 720p 像素扫描。

在 PowerShell 运行以下命令；产物只写到系统临时目录，不需要安装厂商 IP 仿真库：

```powershell
$simRoot = 'D:/vivado_work/anlogic_edge_osd'
$simBin = 'D:/XILINX/Vivado/2021.1/bin'
$simWork = Join-Path $env:TEMP ('anlogic_target_alignment_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simWork | Out-Null
Push-Location $simWork
& "$simBin/xvlog.bat" -sv -d TARGET_ALIGNMENT_STUBS `
  "$simRoot/user_source/hdl_source/design_top_wrapper.v" `
  "$simRoot/user_source/hdl_source/camera_diag_cdc.v" `
  "$simRoot/user_source/hdl_source/video_in.v" `
  "$simRoot/user_source/hdl_source/video_out.v" `
  "$simRoot/user_source/hdl_source/hdmi_mixer.v" `
  "$simRoot/user_source/hdl_source/anlogic_logo_rom.v" `
  "$simRoot/user_source/hdl_source/osd_char_lib.v" `
  "$simRoot/sim/tb_target_frame_alignment.sv"
& "$simBin/xelab.bat" -timescale 1ns/1ps -debug all work.tb_target_frame_alignment -s target_frame_alignment
& "$simBin/xsim.bat" target_frame_alignment -runall
Pop-Location
Write-Output $simWork
```

每一步都应无 ERROR，最终成功标志为 `TARGET_FRAME_ALIGNMENT_PASS`。`TARGET_ALIGNMENT_STUBS` 只启用测试台末尾的空外围模块；只编译上面列出的文件，不可同时编译同名真实外围/IP 模块。空模块使用统一宽度的输入端口，宽度不匹配警告属于测试边界声明，不代表生产 RTL 接线。测试台没有加入 TD 工程。

## 摄像头诊断状态跨时钟

`tb_camera_diag_cdc.sv` 检查 12 位诊断快照的请求/确认握手，
覆盖所有 4096 种值、发送端更快、快速变化合并、两端时钟暂停和传输中复位。
独立队列记录每次发送值，逐次核对接收值，并检查数据在确认前保持稳定。
RTL 仿真不模拟亚稳态；同步级结构、约束匹配和实际路径延迟需结合 TD 报告检查。

使用上面的 `$simRoot`、`$simBin` 设置，在新的 TEMP 目录执行：

```powershell
$diagWork = Join-Path $env:TEMP ('anlogic_camera_diag_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $diagWork | Out-Null
Push-Location $diagWork
& "$simBin/xvlog.bat" -sv "$simRoot/user_source/hdl_source/camera_diag_cdc.v" "$simRoot/sim/tb_camera_diag_cdc.sv"
& "$simBin/xelab.bat" -timescale 1ns/1ps -debug typical work.tb_camera_diag_cdc -s camera_diag_cdc_sim
& "$simBin/xsim.bat" camera_diag_cdc_sim -runall
Pop-Location
```

成功标志为 `PASS tb_camera_diag_cdc`。测试台不加入 TD 工程。

旧 `tb_color_edge_detect_96.sv` 保留为历史参考，需匹配旧彩色边缘选择器，
不能直接与当前 Scharr 选择器混用；当前运行入口不编译该测试台。

以下章节是原官方灰度边缘模块的历史对照测试，不用于验证当前 Scharr 算法。

TD 中的 Read Design / Optimize / Generate Bitstream 是实现流程。功能仿真需要测试台（testbench）提供时钟、复位和输入像素，再由仿真器执行 RTL。

以下旧测试入口直接使用合并工程原有的 `user_source/hdl_source/isp/edge_detect_96.v`，没有把测试台加入 TD 的综合源文件列表。

## 推荐：直接在 Vivado 界面操作

用 Vivado **Open Project** 打开 [vivado/edge_gui.xpr](vivado/edge_gui.xpr)，点击 **Run Simulation → Run Behavioral Simulation**。工程已配置测试台、运行到结束和默认波形，不需要手工运行脚本。

详细的点击步骤、波形说明和结果图片位置见 **[Vivado 图形界面仿真](VIVADO_GUI.md)**。下面保留脚本方式，作为备选；两种方式引用同一份边缘源码和测试台。

## 脚本运行（备选）

1. 在资源管理器打开本目录，双击 `run_xsim.cmd`。
2. 程序依次编译、展开、运行；结束应显示 `PASS` 和 `ALL_TESTS_PASS`（后者在仿真日志中）。
3. 打开 `out/input.bmp` 查看输入图片，打开 `out/edge_output.bmp` 查看原 RTL 算出的边缘。
4. `out/edge_expected.bmp` 是独立的整帧参考算法结果；测试台已经逐像素比对，不需要靠肉眼判断。
5. 双击 `open_wave.cmd`，启动 Vivado 波形查看窗口并读取已保存的 `out/edge.wdb`。这里只使用 XSim / 波形查看功能，不是建立 Xilinx 板卡工程。

脚本默认使用本机已确认的 `D:\XILINX\Vivado\2021.1\bin`。换电脑后可修改两个启动脚本的 `SIM_BIN`，或设置环境变量 `VIVADO_SIM_BIN`。

小尺寸为 320×180，便于快速学习。双击 `run_720p.cmd` 则以 1280×720 参数运行同一套测试，结果单独保存在 `out_720p` 中。`open_wave.cmd` 默认查看小尺寸结果。

## 波形怎么看

| 信号 | 含义与检查方法 |
|---|---|
| clk | 本测试时钟周期 16 ns；这是行为仿真激励，不是时序收敛验证 |
| rst_n | 初始为 0，复位结束后为 1；第五帧前再复位一次 |
| in_valid | 为 1 时输入四个 RGB888 像素 |
| in_user | 一帧第一个有效像素组，与 in_valid 同时为 1 |
| in_last | 每行最后一个有效像素组；小尺寸每行 80 组，720p 每行 320 组 |
| in_data | 96 位；从高位到低位依次放四个 24 位 RGB 像素 |
| out_valid / out_user / out_last | 对应输入控制信号经过模块输出寄存器 |
| out_data | 原边缘 RTL 输出；每个像素只能是 000000 或 FFFFFF |
| frame_id | 0 到 4，标记正在运行哪一帧测试 |
| dut/x_grp、dut/y_pos | 边缘模块内部的像素组与行计数 |

使用 Wave 窗口的放大按钮，先看复位释放后几微秒；再查看行结束、帧切换附近。数据通常在时钟上升沿后更新，测试台在下降沿驱动输入，避开采样竞争。

## 检查了什么

- 第 0 帧：灰色背景、白色矩形和彩色矩形，导出 BMP。
- 第 1 帧：全白，输出应全黑，用于检查上一帧行缓存残留。
- 第 2 帧：全黑，输出应全黑。
- 第 3 帧：固定种子的随机彩色像素，插入 valid 空拍，检查算法在输入间歇时的状态。
- 第 4 帧：复位后输入条纹图，检查输出复位及行缓存重新填充。
- 每帧检查像素值、像素总数、帧首与行尾、输出寄存延迟；遇到 X/Z 或不一致立即失败。

参考模型按本 RTL 的行为计算：先用位移灰度化，再把相邻两像素平均，使用 3×3 Sobel 的 |Gx|+|Gy|，以 80 为阈值，最后复制每个结果到两个输出像素。首两行、每行前四像素置黑，窗口按当前输入位置结束。不能直接拿默认 OpenCV Sobel 输出当作逐像素真值。

## 验证边界

这次只验证独立的边缘检测模块，ready 固定为 1，帧首与第一个有效像素组对齐。未验证完整 ISP、AWB 到边缘模块的帧首时序、96/128 打包、OSD、DDR、MIPI 和 HDMI，也未验证随机反压。

特别注意：本测试给边缘模块插入 valid 空拍，不代表后面的原 96/128 打包模块也支持任意空拍。后者需要另外的接口测试。

后续建议顺序：边缘模块 → OSD 图像叠加 → 像素打包/拆包 → ISP 接口 → 帧缓存模型。整机仿真还需厂商 IP 仿真模型及摄像头/存储器激励。

## ModelSim / Questa 备选

如果已有 ModelSim / Questa，可在其 Transcript 输入：

```tcl
cd D:/vivado_work/anlogic_edge_osd/sim
do run_modelsim.do
```

结果在 `out_modelsim`。本模块不依赖安路原语，因此不需要先编译安路器件库；整机/IP 仿真不适用这一结论。本机实际验证使用 XSim，ModelSim 脚本仅提供备选，尚未运行验证。

## 出错时

查看对应输出目录里的 `compile_console.log`、`elaborate_console.log`、`simulate_console.log`，先处理第一条 ERROR/Fatal。`result.txt` 必须是 PASS 才算通过，生成波形或图片本身不代表通过。

不要把 `tb_edge_detect.sv` 加入 TD 的综合源文件。它有延时、文件读写和仿真结束语句，只供仿真器运行。
