# 当前功能仿真

## 2026-10-11 LSC 回归

低资源横向 LSC 已接到 RAW10 与 demosaic 之间。以下测试使用当前生产源码，
均只把产物写入打印出的 TEMP 目录，不加入 TD 工程，不生成或下载 bit。

```powershell
& './sim/run_lsc_raw10.ps1'
& './sim/run_demosaic_quality.ps1' -Lsc
& './sim/run_demosaic_quality.ps1' -CsiSource -Lsc -Width 1280 -Height 720
& './sim/run_video_fifo_frame_integrity.ps1' -RawSource -Lsc
& './sim/run_isp_lighting_integration.ps1'
```

独立 LSC 回归用图像坐标和浮点曲线作参考，不复用 DUT ROM、坐标计数或绿色交换路径。
64×17 下测试四种 Bayer，各通道独立强度和黑电平，生产默认、最大/零增益、关闭，
覆盖 0..1023、饱和、空拍、早到/保持 SOF、无消隐相邻帧、截断与流水中复位。
4×5 和 12×7 检查最小宽度和奇数组宽；1280×720 检查默认配置的完整帧。
`O_tready` 改变只核对 ready 接线；LSC 与生产摄像头链一样不可反压。

实际结果：

```text
LSC_RAW10_PASS width=64 height=17 pixels=7616
LSC_RAW10_PASS width=4 height=5 pixels=140
LSC_RAW10_PASS width=12 height=7 pixels=588
LSC_RAW10_PASS width=1280 height=720 pixels=6451200
CSI_FRONTEND_QUALITY_PASS frames=7 raw_pixels=6451200 rgb_pixels=6451200
DEMOSAIC_QUALITY_RESULT bayer=BGGR size=1280x720 frames=7 pixels=6451200 errors=0 markers=0
LSC_DEMOSAIC_PASS frames=7 pixels=6451200
VIDEO_FIFO_REGRESSION_PASS writer_bytes=6512640 reader_pixels=3686400
ISP_LIGHTING_INTEGRATION_PASS frames=3 awb_groups=691200 edge_groups=691200 packed_words=518400 bytes=8294400 ae=3 targets=3 edge_white=556
```

LSC→demosaic 参考先在图像域对每个 RAW 像素进行增益、四舍五入、饱和和高八位截取，
再独立计算 Bayer 插值及边界；CSI 模式保留 RAW10 两个低位，保证先校正再截位。
直接输入小尺寸额外覆盖早到保持 SOF、连续有效、valid 空拍和复位恢复。
启用 LSC 时不沿用“原始灰阶台阶无方向插值误差”断言，因为灰阶图已被有意改变；
全部输出仍与补偿后的独立 RGB 参考逐像素比较。

真实 FIFO 回归检查四种 DDR 相位及完整 720p 彩色/边缘帧，并逐字节核对 DDR 写入，
输出检查共 3,686,400 像素且无溢出/欠读；原厂 FIFO 模型的接口宽度告警保留。
该测试中的 AWB 两帧分别复位，像素检查处于单位增益，不替代 AWB 收敛测试。
原 ISP 集成测试从去马赛克后的 RGB 边界注入图像，新增 LSC 已编译，但该项本身
不验证 RAW LSC；RAW LSC 算术和到 DDR 的检查由前面两项完成。

本轮 TEMP 日志目录：

- `anlogic_lsc_raw10_68f229ceaac540019afd3571205625b2`
- `anlogic_demosaic_quality_5f6eaecfdf914b6b8bf1227ccb811890`（直接输入）
- `anlogic_demosaic_quality_592d1c3d14b14e4aa9d772bd06fec255`（CSI、720p）
- `anlogic_video_fifo_integrity_12adb7ea0c194d57918f2b09961c6f01`
- `anlogic_isp_lighting_9e89cc12318941fd9fdf7d5b987c7e89`

整机 TD 路由和 ROM 初值核验见 [LSC 调整说明](../LSC_TUNING.md)。这些是逻辑验证，
没有模拟实物镜头色差、MIPI 电气、真实 DDR 芯片、显示器或拍屏颜色。

## 2026-10-11 RAW 重建与完整像素通路

```powershell
& 'D:/vivado_work/anlogic_edge_osd/sim/run_demosaic_quality.ps1'
& 'D:/vivado_work/anlogic_edge_osd/sim/run_demosaic_quality.ps1' -Width 64 -Height 49
& 'D:/vivado_work/anlogic_edge_osd/sim/run_demosaic_quality.ps1' -Width 1280 -Height 720
& 'D:/vivado_work/anlogic_edge_osd/sim/run_demosaic_quality.ps1' -CsiSource -Width 1280 -Height 720
& 'D:/vivado_work/anlogic_edge_osd/sim/run_video_fifo_frame_integrity.ps1' -RawSource
& 'D:/vivado_work/anlogic_edge_osd/verification/run_image_quality_build.ps1'
```

仿真项使用 ModelSim 和未修改的 TD RAM 功能模型，所有产物写入打印出的 TEMP。
最后一项冻结完整源码及工程配置到 TEMP，运行主工程综合、布局布线，不生成 bit，
并检查最终建立/保持余量非负。GUI 工程和原下载设置不变。

`tb_demosaic_quality.sv` 从实际 RAW40 端口驱动生产 demosaic，
使用独立图像域公式检查 RGB、首尾像素、行末和帧首，覆盖恒定彩色、亮度渐变、
细线、随机图、横/纵灰度台阶、连续输入、不同空拍、提前/保持的 SOF 和带旧 RAM
内容的复位。64×48 七帧 21,504 像素、64×49 七帧 21,952 像素均零错误。
完整 1280×720 七帧 **6,451,200 像素**，像素/标志错误均为 0，厂商 RAM
仿真无错误或警告；日志为 TEMP 的
`anlogic_demosaic_quality_08a71ee4dbf04b0bbe3d7c15282e56cc/console.log`。
灰度台阶的绿色累计绝对误差：64×48 双线性参考 5,376，新方向选择 0；
完整 720p 的对应累计误差分别为 96,000 和 0，检查 921,600 个 R/B 位置。
这是合成无噪声台阶的验证，不是实拍画质评分或所有图像的普遍提升比例。

`-CsiSource` 将输入边界前移到两 lane 的 16 位 HS 数字字节流，实例化生产
`csi_unpacket_2lane`、`raw10_unpacket_2lane` 和 `uial2axis`，再连接新版 demosaic。
以 RAW10 每四像素五字节的格式生成行载荷，逐像素检查全部十位（低两位也变化），
随后用原独立图像域公式核对 RGB/帧行标志。输入是完整连续 RAW10 长包，帧间和
行间有消隐；复位测试发生在消隐中，不声称覆盖半包复位或任意有效信号停顿。
短包/长包 ECC 和行 CRC 用占位字节，当前生产解析器没有校验它们；该测试
不验证 ECC/CRC、丢包恢复、虚拟通道、多数据类型、传感器噪声或 MIPI 电气。
64×48 七帧 RAW/RGB 各 21,504 像素、64×49 各 21,952 像素均通过。
后者日志为 TEMP 的 `anlogic_demosaic_quality_527ca2257206454f8ea094b9fe8715db/`。
完整 1280×720 七帧 RAW/RGB 各 **6,451,200 像素**，像素和标志错误均为 0；
最终入口还检查七帧和两端精确像素总数，不能仅凭一行 PASS 通过。
日志为 TEMP 的 `anlogic_demosaic_quality_d245081fcef443fa86f86ccd82203d28/`。

此前对旧窗口的四帧检查记录为 TEMP 的
`anlogic_demosaic_quality_118d9240d3c64ea299fe49a02f0b4111/console.log`：
12,288 个像素中 7,180 个与中心坐标参考不符，4 个帧首标志错误。
该负例仅把旧 RAM 未连接的写端口在仿真中接地，未强制像素/控制内部状态；
不接地的全零模型结果未作为硬件缺陷证据。
最终测试入口可用 `-DemosaicSourceRoot` 指向独立旧源码目录，并以
`-LegacyRamTies -AllowErrors` 运行前三种图案的旧版负例。
最终入口的三图案负例也已重跑：9,216 个像素中 4,108 个错误、3 个帧首错误，
日志为 TEMP 的 `anlogic_demosaic_quality_d7a3fe43f38545a8a5c450bd04000ce2/`。

FIFO 入口默认仍保留 RGB 回归；`-RawSource` 在其前端连接真实 demosaic 和
data128_96，Bayer 像素来自已编码坐标的 RGB，重建后另用独立公式逐像素核对。
后续 AWB、彩色/Scharr、打包、实际输入 FIFO/DDR 写请求和实际输出 FIFO/解包
不使用 stub。四种 DDR 相位及完整 720p 彩色/边缘测试均通过：

```text
FIFO_FRAME_INTEGRITY_PASS H=720 phase=9.300 frames=2 bytes=5529600
RAW_TO_DDR_FRAME_PASS pixels=1843200
VIDEO_FIFO_REGRESSION_PASS writer_bytes=6512640 reader_pixels=3686400
```

读回含独立双槽压力场景，每项像素错误、空读、满写均为 0。
最新版 `-RawSource` 入口已复验，五个写入场景均输出 `RAW_TO_DDR_FRAME_PASS`，
完整 720p 彩色/边缘两帧和三个读出场景全部通过。
日志为 TEMP 的 `anlogic_video_fifo_integrity_be32d80269124d00b7e5b3554dc6cf54/`。
不模拟真实 MIPI 电气/CSI 包、传感器噪声/镜头、DDR 控制器或 HDMI PHY。
现有 `run_isp_lighting_integration.ps1` 仍只验证 RGB 边界之后，不把它冒称为 RAW 回归。
该入口本轮重跑通过三帧：691,200 组 AWB/Scharr 数据、518,400 个打包字、
8,294,400 字节及三组 AE/目标结果；日志为 TEMP 的
`anlogic_isp_lighting_c2caed08bc15496c92a8953d38b2c501/`。

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
