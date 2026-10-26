# 保持现有功能的 Slice 压缩方案

审查日期：2026-10-20。本文保留完整链路审查后制定的原方案；制定时仅新增方案文档，没有修改 RTL、构建约束或烧录文件，也没有运行新的构建或回归。后续按方案执行的改动、候选取舍与实测结果见 [实施记录](SLICE_COMPRESSION_RESULTS.md)。

建议先合并形状分类中的重复算术和多目标几何读取，再消除帧桥与延迟监测中的重复存储、计数和运算，随后评估显示标签布局的分时共享。候选必须通过全工程最终布局布线验证；本文不承诺尚未实测的 Slice 节省量。

## 1. 基线与验收口径

方案制定时的生产版本为 `src-f87677ec3bf9`。当时重新校验全部 **222 个生产输入，差异为 0**；bit 的 SHA256 与发布清单一致。以下数字和证据均指这份冻结基线。

| 指标 | 当前最终布局布线结果 | 本方案默认验收条件 |
|---|---:|---|
| Slice | **18,929 / 21,216，89.22%** | 首要指标，最终采用结果必须低于此值 |
| LUT6 | 18,200 | 不增加 |
| 寄存器 | 17,784 | 不增加 |
| ERAM | 79 / 108 | 不增加 |
| DSP | 15 / 40 | 不增加 |
| setup / hold 余量 | +0.103 / +0.020 ns | 原频率、原约束下全部通过，并记录余量变化 |

现有功能边界：1280×720、CSI 每拍四像素、十三种显示模式、红/绿/蓝最多四框、运动单总框与中心十字、形状分类与稳定策略、四个 DDR 帧槽、冻结/旧帧对应关系、完整 OSD 和可切换延迟面板。像素精度、吞吐、对外流水延迟、检测结果发布拍数和跨时钟协议均须保持。标签布局允许在像素扫描到标签之前调整内部计算调度，但显示像素及其输出拍必须一致。

资源结论只取 `system_phy.area` 的最终 `#slice`，不把门级 `#slice*`、源码运算符数量或逻辑寄存位直接换算成 Slice。当前 `#slice*` 为 20,965，是布局前估算，不能拿来与最终 18,929 比较。

当前 Slice 分项为 logic LUT 13,938、adder 3,774、reg-only 729、RAM 488。减加减链、比较器和宽选择器值得优先验证；减少 FF 未必同比减少 Slice，因为寄存器可能与逻辑共占资源。报告中的 feedthrough 3,566 也不能直接当作可删除的 3,566 个 Slice。

上一轮保留结果为 18,958 → 18,929 Slice、18,318 → 18,200 LUT6，实际分别减少 29、118；FF 增加 1，ERAM/DSP 不变。曾尝试的 PDPW 延迟 RAM 虽把 ERAM 降至 77，却得到 18,989 Slice，已撤回，不进入本方案。

证据：

- [基线最终物理面积](../build/slice_compression/baseline_release/release/system_phy.area)
- [基线最终布线时序](../build/slice_compression/baseline_release/release/system_pr.timing)
- [基线发布清单](../build/slice_compression/baseline_release/release/release_manifest.json)
- [基线生产输入校验清单](../build/slice_compression/baseline_release/release/source_sha256.csv)
- [上一轮实测记录及已知测试限制](/D:/vivado_work/anlogic_edge_osd/docs/RESOURCE_OPTIMIZATION.md:1)

## 2. 整条链路的审查结论

生产图像链路为 MIPI/CSI → RAW10 解包 → LSC → demosaic → AWB → 空间效果选择 → RGB888 紧密打包 → FIFO/四槽 DDR → 解包 → HDMI 效果和 OSD → HDMI TX。

RAW 统计旁路服务自动曝光；AWB 输出另送颜色/形状多目标和运动检测，结果经稳定器、帧上下文与 metadata 桥绑定到实际 DDR 读槽。延迟监测同时采集 RAW、ISP、DDR 和显示事件。压缩必须覆盖这些旁路的依赖，不能只看图像主通路。

报告中的主要时钟域约为 CSI 103 MHz、DDR 用户域 66 MHz、HDMI 像素域 75 MHz。算术共享只发生在同一时钟域内已有的互斥状态或计算时隙；跨域仍保留原握手和同步协议。

| 链路环节 | 审查范围与结论 |
|---|---|
| 摄像头、CSI、RAW10、AE | 核对实际工程源、接线、采样统计和控制。模块较小，握手及帧标记优先保持；AE 宽接口的常量位已有裁剪。 |
| LSC | 当前已有定标 mesh、DDA 和行 ROM；保留标定数据、量化与流水。4 ERAM/4 DSP，不作为首批重构对象。 |
| demosaic | 审查 Bayer 分支、方向选择、边界镜像与行缓存。候选是按行奇偶共享算术；不能降低为普通双线性插值或改变行缓存行为。 |
| AWB | 审查采样过滤、统计上界、串行除法及增益生效时点。存在可证明的位宽压缩；像素乘法和对齐延迟保持。 |
| Scharr/漫画/浮雕/形态学/掩码预览 | 审查所有运行时模式及窗口。已有不少公共计算；方向判定仍有可共享算术。运行时可切换功能都要保留。 |
| 颜色/形状多目标、运动及稳定器 | 形状描述器的重复加减链、多目标数组的跨状态重复读 mux 是主要机会。不能删减检测、跟踪或稳定策略。 |
| 打包、FIFO、DDR、解包 | RGB888 已紧密打包，每帧 172,800 个 128 位字。维持四槽与带宽；自有外围逻辑不大，不能用降色深或减槽换资源。 |
| 帧桥、CDC、延迟监测 | 有模式互斥数据压缩、重复完帧计数、按现有流水共享减法器的机会。队列深度、nonce、时间精度及读槽冻结不变。 |
| HDMI mixer、标签和面板 | 审查固定 OSD、标签避让、目标框和叠加顺序。可利用标签首个可见像素之前的计算窗口共用比较器。 |
| DDR PHY/controller、HDMI TX IP | 核对生产接口、配置与实际物理资源；部分内部 RTL 加密，不能宣称已审完其内部实现。没有等价配置证据前不改协议逻辑。 |

### 物理资源主要落点

以下第一张表为互不重叠的顶层归属。`logic LUT / ripple / FF` 是报告中的层级资源，**不是各模块的 Slice 数**。

| 同级模块 | logic LUT | ripple | FF | ERAM | DSP |
|---|---:|---:|---:|---:|---:|
| ISP | 6,363 | 2,597 | 6,975 | 52 | 14 |
| target_frame_bridge | 1,725 | 282 | 2,961 | 0 | 0 |
| hdmi_mixer | 1,655 | 220 | 763 | 10 | 1 |
| DDR controller/PHY | 2,109 | 111 | 3,439 | 0 | 0 |
| HDMI TX | 606 | 28 | 1,218 | 5 | 0 |
| latency monitor | 417 | 134 | 1,017 | 0 | 0 |
| video_in/out、mc 接口合计 | 286 | 98 | 353 | 12 | 0 |
| 其余 | 777 | 304 | 1,058 | 0 | 0 |

ISP 内部重点如下；这里的父子项不能再与上表重复相加。

| ISP 子模块 | logic LUT | ripple | FF | ERAM | DSP |
|---|---:|---:|---:|---:|---:|
| AWB | 481 | 230 | 736 | 0 | 8 |
| demosaic | 541 | 344 | 974 | 8 | 0 |
| LSC | 293 | 157 | 162 | 4 | 4 |
| RGB 空间效果 | 1,726 | 560 | 1,733 | 19 | 0 |
| 其中 Scharr 及共用效果 | 1,644 | 560 | 1,710 | 14 | 0 |
| 检测及稳定 | 3,084 | 1,256 | 2,982 | 21 | 2 |
| 其中多目标引擎 | 1,858 | 764 | 1,413 | 8 | 2 |
| 其中形状描述器 | 625 | 508 | 206 | 0 | 0 |

因此先处理自有逻辑中的重复 carry 链、选择网络及多份 metadata，比先动图像 RAM 或加密 IP 更有依据。

## 3. 候选改法及保真条件

下列数量均为结构分析，不是已获得的 FF/LUT/Slice 减少量；新增选择逻辑和布局代价必须计入。

### A. 形状描述器：合并受控加减，第一批优先

入口：[red_target_detect_96.v](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/isp/red_target_detect_96.v:1398)。

目前先算 `center_negative ? -product : product`，再从 `moment` 中减去结果。生产综合网表仍分别存在 38 位的 `neg2` 和 `sub10` 链，证明不是源码重复、网表已共用的情形。

改为一条完整 `MATH_BITS` 位的受控加减：

```text
moment + (product XOR {MATH_BITS{!center_negative}}) + !center_negative
```

按模 2^MATH_BITS 计算时与原式对全部输入位模式等价。显式控制位宽和符号解释，保留后续绝对值、串行乘法、状态和 ready 拍。

同文件第 1415、1420 行的 U/V 投影分别计算 `mx2+my2`、`mx2-my2`，只在互斥投影使用。可先选第二操作数极性及进位，再共用算术链；网表当前 `add1` 和 `sub0` 独立。必须保留零扩展、signed 解释和 V 投影的 `2*IMG_HEIGHT` 偏移。

两项各自试验。结构上不需要新增 FF、ERAM、DSP或时钟拍；风险是 TD 未将控制极性和进位映射成预期单链。先看实际映射，再跑全工程布局布线。

### B. 多目标几何：统一读地址，共用 Top4 读取 mux

入口：[分类几何读取](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/isp/red_target_detect_96.v:960)、[配对读取](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/isp/red_target_detect_96.v:988)、[轨迹更新](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/isp/red_target_detect_96.v:1222)。

同一组 `top_xmin/xmax/ymin/ymax` 分别按分类、配对和轨迹索引动态读取。网表确认同一位进入三套独立 LUT6 mux。

这些用途在状态上互斥，可先按原状态选择统一两位读地址，再共用四个字段的 42 位读取网络。结构目标是消除重复的四选一网络，扣除地址选择成本；不增加存储或处理拍数。

`S_CLASS_WAIT` 全程保持分类索引，满足描述器 `STABLE_INPUTS=1` 的要求；四槽并行发布、Top4 排序与匹配次序不变。主要风险是增加状态到数据的组合路径，必须检查真实关键路径。

### C. DDR 写帧：共用计数，保留两种完成边沿

入口：[top 接线](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/design_top_wrapper.v:985)、[bridge 计数](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/target_frame_bridge.v:350)、[latency 计数](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/video_latency_monitor.v:214)。

两个模块使用同一 DDR 时钟、复位、write_start、slot、write_word，生产 `FRAME_WORDS` 都是 172,800；网表仍保留两套 18 位计数器。

但 bridge 将 start 同拍 word 计入，latency 不计入，不能直接共用一个 complete。保留 latency 口径的计数 C，并在 start 锁存 h=write_word：

```text
后续 word 到来时：
latency 完成条件：C == FRAME_WORDS - 1
bridge  完成条件：C == FRAME_WORDS - 1 - h
```

默认两个阈值为 172799/172798，只差最低位。可共享上 17 位比较、计数和 active，分别生成原拍完成事件；结构上计数与 active 从 38 位变为 20 位，并减少一套增量器。各槽 complete、age 等状态保持。

需要联合证明：start 优先级、截断重启、空拍、末字、额外字、读写同拍、age 清理同拍、复位和停钟。`FRAME_WORDS=1` 保留 bridge 的 start 同拍完成特例；通用参数实例保留原语义。不可给完成事件再加一拍寄存。

### D. 延迟监测：用现有三拍时隙共享减法

入口：[video_latency_monitor.v](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/video_latency_monitor.v:254)。

当前 display 边沿锁存样本，下一拍并行计算 total/ISP/buffer，再下一拍发布。生产网表保留 24/24/20 位的三组差分寄存器。

改为共用一个 `TIME_WIDTH` 位减法器：

| 原有时隙 | 共用减法器计算 | 保持的行为 |
|---|---|---|
| display 采样边沿 | 旧 pending 的 ISP − RAW | 与原采样同一份记录 |
| stage 1 | 已锁存 display 时间 − RAW | total 在发布前备妥 |
| stage 2 | 已锁存 display 时间 − ISP | buffer 直接写输出，三个结果仍原拍同时发布 |

可去掉中间 `S_buffer_delta` 实际保留的 20 位存储；代价是操作数 mux。连续过期检查 `pending_age` 的独立减法保留。

display 与邮箱消息同拍时，仍使用非阻塞更新前的旧 pending；新 display 抢占 stage 1/2 时仍取消旧输出。保留无效样本的数值、模时间回绕和 `TIME_WIDTH=12` 测试配置。风险是采样边沿新增算术路径；不能靠延后输出解决时序。

### E. 帧桥 payload：按颜色/运动互斥关系共用字段

入口：[payload 格式](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/target_frame_bridge.v:54)、[生产结果关系](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/isp/target_detect_switch_96.v:239)。

当前每份 payload 同时保存单框 63 位和四框 168 位。单框包含 42 位边界和 21 位中心；这些数据经过两份 result 邮箱、last、四个 slot 和两份 read 邮箱，共九份。

生产多目标分支有明确不变量：颜色单框边界来自四框中原优先级选出的 first_box，运动发布时四框字段清零。可保留 21 位中心，把重复的单框四边界并入四框坐标区：颜色保存四框并在译码时恢复单框，运动使用同一坐标区保存单框边界。

该阶段结构上少存 `42×9=378` 个数据位及相应宽 mux 位，需扣编码/译码电路。它是本方案较大的存储与选择器压缩机会，但不是“减少 378 Slice”的承诺。

必须保留：

- 中心十字仍使用独立中心。不能从 clip 后边界重算中心，舍入及饱和次序不等价。
- first_box 的原选择顺序，包括没有 valid 时回落到第 4 框的行为；不能自行把无效字段归零。
- 运动源 multi_boxes 为零，但 bridge 目前仍加空间 offset；恢复输出时保留这一细节。
- 无有效 read 记录时原输出的零几何、整帧配置、nonce/frame ID、冻结、迟到结果与全部队列容量。无效 read 按记录的 ready/valid 判断；found=0 或 multi_valid=0 仍可能是有效记录，不能据此清零。
- 通用 bridge 允许单框和多框独立输入。压缩必须在生产实例明确启用并证明输入不变量，或保留通用格式分支。
- CDC 载荷稳定握手及当前 20/20/13 ns 规则仍覆盖新的真实寄存器。

第一阶段不再压缩中心、不减少邮箱或帧槽。风险集中在字段译码、模式切换与异常帧，需要生产链联合差分。

### F. 显示标签：在首个可见像素前分时检查避让

入口：[hdmi_mixer.v](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/hdmi_mixer.v:423)。

当前每拍尝试一个候选位置，组合电路并行检查固定 OSD 和四个 peer 标签。四槽各最多 32 个候选，最多 128 次尝试。有效标签要求 y≥16。

先只把四个可变 peer 矩形检查共用为一个比较单元，每个候选分四个子周期检查，保持原槽位、候选及 compact 回退顺序。候选次数不变，计算预算约 512 拍加少量控制开销。

生产 HDMI 每行 1,650 拍，row 16 约在 26,400 拍；即使只算有效像素也至少有 20,480 拍，足够在任何标签可见之前完成。目标框渲染与图像像素流水保持原拍。固定 OSD 的常量比较先保留，避免为了串行化反而增加 mux。

风险包括小尺寸参数实例、异常早 SOF、布局重入取消，以及新 peer 索引/reject 状态的 FF 成本。对小尺寸应证明窗口足够，或保留原并行实现。若控制成本不能在本项内部抵消、全工程 FF 或 LUT 上涨，则不采用。

验收比较最终标签位置和逐像素输出；内部 label_valid 的提交拍会变化。不能把原“128 拍完成”的内部断言简单删除后就认定等价，必须补上新完成上界和首个可见像素之前完成的断言。

### G. AWB：按统计上界缩位宽

入口：[awb.v](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/awb.v:32)。生产使用这个文件，不是其他目录下的同名旧实现。

720p 每帧 230,400 个四像素拍，采样间隔 16，最多 14,400 个样本；过滤后每通道≤220，因此单通道和≤3,168,000。可以将 sum 的 32 位缩至 22 位，sample_count 缩至 14 位，除数与两份备份和同步缩至 22 位，余数保守保留 23 位。

这些字段当前确实以宽寄存器存在于网表。按上述保守宽度，源码存储预算约减少 88 位，同时缩短统计与除法比较/减法链；这是结构预算，实际物理收益待测。

保留 40 位 quotient、红蓝各 40 拍的除法调度、增益限幅和平滑、SOF 首像素增益生效、短帧丢弃及 54 拍像素延迟。位宽按参数上界推导，不能把 720p 常数硬塞给其他合法尺寸；覆盖背靠背帧、早 SOF 和无有效样本。

### H. Scharr 方向：先选主次轴，共用常数运算

入口：[scharr_edge_detect_96.v](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/isp/scharr_edge_detect_96.v:204)。

当前四 lane 各自计算 `106*ax` 和 `106*ay`，网表保留八套运算 cone。可先选 major/minor，仅计算 `106*major` 并比较 `256*minor`，再按主轴选择方向 0/2，否则保留原对角方向 1/3。

保留四 lane 并行和原流水。对全部 12 位绝对值位模式证明等价，特别是 ax=ay=0 时仍为方向 0，以及阈值相等时的优先级。风险是新增主次轴比较和输入 mux 抵消节省、影响 carry 前时序，因此排在前述结构改动之后。

TD 已裁剪原中间表达式的高位，单纯改写常数乘法形式或把声明的 20 位改窄，不能据此承诺收益。

### I. 后备小项：坐标 clip 与 demosaic 奇偶共享

[bridge 坐标 clip](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/target_frame_bridge.v:75) 有 22 路调用，可试先判断 `value > MAX-offset`，未超限时才取较窄的和；offset 只为 0/1/3。必须保留输入高位判断，覆盖 4095 和所有临界值。需要核对综合是否已做窄化，不能把整个 bridge 的 282 ripple 都算成收益。

[demosaic BGGR 分支](/D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/isp/demosaic_4x_2_0/bilinear_interpolation.v:201) 可研究按 Bayer 行奇偶先选操作数，共用实际互斥的 green_pair 方向单元及成对加法。先确认网表里跨奇偶的单元确实独立；同一 site 的公共表达式可能已共享。保持 edge-aware 阈值、边界和五拍流水；不改 RAM 结构。新增输入 mux 的时序风险使其仅列后备。

## 4. 不计入本轮收益的项目

- Scharr 与 motion 的部分灰度加法、Gaussian/cartoon 的部分窗口控制，已经由综合器跨模块共享；Gaussian 重叠求和和形态学横窗也已有优化。
- bridge 的 nonce/start nonce、跨模块重复的部分 frame ID、slot ID 和 active slot 已共享；AE 的 64 位接口每份实际仅保留 39 位，不能按声明宽度虚算 FF。
- video_out 声明的 128 位延迟寄存器实际仅低 16 位保留，不能声称再删掉 112 个 FF。
- 显示参数固定零位、SHOW_RAW_STATS=0 的未启用逻辑和旧单目标分支已裁剪。十三模式、连续运行的检测和 motion 参考更新都属于现有功能。
- FIFO 深度、四个 DDR 帧槽、RGB888、检测精度、形状规则、时间位宽和 nonce 不缩减；不能靠这些改变资源基线。
- bridge 的 pending/last 邮箱支持停钟、提前结果和最新快照；不能因正常帧率较低而删掉。
- DDR 当前已经关闭 ECC；HDMI 虽无有效音频输入仍有 IP 内部音频资源，但无官方等价裁剪证据前，不直接删除音频/InfoFrame/岛区逻辑。
- 全部候选均不新增图像 DDR 访问、整帧缓存或 DSP。更换 RAM 模式只有在最终 Slice、LUT 和全部资源门槛均满足时才可能采用。

## 5. 实施与验证顺序

建议分批推进，每个编号独立 A/B，保留可追溯的源文件和报告：

1. **先减算术和读 mux**：A 的两项分别验证，再试 B；这些改动不改变格式、存储或周期。
2. **再合并现有状态与流水运算**：分别试 C 的 DDR 计数和 D 的 latency 减法，联合检查边沿。
3. **再做跨模块数据格式压缩**：E 单独实现，保持通用分支，对生产输入不变量加断言并做端到端差分。
4. **再利用显示前计算窗口**：F 单独实现，先证明最坏完成拍，再核对整帧像素。
5. **最后试范围缩宽和其他算术共享**：G、H、I 各自评估；前面候选若没有实际 Slice 收益，不为了凑数量强行合入。

每项先进行有针对性的等价/功能检查，再看实际综合是否消除了目标硬件；综合没有结构收益或时序明显不利时提前停止该项。通过初筛后必须独立跑最终布局布线，以同工具链、同器件、同约束和同布局设置比较。组合版本还要再次完成全工程验证，不能将单项收益简单相加。

当前构建入口 [run_image_quality_build.ps1](/D:/vivado_work/anlogic_edge_osd/verification/run_image_quality_build.ps1:1) 支持不发布的试验：`-SkipRoute` 仅作综合初筛，不带该开关则执行最终布线。试验阶段都不传 `-GenerateBit`，从返回的独立快照目录归档报告；该参数会发布到固定 best_result。`-OutputDirectory` 不能隔离 bit 发布，不应当作保护正式 bit 的选项。只在功能与全资源门槛确认后发布最终版本。

### 回归覆盖

这些是后续实施时的验证入口，本次没有重新运行。

逐拍差分的参考必须冻结为本方案的当前生产版本。Scharr 差分脚本默认使用上一轮改动前的历史快照，实施 H 时应显式传入 `-ReferenceRtl`，指向冻结的 `src-f87677ec3bf9` 源文件，保证单项归因。

| 改动范围 | 现有回归入口（位于 `D:\vivado_work\anlogic_edge_osd\sim`） | 必须增加的针对性覆盖 |
|---|---|---|
| A/B 形状、Top4 | `run_color_shape_target.ps1`、`run_color_shape_stability.ps1`、`run_red_multi_target.ps1` 的 Both 模式，以及旋转回归 | 基线/候选逐拍差分；四投影、正负边界、720p 高坐标矩、STABLE_INPUTS=0/1、ready 拍和溢出 |
| C/E 帧桥、metadata | `run_target_frame_bridge.ps1`、`run_target_frame_bridge_slot_writes.ps1`、`run_target_frame_alignment.ps1`、`run_red_multi_frame_alignment.ps1` | start+word、FRAME_WORDS=1/2/4/8/172800、截断/额外字、无效字段、clip、模式切换、停钟、回绕、迟到结果 |
| C/D 延迟监测 | `run_video_latency.ps1`、`run_video_latency_frame_tag.ps1` | 全输出逐拍比较；display/read/过期同拍、连续 display 抢占、TIME_WIDTH=12 和生产 24 位回绕 |
| F 标签、显示 | `run_multi_target_mixer.ps1`、`run_display_effects_mixer.ps1`、`run_latency_display_toggle.ps1`、`run_video_latency_osd.ps1` | 四框最坏避让、全部候选失败、紧凑回退、全部模式与面板开关、早 SOF、首个标签像素前完成、整帧像素等价 |
| G AWB | `run_awb_frame_adaptation.ps1`、`run_isp_lighting_integration.ps1` | 满上界统计、除法边界、早 SOF、背靠背帧、增益生效拍与独立参考 |
| H Scharr、I demosaic | `run_scharr_morphology_equivalence.ps1`、`run_demosaic_quality.ps1` | 12 位方向阈值等价、Gaussian 两种设置、奇偶/边界、空拍、复位及逐像素差分 |
| 最终组合 | `run_isp_motion_camera.ps1`、`run_isp_red_multi.ps1`、`run_video_fifo_frame_integrity.ps1` 及对应上述回归 | 真实 RAW 输入、十三模式、四种检测配置、DDR 帧对齐、CDC 实际路径命中和最终布线时序 |

现有 Gaussian=0 独立 selector oracle 在原版与当前版都于 cycle=4300 失败；它是已知基线测试限制，不能报成通过。后续需保留此事实，以原版差分覆盖等价性；其他独立参考照常作为验收依据。

最终交付必须同时列出候选与基线的 Slice、LUT6、FF、ERAM、DSP、setup/hold、CDC 约束覆盖、源码指纹及 bit 身份。若 Slice 上涨，即使 ERAM 或 LUT 下降也淘汰该项；若其他资源上涨，按本方案默认门槛同样不采用。目标是有证据的全工程压缩，不是局部资源之间的置换。

## 6. 审查证据定位

本次 RTL 阅读以生产 `.al`、top 实例及发布清单为准；网表证据来自当前发布对应的：

```text
C:\Users\1\AppData\Local\Temp\anlogic_image_quality_8fbb54cc4e0341e48e87ac7315df2d0b\system_gate.v
```

这是本机构建快照的临时路径。正式面积、时序与源码身份以第 1 节固定报告为准；实施时应将参与对照的网表及源码另存证据目录。

| 核查对象 | 当前网表定位 |
|---|---|
| shape 条件取负和相减独立 | `u_shape/neg2` 映射区约 347890 行；`u_shape/sub10` 约 351872 行 |
| U/V 两条算术独立 | `u_shape/add1` 约 333572 行；`u_shape/sub0` 约 351219 行 |
| 同一 Top4 几何位的三组读 mux | 约 319575、323765、349303 行 |
| Scharr 两轴 106 倍分别保留 | `add130/add135` 等四对 cone，约 1187 行的 wire/source 归属起 |
| AWB 宽统计寄存器仍存在 | `u_isp_top/u_awb/sum_r`、`sample_count` 为 32 位，并有对应存储实现 |
| DDR 两套计数未共用 | `u_target_frame_bridge/S_write_count`、`u_video_latency/S_write_count` 均为 18 位，并有对应存储实现 |
| 灰度计算已有跨模块共享 | motion `add2_syn_47/48` 约 279878 行起，输入使用 Scharr 算术节点 |
| 窗口控制已有共享 | 约 244858 行，Gaussian bottom 寄存器使能复用 cartoon Gaussian 的 `vd` |
