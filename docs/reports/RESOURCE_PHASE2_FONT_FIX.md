# 三项资源优化与常规字库修复

日期：2026-10-30，显示布局更新于 2026-10-31。基线为 `9d3b6e91e1bfca11c50d03b2ed7926526ef9a66c`，包含上一轮语音修复。按授权完成前三项资源优化，并更换屏幕字库。仅运行综合和仿真，没有运行布局布线、生成 bit、下载 FPGA 或写入 Flash。下文综合数据与输入指纹记录第一次字库修复快照；当前 kg、双语识别结果、分区框和底部显示布局见文末。后续显示调整只做仿真，不能沿用前面快照的资源和时序结论作为当前版本结果。

后续横向水果识别框及实际采样调整见 [水果矩形 ROI 报告](FRUIT_ROI_RECTANGLE_20261031.md)。该后续修改改变生产系统和预处理输入，本报告的综合数据与显示测试指纹仍只对应各自记录的快照。

## 已完成的修改

| 修改 | 实现与保持的行为 |
|---|---|
| 关闭 Flash 诊断串口 | `fruitfixed_system.v` 末尾新增 `FLASH_DIAGNOSTIC_ENABLE=0`，默认裁掉 R18S/R18F 收发电路，TX 保持高电平。Flash 启动、DDR 读回、两次 CRC 和故障处理保留；独立语音串口保留；非 Flash 配置的 UART 权重加载保留。 |
| Normalize/Gamma 转 ERAM | 生产用 Normalize 表改为 1024×12 位有符号同步 ROM，符号扩展回 16 位，原 768 项值、无效地址输出零和一拍延迟保持。Gamma 原表不变，RG 共用双读口、B 使用另一份 ROM，同拍输出三个通道。 |
| 两个卡通中心窗口缩减 | 仅替换 `u_cartoon_center_window` 和 `u_cartoon_final_window`。只缓存所需的上一行中心数据，36 位四像素组拆成两个 18 位半组，双口分别访问偶数/奇数地址，1280 宽时每个实例只占一块 ERAM。 |
| 更换常规字体 | 中文采用 16 像素宋体点阵，英文字母、数字及标点采用常规 Consolas 点阵，存入原 16×16 字格。组合字库和同步字库一致；原来的显示位置、缩放和流水延迟保持。补齐横线，点和斜杠统一使用该字库。 |

CNN 核心和 24 路 MAC、每拍四像素图像链路、效果选择、检测与稳定逻辑、Logo、延迟面板、称重计价和语音 RTL 保留。模型文件、Flash 布局、DDR 地址图和时序约束未改。

中心缓存仍为局部两拍，整个 Scharr 效果链仍为 11 拍；没有用降低并行度或增加空拍来节省资源。

字库点阵已内嵌在 RTL 中，综合不需要 Windows 字体文件或 Pillow。`verification/refresh_osd_font.py` 仅用于核验和机械再生成字库。

## 同配置综合实测

两版均使用本机 TD 6.2.168116、PH1P35MDG324 和同一主工程/约束，只运行 `run_image_quality_build.ps1 -SkipRoute`。

| 项目 | 本轮之前 | 本轮之后 | 变化 |
|---|---:|---:|---:|
| 估算 Slice `#slice*` | 23374 | 22755 | 减少 619，约 2.65% |
| LUT 总数 `#lut` | 30330 | 29518 | 减少 812 |
| 寄存器 `#reg` | 20302 | 19729 | 减少 573 |
| ERAM | 94 / 108 | 95 / 108 | 净增加 1 块 |
| DSP | 39 / 40 | 39 / 40 | 不变 |

ERAM 的净变化为：Normalize 增加 1 块，Gamma 增加 2 块，两个中心窗口合计从 4 块降到 2 块，合计净增加 1 块，剩余 13 块。

最终层级报告确认：

- Normalize 为 1 ERAM、5 logic LUT。
- Gamma 为 2 ERAM、0 logic LUT、0 fabric register。
- 两个中心窗口各为 1 ERAM、9 logic LUT、19 register。
- 同步字库仍为 1 ERAM。
- CNN 核心仍含 24 个 DSP MAC；Flash 诊断 UART 实例已从默认网表中消失。

综合报告的 `#slice*` 仍显示 107.25%。TD 在报告中明确说明 Optimize-Gate 的 Slice/LUT 是估算值，需要 Optimize-place 后确认实际占用。因此本轮只能确认综合通过和上述同口径变化，不能据此宣布已经放得下，也不能仅凭该百分比宣布放不下。

门级综合时序报告为 `Confidence: Synthesized`，SWNS 为 0.163 ns，HWNS 为 0.114 ns；它不能代替布局布线后的 setup/hold 结果。最终物理占用与时序留给本轮新布局报告确认。

## 验证结果

以下均通过：

| 检查 | 结果与覆盖 |
|---|---|
| Normalize 等值回归 | 遍历全部 2048 地址，正反两轮 4096 向量，4095 次边沿间保持检查；核对有符号扩展与无效地址。 |
| Gamma 回归 | 1281 向量，2560 次边沿间保持检查，255 项单调性检查；包含灰阶、混色、独立通道及禁用旁路。 |
| Flash 完整仿真 | 编程/准确读回、重复写入、非空保护、器件 ID、写保护、Flash CRC、DDR CRC、背压。全部是仿真，没有访问板卡。 |
| 真实系统诊断开关回归 | 默认 TX 空闲；显式打开时 R18S/R18F 带 CRC 应答；备用 UART 接收 256 字节权重并核对 16 拍 DDR 地址/数据及 ACK/R18L；开关前后 Flash/DDR 事务逐周期一致。 |
| 中心缓存双模型回归 | Portable RAM 与 TD 官方 PH1P ERAM 模型均通过。六种尺寸/位宽，包含完整 1280×720；每种模型在 720p 用例核对 3,678,407 个有效中心像素、1,006,100 周期，覆盖空拍、提前 SOF、复位、帧中重启和双口地址不碰撞。 |
| Scharr 全链差分 | 两种 RAM 模型各检查四种尺寸、每种九帧；四个效果输出和 11 拍控制逐周期与原实现一致。另有独立二维图像参考检查 28 帧、77,376 像素，覆盖边缘、浮雕、卡通、形态学与模式选择。 |
| 字库一致性 | 同步/组合库 8192 次检查、8191 次保持检查；生成器核对 52 个常规字形。 |
| 生产水果面板像素 | 1,653,371 项检查、1,652,624 像素，覆盖五类水果与未知类、合法/无效重量金额、横线、小数点、透明背景、边框、Gamma 和真实三拍 HDMI 控制/数据流水。生成六张 DUT 像素预览。 |
| 其他显示回归 | 延迟面板、共享混合器、目标面板、全部 13 种显示模式及延迟开关回归通过。 |
| 原称重语音回归 | 五类计价、105 组语句、稳定/漂移/去重/陈旧数据、生产适配层、1/14/24 位数据边界、串口完整载荷/状态/超时等五组测试通过。 |
| 工程与范围检查 | 两份工程的文件/命名接口/语音源清单、引脚、Python 语法检查通过。12 个图像核心与原主线一致，Scharr 仅允许本轮两个中心窗口替换；另有差分仿真验证功能。`git diff --check` 通过。 |
| 整机综合 | `IMAGE_QUALITY_SYNTHESIS_PASS`，退出码 0。 |

## 证据与版本

最终综合快照指纹：`src-f96f43c660df`。

- 基线报告：`build/voice_resource_fix_20261030/optimized_reports/`。
- 最终报告、综合日志、工程快照及 271 项输入 SHA256：`build/resource_phase2_20261030/final_reports/`。
- ROM、Flash 诊断、中心缓存及语音/Flash 回归日志：`build/resource_phase2_20261030/regressions/`。
- 字库前后对照：`build/resource_phase2_20261030/font_before_after.png`。
- 仿真实际输出的水果面板：`build/resource_phase2_20261030/regressions/font/fruit_panel_class_1.png` 至 `fruit_panel_class_6.png`。

基线和最终综合输入之间仅六个生产 RTL 文件不同：`fruitfixed_system.v`、生产目录中的 `handcnn_normalize.v`、`gamma_lut_rgb888.v`、`scharr_edge_detect_96.v`、`osd_char_lib.v`、`video_latency_osd.v`。

该次综合结束时，快照与工作区的 270 项源码/约束输入完全匹配；后续显示调整已修改显示源码，当前输入以新仿真目录的 SHA256 清单为准。另 1 项为工程文件：快照之后，现场 `.al` 中 `flash_status_uart.v` 条目多出 `AutoExcluded=true`，`UsedInSyn` 和 `UsedInP&R` 仍为 true。未回退这项现场变动；当前默认关闭诊断时不影响网表。将来如果重新启用 Flash 诊断参数，应重新分析工程层级，确认该源被纳入，再完整综合。

最终中心缓存 RTL SHA256：`37E04BA7E18697C43976BAB7B4CED1CEFB19A6EA7D9677CC237C7914A23BD8A9`。

## 复现入口

在仓库根目录执行；各仿真脚本只调用模拟器：

```powershell
python -B verification/check_merge_readiness.py
python -B verification/refresh_osd_font.py
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_resource_phase2_roms.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_fruit_flash_diagnostic_gate.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_fruit_flash.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_scharr_center_delay_equivalence.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_fruit_font_pixels.ps1
python -B verification/run_scale_voice_tests.py --modelsim C:/altera/14.1/modelsim_ase/win32aloem
powershell -NoProfile -ExecutionPolicy Bypass -File verification/run_image_quality_build.ps1 -TdBin D:/TD/bin -SkipRoute
```

中心回归默认从固定基线提交提取旧实现，不依赖被忽略的 build 快照。字体核验工具需要本机字体和 Pillow；常规 FPGA 构建不需要。

后续在 TD 中对更新后的主工程重新综合，再进行布局布线，避免复用旧网表。本轮模型与 Flash 数据格式未变，字体和本轮资源优化不要求重新烧写已有正确权重；字体需要随新 bit 更新到 FPGA。

## 当前显示布局

2026-10-30 至 31 日按后续要求调整 `hdmi_mixer.v` 的水果侧栏：

- 保留原顶部 `FRUIT RECOGNITION`、中英文识别结果、`WEIGHT` 与重量、`TOTAL` 与金额。
- 英文结果按最新要求恢复为 `APPLE`、`BANANA`、`GRAPE`、`ORANGE`、完整 `STRAWBERRY` 和未知类 `UNKNOWN`。仍位于原结果框内：侧栏局部 x=0..319、y=328..359，两倍字号，随中文结果使用类别色。状态行 `IDENTIFIED/NO RESULT` 与底部 `ANLOGIC FPGA` 保持删除；未知类中文位置显示 `--`。
- 重量显示为 `d.ddd kg`，例如 `0037` 克显示 `0.037 kg`，`1250` 克显示 `1.250 kg`，无效重量显示 `-.--- kg`。直接插入小数点保留 1 克精度，没有增加换算除法；内部克、分、计价和语音单位未改。
- 重量区域扩为 8 个字符，保持原两倍字形缩放和三拍 HDMI 流水。
- 原 1024×16 字库的空槽 59/60 加入常规小写 g/k，共 54 个字符。限制原数字槽映射范围，确保分号等未知字符仍为空白。

此前 kg 改动的验证：

- 字库：8192 次同步/组合一致性、8191 次保持和 6464 次未知字符空白检查通过。
- 侧栏字段回归：15789 项检查通过，包括 0、1、37、999、1000、1250、9999 克、无效与损坏 BCD，以及旧 PROBE/RUNTIME 显示。
- 实际三拍 HDMI 像素回归：1,708,071 项检查、1,707,228 像素通过；其中 95,232 个原文字区域位置确认未使能字形，kg 字形、所有水果和无效结果覆盖通过。
- 工程清单、生成器核验和 `git diff --check` 通过。

上述 kg 阶段的预览、输入哈希和像素日志在 `build/fruit_sidebar_kg_20261030/`。字库日志副本为其中的 `font_equivalence.log`，字段日志副本为 `showcase_panel.log`。

### 侧栏分区框

标题、识别结果、重量、价格四个有内容的分区保留完整的 4 像素彩色边框，边框随水果类别着色。分隔线位于 y=104、376、472，价格框在 y=576 前闭合；原 y=184 的空状态分隔线不再绘制，y>=576 不再延伸水果边框。背景为 `24'h101418`，下方空白由独立延迟显示使用。文字字形、颜色、位置、kg 格式和摄像头识别 ROI 框保持。

此前仅恢复分区框的预览、输入哈希与日志在 `build/fruit_sidebar_framed_20261030/`。当前双语结果的预览与回归见下文。

### 左下角检测与算法、右下角独立延迟

1280×720 生产配置中，检测与算法在左下角上下排列；延迟单独放在右下角水果侧栏下方：

| 显示 | 起点 (x,y) | 范围 | 内容 |
|---|---|---|---|
| 当前检测 | (16,632) | 360×32 | RED / GRN / BLU / MOV，保留 FOUND / NONE、形状或多目标计数。 |
| 当前算法 | (16,672) | 360×32 | 两位模式号及当前算法英文名，覆盖全部 13 个模式。 |
| 独立延迟 | (960,592) | 320×112 | TOT、ISP、BUF 三行；三位整数、三位小数和 MS 单位完整保留。 |

左下两行相隔 8 像素，合计 23,040 像素，约占整屏 2.50%。延迟面板在价格框下方留 16 像素间隔，不增加连接水果分区的边框。三处字形保持横纵等比例两倍放大；只裁掉原 ASCII 字格左右各两列空白，形成 24×32 的紧凑字格。独立检查确认所有使用的 ASCII 外侧列没有笔画。延迟窄版每行 13 字符，例如 `TOT:024.123MS`，适配 320 像素宽侧栏空白。

字符定位使用有界常量比较与减法，没有新增变量除法、乘法或视频流水级。延迟转换、饱和与告警语义不变，HDMI 输出继续保持原三拍对齐。SW1 仍在帧边界切换延迟显示，与 SW2 水果开关没有关联；合成层级优先显示延迟，避免水果背景覆盖它。延迟关闭时左下两行位置固定，目标标签可以使用释放的延迟区域。

检测行随原控制切换红、绿、蓝或运动模式，显示当前模式，不将四种互斥模式伪装成同时运行的四组结果。水果开启时仍显示帧桥传来的真实检测状态，沿用 FOUND / NONE、形状和计数语义；帧中输入变化仍等到下一帧锁存。目标框、跟随标签和十字沿用原水果开关控制。逐目标标签避让更新为检测、算法和延迟的真实矩形。

小画幅使用原字号并上下排列；原点减法夹到零。小高度导致汇总行靠近 Logo 时，改放底部最后 16 行，宽度足够时 x=176，避免 Logo 和 HUD 遮住汇总内容。两项底部诊断显示均关闭时，保留旧检测行布局，供旧核心差分回归使用。

### 当前显示验证与预览

- 生产配置实际像素：4,277,104 项检查，独立比对 2,950,102 个有效像素；六类中英文、kg/价格、非法 BCD、四个分区框、被删状态/页脚、边界和三拍视频控制均通过。分别捕获水果开启、关闭时各 921,600 个真实 DUT 输出像素，并独立验证左下文字、右下延迟和周边背景；逐像素验证两倍字号的全部 13 个算法名和 4 种检测模式。CNN 关闭与开启均覆盖 FOUND / NONE、形状和帧中输入变化，110 次帧起点检查通过。
- 延迟模块：默认尺寸 183,689 像素、大字尺寸 417,545 像素、窄版大字 336,905 像素均通过，合计 938,139 像素，包含 N/A、BCD、128000/128001 阈值、三项饱和、DE/坐标边界及一拍输出。
- 延迟开关集成：8 帧、2,867,200 像素通过。显示/隐藏各覆盖 143,360 个面板位置；算法与检测行各覆盖 92,160 像素；标签四次避让、四次释放；显示关闭时仍持续更新全部延迟字段。
- 小尺寸算法/目标回归：13 种算法、40 帧、5,160,960 像素通过，含独立目标行文字参考；另 7,372,800 个目标显示像素通过。
- 侧栏字段检查：5,926 项通过，英文首末字符、完整 STRAWBERRY、缩放、类别色、中文、kg/价格、ROI 和 PROBE/RUNTIME 均覆盖。
- 工程清单、常规字库生成器核验及 `git diff --check` 通过。整屏像素仿真只有 ModelSim Starter 的设计容量性能提示，没有功能错误。

旧核心差分的 shared-font、runtime、serial-layout、label 四组回归均通过。由于本次有意调整布局，这四组在两端均关闭算法和延迟显示，仅证明旧核心路径等值；本次底部布局、放大字形和模式切换由独立参考像素检查覆盖，不能将旧核心差分结果解释为整个新旧 UI 完全一致。

当前生产显示仿真证据位于 `build/fruit_hud_right_20261031/final_pixels/`：`fruit_hud_720p.png` 与 `detection_hud_720p.png` 分别为水果开启和关闭的两张整屏预览，右下延迟在两种情况下均显示；`fruit_panel_class_1.png` 至 `fruit_panel_class_6.png` 为全部识别结果，`console.log` 和 `source_sha256.csv` 保存像素检查与输入版本。截图背景和延迟数值来自仿真激励，不是板上摄像头或实测性能。开关、算法与目标框回归证据在同级上层目录的 `regressions/` 下，`coverage.md` 记录测试快照与最终生产源码之间的覆盖范围。

最终混合器 SHA256 为 `DE8BFBAA1C72CD81019C1F0A2D72D5E56D83F792537EB359A5BA8F79C2254C4D`，延迟模块为 `C08EA112CE75A2E124E94B8059F2A84F7EF75CD7B9A6ED3C30A98C9A87322F52`。主像素回归的 8 项输入哈希与当前文件全部一致。上层目录保留了取消 CNN 文字覆盖之前的中间快照，只能用 `final_pixels/` 作为最终显示证据。

本轮没有重新综合、布局布线、生成 bit 或操作板卡。当前资源及时序需要用户对最新主工程重新综合、布线后确认。
