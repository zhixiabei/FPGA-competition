# 无板仿真：先验证边缘检测模块

## 2026-10-10 真实视频 FIFO 与右侧接缝回归

```powershell
& 'D:/vivado_work/anlogic_edge_osd/sim/run_video_fifo_frame_integrity.ps1'
```

此入口使用 ModelSim 和 TD 厂商功能模型；所有日志、库、导出图像字和像素参考写入
打印出的 TEMP 目录。`tb_video_fifo_frame_integrity.sv` 内包含写入和读出两个测试顶层：

- 写入测试使用生产 AWB、厂商 DRAM/ERAM、彩色/Scharr 选择器、注册式 96→128 打包、
  `video_in`、实际 `w128_d512_fifo` 及其原 RAM 源码。输入为像素编号编码的 RGB，
  彩色逐像素先核对输入坐标；Scharr 输出在打包前另存像素参考，再逐字节比较 DDR 写入。
- 103.52 MHz 摄像头域、66.667 MHz DDR 域；四种 DDR 相位分别运行 1280×32 彩色和边缘帧，
  完整 1280×720 两帧导出实际 DDR 写入内容。每行 320 组连续有效、约 1725 个摄像头
  时钟周期，帧间空白允许延迟像素排空；DDR ready 有间歇停顿。
- 读出测试将上一步实际写入的 128 位字交给生产 `video_out` 及原 FIFO，
  以约 75.002 MHz 扫描，模拟 40 个 DDR 时钟的返回延迟与 240 字突发。
  彩色、边缘各核对 921,600 个像素，每幅逐行左右 16 像素额外计 23,040 次检查；
  双槽压力场景核对 1,843,200 个像素，检查空读、满写及突发长度。

成功必须同时出现写入 `FIFO_FRAME_INTEGRITY_PASS` 和读出 `FIFO_FRAME_READER_PASS`，
像素不一致、FIFO 溢出/空读、帧首复位与数据重叠均失败。
最终验证共比较写入 6,512,640 字节、读回 3,686,400 像素，其中逐行左右
边界 92,160 像素；像素错误、空读、满写及突发长度错误均为 0。
日志目录为 `anlogic_video_fifo_integrity_15e7940d43f441f3b8388847af74bd0f/`：
`console.log` 包含五个写入场景，`reader_exact_console.log` 包含修正为实际
1650 拍行周期后的三个读回场景。这次补跑只调整读回消隐计数，写入测试模块未变。
最终编译的测试台与当前源码哈希一致；入口脚本已采用相同读回时序。
本测试不模拟 MIPI/RAW 去马赛克、传感器 I²C、DDR 控制器/电气或 HDMI PHY。
Scharr 算法的独立图像域正确性仍由下方专用测试覆盖，这里检查它的输出经缓存后未错位。

修复前的 TEMP 负例使用原 `video_in`/FIFO，按真实打包器 3/4 节拍写入：
SOF 到第一写入仅 3 个摄像头时钟时，四种 DDR 相位的首个保留字均为源 word9，
即丢失 9×16 字节、48 个完整 RGB 像素；恢复原提前量 55 拍时首字均为 word0。
复现日志为 `anlogic_video_in_prefix_eaa693de995443009bf279eb3845a8b0/console_real_pattern.log`。
另从最终 AWB 副本只移除新增延迟，以工程登记的打包器和真实厂商 RAM/FIFO
重跑完整模块连接；四种相位的 DDR 首像素均为源像素 48、应为 0。
该反向验证为 `anlogic_video_fifo_unguarded_3844b9f46bdc4ccfaff37859536a3cdc/console.log`，
未改动生产文件。
修复在 AWB 增加 52 拍分布式 RAM 延迟，总像素延迟恢复 54 拍；
没有通过修改红色门限、裁剪侧边或框坐标来隐藏问题。

## 2026-10-10 光照适应回归

新增四个 PowerShell 入口均使用 XSim 2021.1，把日志、展开文件和波形写入打印出的
TEMP 目录，不加入 TD 综合工程：

```powershell
& 'D:/vivado_work/anlogic_edge_osd/sim/run_auto_exposure.ps1'
& 'D:/vivado_work/anlogic_edge_osd/sim/run_awb_frame_adaptation.ps1'
& 'D:/vivado_work/anlogic_edge_osd/sim/run_red_target_lighting.ps1'
& 'D:/vivado_work/anlogic_edge_osd/sim/run_isp_lighting_integration.ps1'
```

每个入口遇到编译、展开、运行失败或缺少成功标志都会报错；
日志可见不等于测试通过，需对应版本完成后的 PASS 标志。

| 入口 | 实际验证内容 | 成功标志 |
|---|---|---|
| `run_auto_exposure.ps1` | 4 个测试台：完整帧亮度统计、控制器闭环/写握手、64 位异步邮箱、统计→CDC→AE→原增益/曝光表的反馈集成 | `AUTO_EXPOSURE_CONTROL_PASS`、`AE_FRAME_STATS_PASS`、`AE_STATS_CDC_PASS`、`AE_LIGHTING_LOOP_PASS` |
| `run_awb_frame_adaptation.ps1` | 按帧计算与提交红/蓝增益、近中性样本选择、平滑/限幅、整帧增益固定、四像素输出和 54 拍总延迟、相邻输入帧的 AWB 算术及完整 720p；延迟缓存使用厂商 DRAM 功能模型 | `AWB_FRAME_ADAPTATION_PASS` |
| `run_red_target_lighting.ps1` | 独立逐像素 RGB 判定及 3×3 多数滤波参考，暗红、强粉红、非红颜色、门限边界、valid 空拍、截断/连续帧、目标框和像素计数 | `RED_TARGET_LIGHTING_PASS` |
| `run_isp_lighting_integration.ps1` | 真实 `isp_top` 内预 AWB AE 统计、AWB、彩色/Scharr 切换、红色检测和 96→128 打包，在三个完整 720p 场景中检查帧标志、像素/字节总数及目标结果 | `ISP_LIGHTING_INTEGRATION_PASS` |

红色检测还可按生产分辨率运行：

```powershell
& 'D:/vivado_work/anlogic_edge_osd/sim/run_red_target_lighting.ps1' -Width 1280 -Height 720
```

AE 的生产统计位于 AWB 前，每完整 720p 帧抽取 7,200 像素，
输出 `{sum32, count16, bright16}`，`sum` 仅累加 `Y<232`，
`count` 仍统计全部采样，`bright` 为 `Y>=232` 数量。
控制端默认写曝光 1000/增益 16，范围 4..1991/16..144，非高光均亮目标
96..128；非高光至少 25% 才能偏暗增亮，少于 12.5% 时减亮，
非高光达到 12.5% 但未到 25% 且偏暗时保持。每次实际 I²C done 先低后高后忽略 3 帧统计。
帧统计测试覆盖空闲帧首、帧首与像素同时到达、保持的帧首、最终像素、
错误行尾、截断帧、新帧重新同步、未标记额外数据、停止及复位。

AE 回归本轮结果：

```text
AUTO_EXPOSURE_CONTROL_PASS requests=63 commits=61 checks=596
AE_FRAME_STATS_PASS small_frames=7 large_frames=1 production_samples=7200 checks=10
AE_STATS_CDC_PASS captures=301 checks=301 repeated=16 walking=128 random=128 stream=300 stalled_latest=50 resets=2
AE_LIGHTING_LOOP_PASS frames=1571 requests=139 commits=139 stable_checks=4448 convergences=6 mixed=10 boundaries=4 color_fields=4
```

邮箱测试核对相同值的连续帧也有 valid 脉冲，逐位和随机 64 位 payload、
快速连续输入有序合并、目的钟停止后先接收在途快照再接收最新 pending 快照，
以及复位取消在途事务。AE 反馈测试运行 100 MHz 视频域和约 23.81 MHz 控制域，
通过真实 `SC520GainTbl`、`uics520regAE` 表模拟 8 项写入和 group release，
亮→暗→亮、源时钟停止/恢复、复位恢复、全白恢复共六个场景均进入目标亮度范围。
混合场景以 128×40 的实际 RGB 帧输入统计模块，按 32 像素×4 行块组成
40 个采样块，光源照度 1000、背景照度 16。光源占 15%/30%/50%/75%
并改变位置时，背景亮度 103 连续 8 帧达标，随后 20 帧没有新增调节请求。
85%/90% 边界从光源实际亮度 255 进入，并检查首帧高光计数分别 34/36；
85% 保持背景 103，90% 为防近全白降至背景 2、光源 133 后停止调节。
这四项边界测试证明没有反复明暗请求，不证明高光占满画面时背景仍能看清。
四项饱和 RGB/粉红固定输入只验证高光计量，不模拟其随曝光变化的色彩，
也不验证单个通道防过曝。
这是逻辑反馈及寄存器语义验证，不模拟 SCL/SDA 电气、噪声、镜头或真实传感器感光响应；
具体收敛帧数不代表实物验证结果。

最新四项 AE 回归日志位于 TEMP 的
`anlogic_auto_exposure_de1491ffdb20414784be88abd43da9c9/`。
旧策略使用冻结的旧统计和旧控制器，以同一混合场景另编译
`AE_LEGACY_POLICY_REPRO` 分支，复现结果：

```text
AE_LEGACY_MIXED_REPRO_PASS fraction=6/40 source_illumination=1000 background_illumination=16 background_min=2 background_max=4 AE=180 AG=16 requests=70
```

完整记录保存在 TEMP 的
`anlogic_ae_legacy_mixed_loop_77101abc37de46b9b5ecbb7939574492/`；
此分支需同时使用旧统计与旧控制器，仅用于保留问题证据，不属于正常入口。

当前源码的 AWB 与 ISP 回归结果：

```text
AWB_FRAME_ADAPTATION_PASS frames=102 pixels=26868 full720p_beats=230400 candidates=91 holds=8 resets=4
ISP_LIGHTING_INTEGRATION_PASS frames=3 awb_groups=691200 edge_groups=691200 packed_words=518400 bytes=8294400 ae=3 targets=3 edge_white=556
```

本次 ISP 回归重新核对仅累加非高光的统计语义；最新 TEMP 为
`anlogic_isp_lighting_495d2056dbe445cdae4e854ac503f2ba/`。
AWB 54 拍回归位于 `anlogic_awb_frame_2781817f774c45a09be6527c41f6fe11/`；
测试中的复位会主动取消尚未输出的延迟像素，因此检查像素数与旧两拍版不同。
AWB 与 ISP 集成测试不模拟 MIPI/RAW 到 RGB 的真实去马赛克过程。
ISP 测试只在去马赛克后的 RGB 边界提供输入，外围 demosaic 使用测试 stub，
Scharr RAM 使用 `SCHARR_PORTABLE_RAM` 行为模型；AWB 的 52 拍缓存使用
`D:/TD/sim_release/ph1p/ph1p_logic_dram.v` 内未修改的功能模块。
它验证 AWB 54 拍像素/valid 延迟和后续模块连接，帧间消隐为 68 拍，
允许旧帧排空且保留既有白平衡提交场景。
它不单独代表 Scharr 厂商 RAM、DDR、HDMI 或整机时序已经验证。
统计流水或增益计算修改后，必须重新运行 AWB/ISP 入口；
最终面积和时序需以对应源码的 TD 报告为准。

## 当前 Scharr 独立回归

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

## OSD 资源优化的输出等价验证

`tb_hdmi_mixer_equivalence.sv` 同时运行旧版和候选版 mixer，
逐拍比较读使能、DE、HS、VS 和 RGB，包括消隐及复位。
覆盖六种配置、四个完整 1280×720 帧、16 种诊断状态、
256 个错误码、帧计数多种数字与回卷、12 组目标坐标场景。
字库另核对全部 4096 个字符/行组合，Logo 核对全部 32768 个地址。
测试台不参与 TD 综合。

参考必须是优化前独立保存的 `hdmi_mixer.v`、`anlogic_logo_rom.v`
和 `osd_char_lib.v`，不能把候选自己作为参考。运行入口：

```powershell
& 'D:/vivado_work/anlogic_edge_osd/sim/run_hdmi_mixer_equivalence.ps1' `
  -BaselineDir 'C:/Users/1/AppData/Local/Temp/anlogic_mixer_baseline_20261010_144803'
```

入口把参考和候选冻结到独立 TEMP 目录，只在参考副本中改模块名字。
成功标志为 `HDMI_MIXER_EQUIVALENCE_PASS`。
OSD 优化时通过 5,493,339 个有效输入像素、1,042,020 个消隐检查周期；
复位中按原行为取消两拍未输出像素。
已通过全套测试的 mixer 与最终生产 mixer 文件完全相同。
最终 Logo 只把第一拍从保存索引改为保存地址以适配 TD 的 ERAM 推断；
它与全套测试版本另经全部 32768 地址、4096 次随机跳转和裁剪范围外地址
逐拍对照，共 36,868 拍通过。两版本像素表相同。
最终整机网表的 10 个 Logo ERAM 初始化另经逐地址解码核对，
全部索引和调色板数据与最终 RTL 相同，重建 32768 个像素与原版一致。
OSD 优化版本的整机布局布线在现有约束下通过，建立/保持余量为 +0.564/+0.020 ns；
这是增加本轮光照自适应之前的报告，不能当作当前 AE/AWB 版本的最终结果。
资源、约束审计范围及 TEMP 报告位置见工程 README，实物显示仍需上板验证。

## 目标框与 DDR 帧对齐

`tb_target_frame_alignment.sv` 运行真实系统顶层、`video_in`、`video_out` 和 `hdmi_mixer`，根据实际 DDR 写/读基址建立独立参考，检查四槽轮换、完整/无目标/截断帧、邮箱 ACK、复位、边缘模式坐标补偿及 mixer 的帧首锁存。14 项检查核对摄像头 4 位状态和 8 位错误码经诊断 CDC 后到达实际 mixer 输入；另 19 项检查运行真实顶层状态逻辑，验证初始化 done 不冒充首次 AE 应用、实际 busy→done 置位、后续曝光/增益变化与写 busy 保持已应用状态、持续 I²C 错误/配置失效清除状态及复位恢复。测试台以 `force` 提供 ISP 结果、摄像头配置握手、诊断值、图像标志和异步时钟，因此不覆盖摄像头 I2C/AE/ISP 算法内部、真实 DDR 传输或完整 720p 像素扫描。

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

每一步都应无 ERROR，最终成功标志为 `TARGET_FRAME_ALIGNMENT_PASS`，
当前应包含 `diagnostic=14 actual_status=19`。
`TARGET_ALIGNMENT_STUBS` 只启用测试台末尾的空外围模块，
包括 AE 控制器、AE 统计 CDC、ISP、摄像头控制及其它外围/IP；
真实顶层状态逻辑和 `camera_diag_cdc` 保留并接受边界激励。
只编译上面列出的文件，不可同时编译同名真实外围/IP 模块。
空模块使用统一宽度的输入端口，宽度不匹配警告属于测试边界声明，
不代表生产 RTL 接线。测试台没有加入 TD 工程。

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
