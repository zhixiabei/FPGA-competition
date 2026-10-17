# 算法选择与检测模式切换

更新日期：2026-10-17。

当前源码包含五项显示模式：原画加 Gamma、灰度、原 Scharr 边缘、反色和灰度浮雕。
屏幕显示编号与名称，上电默认原画加 Gamma。
**K2** 独立切换红色/帧差运动检测。

## 怎么用

1. 本次浮雕版已完成编译。在下载器中重新加载 `td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit` 并烧录。
2. 使用原来的下载流程烧录。根目录 `build_firmware.cmd` 成功后同时更新上述路径和 `firmware/anlogic_edge_osd.bit`；文件身份见 `build/release/release_manifest.json`。
3. 上电默认显示 `00 COLOR GAMMA`。**K3** 按 `00 原画+Gamma → 01 灰度 → 02 Scharr → 03 反色 → 04 浮雕` 切换，**K1** 反向切换，首尾循环；默认按一次 K1 到 `04 EMBOSS`。
4. 上电默认红色目标检测。按一下 **K2** 切换到帧差运动检测，再按一下切回红色检测。
5. **K4** 保留引脚但不执行操作；五项显示模式均无按键调参。
6. K1、K2、K3 按下和松开均需稳定至少 20 ms；正常按一下即可。长按只触发一次。

`td_project/anlogic_sc520_capture.al` 也支持同样的操作，两个工程默认彩色加 Gamma，并保留原来的 Logo、文字和计数叠加。切换不需要重新配置摄像头或复位 DDR。

显示算法与 K2 独立：所有显示算法都可以叠加红色目标框或运动目标框。
左上方 `(192,80)` 显示 `00..04` 和英文名称：`COLOR GAMMA`、`GRAYSCALE`、
`SCHARR EDGE`、`NEGATIVE`、`EMBOSS`。不再显示参数。
左下角 `RED` / `MOV` 表示当前显示帧的检测算法，`FOUND` / `NONE` 表示是否有目标。
检测模式随 DDR 帧槽保存，因此响应会包含帧首切换和现有视频缓存延迟。
固定摄像头后持续移动目标验证帧差；首帧建立参考，连续 3 帧相容候选才出框。
目标停止或短暂漏检时保持原框 2 帧，第 3 帧清除。确认与平滑会带来跟随延迟。
运动框是 8×8 区域精度的单个总框，可能包含移动前后的位置；
多个目标暂不分别编号。全图至少 40% 区域变化时立即清框；
至少 12.5% 区域变化且其中至少 7/8 同向变亮/变暗时也立即清框。
目标与背景亮度很接近、运动很慢或目标很小时，可能达不到变化门槛。

前版 AWB 显式行尾修复保留。当前生产区域均值差门槛为 10，最少 12 个变化区域，
3×3 区域至少 3 票。另需至少 8 个真正受邻域支持的变化块，
且 `3×支持块数 >= 2×(框宽块数+框高块数)`，避免少数分散小簇形成大框。
确认后的每个框边界，变化不超过 8 像素时保持不动，较大变化按四分之一平滑；
明显异位或尺寸突变的候选不会直接替换旧框。微小、低对比度慢移会更容易被抑制。

自行修改源码后，在 TD 重新打开 `td_project/anlogic_edge_osd.al`，
保存源码和工程后，运行根目录 `build_firmware.cmd`，自动完成综合、布局布线和
bit 生成，成功后更新 `best_result/anlogic_edge_osd.bit` 和 `firmware/anlogic_edge_osd.bit`。
每次修改源码后都必须重新构建，并在下载器中重新加载生成的文件。

## 当前构建状态

本次五模式浮雕版 `src-b81e1a687c70` 于 2026-10-17 18:44:37（北京时间）生成 bit。
最终 Slice 14,881/21,216（70.14%）、LUT6 13,612、寄存器 12,793、
ERAM 62/108、DSP 13/40；建立余量 +0.117 ns，保持余量 +0.020 ns。
配置跨时钟的 13 ns 约束覆盖全部 3 条有效路径。
221 个构建输入文件与工作区逐项 SHA256 一致，两处 bit 内容一致。
当前 bit 的 SHA256 为 `6315C6903906330B1556063D532224DA01068D0BED9C193562E2EE3FDF0C695B`。
构建身份见 [发布清单](../build/release/release_manifest.json)，本次回归证据见
[algorithm_regression.zip](../build/verification/algorithm_regression.zip)。
新浮雕版真实摄像头画质和按键操作仍需重新烧录后验证。

## 工程检查

当前工程应包含 `display_effect_control.v`、`display_effects_rgb888.v`、
`gamma_lut_rgb888.v`、`video_mode_control.v`、`rgb_edge_switch_96.v`、
`scharr_edge_detect_96.v`、`motion_target_detect_96.v` 和
`target_detect_switch_96.v`。若 TD 报未知模块，
先检查当前窗口的源文件列表；磁盘上的 `.al` 更新不会自动刷新已打开的工程。
现有 LSC 和 RAW10 自动曝光模块已登记；彩色校准表已移除。
重新打开当前磁盘工程后再综合，避免 TD 窗口沿用旧源文件清单。

若出现 `HDL-8007 ... target_detect_switch_96 ... is a black box`，
检查源文件列表是否同时包含 `motion_target_detect_96.v` 和
`target_detect_switch_96.v`，并确认 `red_target_detect_96.v` 未被排除。
2026-10-15 22:49 的失败综合快照缺少这两个新文件，主 `.al` 也被旧清单覆盖；
已补回登记并恢复红色检测的综合参与。
先关闭旧工程，再重新打开磁盘上的 `td_project/anlogic_edge_osd.al`。
若提示保存旧工程清单，选择不保存，避免再次覆盖修复；源码编辑可单独保存。
仅重跑综合不会刷新 TD 内存中的工程文件列表。

独立综合检查在项目根目录的 PowerShell 执行：

```powershell
& './verification/run_image_quality_build.ps1' -SkipRoute
```

该入口使用当前工程的独立快照，成功标志为 `IMAGE_QUALITY_SYNTHESIS_PASS`。
日志和资源报告写入打印出的 TEMP 目录；此命令不生成 bit，也不更新当前 TD 窗口。

## 按键名称与实际引脚

依据资料包《新HX1P35A开发板手册-HDL版2604.pdf》第 22–23 页：

| 板上按键 | FPGA 引脚 | 本次功能 |
|---|---|---|
| K1 / KEY1 | D5 | 上一个显示算法 |
| K2 / KEY2 | A9 | 红色/帧差运动检测切换 |
| K3 / KEY3 | B9 | 下一个显示算法 |
| K4 / KEY4 | C7 | 保留引脚，无操作 |

顶层输入 `I_mode_key_n` 约束到 D5，`I_detect_key_n` 到 A9，
`I_effect_key_n` 到 B9，`I_param_key_n` 到 C7。
原例程 `I_button[0]`=N2、`I_button[1]`=J14 是 GPIO 扩展口控制信号，
不是板载 K1/K2；不要为了切换而短接扩展口。

## 实现位置

- `user_source/hdl_source/display_effect_control.v`：在 50 MHz 板载时钟下完成 K1/K3 的两级同步、20 ms 按下/释放消抖，生成 0..4 模式请求；同拍 K3 优先于 K1。兼容参数接口固定为 0，K4 不参与控制。
- `user_source/hdl_source/video_mode_control.v`：独立处理 K2，选择红色/运动检测。
- `user_source/hdl_source/isp/rgb_edge_switch_96.v`：帧首锁存显示配置；原 RGB、Scharr 和浮雕的像素、标记和配置统一延迟 **11 拍**，模式 2 选择 Scharr、模式 4 选择浮雕，其余选择 RGB。
- `user_source/hdl_source/isp/scharr_edge_detect_96.v`：保留原高斯、Scharr、NMS 和固定阈值通路；浮雕共享第一层灰度窗口。
- `user_source/hdl_source/display_effects_rgb888.v`：DDR 读出后完成模式 0 原画 Gamma、1 灰度、2 Scharr 直通、3 反色、4 浮雕直通；固定两拍，与原 mixer 像素延迟相同。
- `user_source/hdl_source/hdmi_mixer.v`：按当前显示帧锁存配置，共用原字库显示五项名称，再叠加原 OSD 和框。
- `user_source/hdl_source/isp/motion_target_detect_96.v`：使用片上历史灰度数据进行帧差运动检测，输出单个合并外接框。
- `user_source/hdl_source/isp/target_detect_switch_96.v`：将 K2 请求同步到摄像头时钟域，在帧首锁存检测算法；同文件内的 `motion_result_stabilizer` 完成支持检查、3 帧确认、短暂保持及框平滑，再转发该帧结果和模式。
- `user_source/hdl_source/isp/isp_top.v`：集成两个检测分支，保持原来的 96/128 位图像打包通路。
- `user_source/hdl_source/design_top_wrapper.v`：实例化按键控制器，将 12 位显示配置握手传入 CSI，并将实际生效配置、框和检测模式随 DDR 帧槽保存给 HDMI。
- `user_source/constraints_source/pin.adc`：K1..K4 输入约束。两个顶层 SDC 排除异步机械按键输入路径，并约束配置握手邮箱；同步器后的控制逻辑仍需正常满足时序。

`ENABLE_EDGE` 只表示复位默认值：1 为模式 2 Scharr，0 为模式 0 原画加 Gamma；当前主工程默认值为 0，不用于综合时删除边缘模块。

当前 Scharr 是固定单阈值第一版，没有自适应、色度边缘或 Canny 追踪。
单阈值 20 对应 `abs(Gx)+abs(Gy)>=320`，不要照搬旧算法参数。
Scharr 轮廓相对原图向右、向下各移 3 像素；两类目标框在模式 2 均作相同补偿。
浮雕使用 `E=clip(128+2*(Y中心-Y左上),0,255)`，`Y=(R+2G+B)>>2`。
平坦区域输出中灰 128，轮廓一侧亮、一侧暗；前两行、前两列输出中灰。
共享 Scharr 第一层灰度 3×3 窗口，不增加 DDR 访问或行缓存；本次 DSP 总量仍为 13。
浮雕空间偏移向右、向下各 1 像素，两类目标框在模式 4 均作相同补偿。
可对照[合成输入图](../build/verification/emboss_synthetic_input.png)与
[RTL 浮雕输出](../build/verification/emboss_synthetic_rtl.png)；
它们来自合成测试场景及 RTL 仿真，不是实物摄像头采集。
红色和运动检测独立读取 AWB RGB，在所有显示模式中叠加所选检测结果。
模式 1 灰度使用 `(77R+150G+29B+128)>>8`；
Scharr 内部沿用 `(R+2G+B)>>2`。

当前 AWB 可能在有效像素之前给出帧首脉冲，因此模式更新不能要求 `tuser` 与 `tvalid` 同时为 1。请求恰好到达帧首、尚未通过同步器时，会推迟到后续帧生效。新画面还需要经过已有 DDR 缓冲，按键响应不是零延迟。

## 本次仿真与验证边界

显示模式检查入口：

```powershell
& './sim/run_display_effect_control.ps1'
& './sim/run_display_effects_rgb888.ps1'
& './sim/run_display_effects_mixer.ps1'
& './sim/run_target_frame_alignment.ps1'
```

本次控制器通过 238 项检查，覆盖五项循环、K1/K3 消抖、K4 无操作和参数固定为零。
像素模块通过 337,251 次独立参考对照和 674,502 次时钟边沿外保持检查，
覆盖五种模式和 11 种非法编码。五项名称/mixer 检查通过 16 帧、2,064,384 个像素，
原目标框 mixer 另通过 7,372,800 个像素。
DDR 槽对齐通过 30 次写入、读取和显示事件，覆盖全部五模式；
包含 2 次浮雕边界裁剪和 1 次 Scharr 边界裁剪。完整结果
见 [仿真说明](../sim/README.md#当前结果与边界)。

双击 `sim/run_video_mode.cmd` 运行当前 Scharr 的 64×48 测试。它先运行按键测试，
再运行 `tb_scharr_edge_detect_96.sv` 的独立图像参考，同时核对边缘模块和选择器。
720p 命令保持不变：

```bat
sim\run_video_mode.cmd --no-pause 720
```

本次 Scharr/浮雕 XSim 回归通过 64×48 的 19 帧（含截断帧）、55,488 像素，
64×49 的 19 帧、56,640 像素，以及
720p 的 13 帧、11,980,800 像素；最终 720p 脚本退出码为 0。
覆盖暗灰度边界、两种斜边、奇偶位置的一像素线、等亮度颜色、均匀图、噪声、
五模式切换、提前帧首、连续帧、空拍、复位与 11 拍对齐。
720p 浮雕核对全部 65,536 组中心/左上灰度组合，
含 132,410 个饱和暗像素、132,201 个饱和亮像素和 11,383,044 个中灰像素。
成功标志为 `VIDEO_MODE_BUTTON_TEST_PASS`、`SCHARR_EDGE_TEST_PASS`、`EMBOSS_TEST_PASS`，
`result.txt` 为 `PASS`。所有产物写入打印出的 `%TEMP%\anlogic_video_mode_<随机编号>/`。
这些是合成图功能结果，不证明真实暗光画质。

浮雕 ISP 集成检查分别运行红色检测和运动检测配置：

```powershell
& './sim/run_isp_lighting_integration.ps1' -Emboss
& './sim/run_isp_lighting_integration.ps1' -Motion -Emboss
```

两项均以 RGB 注入已知场景，各检查 3 帧、691,200 组 AWB/选择器数据、
518,400 个打包字和 8,294,400 字节；各核对 921,600 个浮雕像素。
运动配置仍保留 13 拍结果延迟和原有三帧确认策略。此项验证 ISP 选择和打包，
没有模拟真实 MIPI、传感器响应和 DDR 器件。

按键测试将消抖参数缩短为 8 个时钟周期以加速仿真；实际顶层使用 1,000,000 个 50 MHz 周期，即 20 ms。2026-10-02 的历史检查覆盖当时两个真实 TD 工程的源码展开、引脚约束合法性检查和顶层 SDC 读取。



该入口覆盖按键、Scharr/浮雕和选择模块，不覆盖打包模块、真实摄像头、完整 ISP、DDR/HDMI 联合仿真或板上画面。原打包模块不支持任意位置的空拍，当前入口的算法空拍测试不能用于改变打包接口的既有协议。综合通过也不等于布局布线后的时序通过。

新增运动检测的复现命令：

```powershell
& './sim/run_motion_target_detect.ps1' -Mode Both
& './sim/run_motion_stability.ps1' -Pipeline Stable -Mode Both -CheckBehavior
& './sim/run_isp_lighting_integration.ps1' -Motion
```

前者用 XSim 便携 RAM 与 ModelSim 厂商 ERAM 分别核对 41 帧图像参考、
6 帧算法切换和 4 帧 720p 全地址参考缓存。该旧选择器测试显式关闭稳定处理，
用于独立核对算法选择；稳定行为由 `run_motion_stability.ps1` 的逐像素场景覆盖。
RGB 注入集成测试检查 13 拍运动结果和 8,294,400 字节打包；
三个输入帧只有两次运动候选，因未连续确认三次，公开结果均应为 `NONE`，
内部原始运动结果另用图像参考逐块核对。
DDR 帧槽/算法/框的元数据对齐由独立顶层测试覆盖。
这些测试不替代真实 MIPI 摄像头、DDR 器件和 HDMI 整机验收。

新增真实 RAW 全链路和逐像素慢移回归：

```powershell
& './sim/run_isp_motion_camera.ps1' -LineBlanking 1405 -MovePixels 4
& './sim/run_motion_realistic.ps1' -RequireDetections
```

前者不注入 RGB、不替换去马赛克，采用厂商 ERAM/DRAM 模型，
检查连续末两行的显式行尾、参考有效性、运动框和打包长度。
后者覆盖 1/2/4/8/16 像素每帧平移、窄目标、斜移、静止、像素噪声、
分散变化区域及全局明暗变化。
以下 1405 拍行消隐、4 像素慢移数字为前版原始算法的历史结果：
全部 921,600 个 AWB 数据拍、691,200 个打包字和每帧 720 个行尾正确；
慢移帧检出 1,920 个等效变化像素，框为 `x=200..367、y=184..303`，
与 AWB 像素域独立参考精确一致。222 帧慢移/干扰回归中，
168 个预定运动场景均检出，54 个非运动场景无误触。

## 上板验收

- 逐次按 K3，确认 `00 COLOR GAMMA → 01 GRAYSCALE → 02 SCHARR EDGE → 03 NEGATIVE → 04 EMBOSS` 循环，且编号与画面一致；用 K1 反向返回。
- 检查默认原画有 Gamma，灰度、原 Scharr、反色和浮雕画面与名称相符；按 K4 应无变化。
- 在浮雕画面中检查平坦墙面为中灰、轮廓有成对明暗边，并检查画面前两行、前两列为中灰。
- 逐次按 K2，确认 `RED` 和 `MOV` 交替显示；用红色静物和任意颜色的运动物体区分两种算法。
- 在全部五项画面分别测试 K2，核对目标框位置及 RED/MOV 标签；浮雕框向右下各补偿 1 像素。
- 长按 K1、K2、K3，确认只触发一次；松开后再按才能再次触发。
- 固定摄像头，等待曝光稳定后持续移动物体，检查连续 3 帧候选后出框、小抖动不会不断换位置、停止后第 3 帧清框。
- 分别测试普通室内光、低照度、灯光切换与远近物体，记录漏检和误框；本版没有摄像头防抖。
- 视频运动过程中反复切换，观察是否有花屏、卡死或半帧混合。
- 复位后检查默认 COLOR GAMMA 与红色检测；检查模式切换不会改变摄像头增益。

## 延迟显示版构建（历史）

该版加入右上角延迟数字和 64 帧曲线。
2026-10-16 最终布局布线为 Slice 14,554/21,216（68.60%）、
ERAM 62/108、DSP 13/40；SWNS +0.132 ns，HWNS +0.020 ns。
版本为 `src-49a1164317e0`，完整结果见
[延迟可视化说明](LATENCY_VISUALIZATION.md)，bit 身份以
`build/release/release_manifest.json` 为准。

## 稳定运动版构建（历史）

2026-10-16 完成综合、布局布线和 bit 生成。
Slice 13,106/21,216，ERAM 62/108，DSP 13/40；
SWNS +0.166 ns，HWNS +0.020 ns。
213 个生产文件及主 SDC 与构建快照一致。
当时 bit 的 SHA256 为
`9C14E875C611F4F86B4CFA605EB2C4BE185149FA864ACF59A8C256798B8BC4CD`，
这些历史身份不代表当前烧录文件，当前身份以发布清单为准。
406 帧场景在两种 RAM 模型下均通过，静止/干扰误触 0/168，
确认后的要求运动 120/120；六帧真实 RAW 链路另行通过。
完整说明见 [运动检测说明](MOTION_DETECTION.md)，报告和压缩日志见 `build/release/`。

## 前版构建（历史）

主工程在 2026-10-16 完成综合、布局布线和 bit 生成。
Slice 12,299/21,216，ERAM 62/108，DSP 13/40；
SWNS +0.253 ns，HWNS +0.020 ns。
引脚报告确认 K2 为 A9、LVCMOS33、PULLUP。
该版旧 bit 和旧面积/时序导出已删除；
行尾与细边故障复现记录保存在 `build/release/framing_fix_history.zip`。
SHA256 为 `B6121FB8CD4D120216693065DC6256AF578A2BE4B018E5E3AEFD435D735DFEB7`。
工作区与构建快照 213 个源文件哈希一致；实物效果需重新烧录后验证。
