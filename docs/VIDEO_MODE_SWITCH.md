# 算法选择与检测模式切换

更新日期：2026-10-19。

当前源码包含十三项显示模式：原画加 Gamma、灰度、原 Scharr 边缘、反色、
灰度浮雕、红绿保色、彩色漫画、Scharr 反色、形态学边缘，
以及所选颜色的二值掩码、腐蚀、膨胀和清理掩码。
屏幕显示编号与名称，上电默认原画加 Gamma。
**K2** 独立循环红色、绿色、蓝色和帧差运动检测。
颜色模式最多显示 4 个独立区域，并识别正方形、三角形和圆形；
运动模式保留 1 个总框。无法可靠分类时保留颜色框，形状标为 `UNK`。
本版已移除 CNN 推理与结果显示，包括中心裁剪框和手势类别文字。

## 怎么用

1. 构建状态和源码版本见下方资源章节。在下载器中重新加载 `td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit` 并烧录。
2. 版本、时序和 SHA256 见 `build/release/release_manifest.json`。
3. 上电默认显示 `00 COLOR GAMMA`。**K1** 按 `00 原画+Gamma → 01 灰度 → 02 Scharr → 03 反色 → 04 浮雕 → 05 红绿保色 → 06 漫画 → 07 Scharr反色 → 08 形态学边缘 → 09 二值掩码 → 10 腐蚀 → 11 膨胀 → 12 清理掩码 → 00` 单向循环；默认按四次 K1 到 `04 EMBOSS`。
4. 上电默认红色目标检测。每按一下 **K2** 按 `红色 → 绿色 → 蓝色 → 帧差运动 → 红色` 循环。
5. **K3、K4** 保留引脚但不执行操作；十三项显示模式均无按键调参。
6. K1、K2 按下和松开均需稳定至少 20 ms；正常按一下即可。长按只触发一次。

`td_project/anlogic_sc520_capture.al` 也支持同样的操作，两个工程默认彩色加 Gamma，并保留原来的 Logo、文字和计数叠加。切换不需要重新配置摄像头或复位 DDR。

显示算法与 K2 独立：所有显示算法都可以叠加所选颜色的目标框及形状，或运动目标框。
左上方 `(192,80)` 显示 `00..12` 和英文名称：`COLOR GAMMA`、`GRAYSCALE`、
`SCHARR EDGE`、`NEGATIVE`、`EMBOSS`、`COLOR KEEP`、`CARTOON`、
`SCHARR INV`、`MORPH EDGE`、`BINARY`、`EROSION`、`DILATION`、`CLOSE MASK`。
模式 09 按 K2 所选颜色二值化，10/11 对原始掩码作 3×3 腐蚀/膨胀；
12 显示 3×3 多数滤波、膨胀、腐蚀后的实际形状输入。MOV 时预览默认红色掩码，
运动检测及其框仍照常工作。形状判断在所有 K1 模式中都使用清理掩码。
左下角显示 `RED/GRN/BLU COUNT:0..4` 或 `MOV COUNT:0..1`，表示当前显示帧的检测算法和框数。
颜色框的完整跟随标签例如 `1 GRN TRI OK`（编号 1..4），
`SQR/TRI/CIR/UNK` 分别表示正方形、三角形、圆形和未知。
目标漏检保持时将末尾改为 `H`；颜色目标仍匹配而暂时保持原形状时仍为 `OK`。
空间不足时使用 `1 TRI OK` / `1 TRI H`。
运动完整标签仍为 `1 MOV OK`。
颜色新目标连续匹配两帧确认，漏检保持两帧，第 3 帧清除；
同一轨迹的形状连续两次相同才确认或切换，单帧波动暂留旧类，
连续第 3 帧仍无原类别支持且未确认新类别时清为 `UNK`。
队列或候选表容量溢出时显示 `OVF`、清除整组框，不退回总框。
颜色区域提取存在连通近似，目标相交、合并时编号可能互换；
形状使用同一掩码的近似周长、面积和投影特征，支持图像平面内旋转，
圆形保持 `9/8` 投影限制；方形有条件增加两像素跨度容差，已确认圆使用双覆盖门槛抵抗边缘波动。
质心容差为跨度的 `1/16`，不做透视矫正。
近方长方形、低轴比椭圆可能分别混淆为 `SQR`、`CIR`。
用填实、分离、宽高至少 12 像素的色块验证，
普通不等边三角形也可识别；严重斜拍、空心、遮挡或贴边时可能标为未知。
具体容量与边界见[多颜色目标说明](RED_MULTI_TARGET.md)和[形状算法说明](COLOR_SHAPE.md)。
检测模式随 DDR 帧槽保存，因此响应会包含帧首切换和现有视频缓存延迟。
固定摄像头后持续移动目标验证帧差；首帧建立参考，连续 3 帧相容候选才出框。
目标停止或短暂漏检时保持原框 2 帧，第 3 帧清除。确认与平滑会带来跟随延迟。
运动框是 8×8 区域精度的单个总框，可能包含移动前后的位置；
多个运动目标仍合为一个框。全图至少 40% 区域变化时立即清框；
至少 12.5% 区域变化且其中至少 7/8 同向变亮/变暗时也立即清框。
目标与背景亮度很接近、运动很慢或目标很小时，可能达不到变化门槛。

前版 AWB 显式行尾修复保留。当前生产区域均值差门槛为 10，最少 12 个变化区域，
3×3 区域至少 3 票。另需至少 8 个真正受邻域支持的变化块，
且 `3×支持块数 >= 2×(框宽块数+框高块数)`，避免少数分散小簇形成大框。
确认后的每个框边界，变化不超过 8 像素时保持不动，较大变化按四分之一平滑；
明显异位或尺寸突变的候选不会直接替换旧框。微小、低对比度慢移会更容易被抑制。

自行修改源码后，在 TD 重新打开 `td_project/anlogic_edge_osd.al`，
保存源码和工程后，运行根目录 `build_firmware.cmd`，自动完成综合、布局布线和
bit 生成，成功后只更新 `td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit`。
每次修改源码后都必须重新构建，并在下载器中重新加载生成的文件。

## 当前构建与资源

最新资源与验证见 [Slice 压缩实施记录](SLICE_COMPRESSION_RESULTS.md)；
此前形状修订见 [方形像素容差与圆形特征保持修订](SHAPE_BOUNDARY_FIX.md)。
以下为前版形状容差与时间稳定版 `src-f2960ad79fd7`，于 2026-10-19 19:32:11（北京时间）
完成综合、最终布局布线和 bit 发布。最终 Slice 19,044/21,216（89.76%）、
LUT6 18,292、寄存器 17,886、ERAM 79/108、DSP 15/40；
建立余量 +0.106 ns，保持余量 +0.020 ns，均无违例。
显示配置 13 ns 约束和目标帧 20/20/13 ns 约束均通过健康检查，
覆盖显示配置 4 条、帧上下文 6,216 条、检测结果 2,318 条和显示快照 257 条路径；
不存在无效约束或无路径约束。

前版 CNN 移除版 `src-5ad2d432a102` 为 Slice 19,046（89.77%）、LUT6 18,292、
寄存器 17,863、ERAM 79、DSP 15；本次 Slice 减少 2、寄存器增加 23，
LUT6、ERAM、DSP 不变。红、绿、蓝仍共用颜色检测链，
Top4 特征移入既有候选 ERAM 的空余地址，共用一个串行形状分类器；
新增预览复用二值窗口，没有增加 DDR 图像读写或整帧缓存。
该版剩余 2,172 Slice、29 个 ERAM 和 25 个 DSP，Slice 占用为 89.76%。
两份 bit 内容一致，均为 1,789,539 字节，SHA256 为
`0A9663FE1C7DBF1D75CCD65929F6022408F6C5168208B04CEE0D5D4C8FB4B25A`；
222 个生产输入与发布清单逐项一致。当前回归日志和源码快照见
[形状容差证据包](../build/verification/shape_tolerance_regression.zip)，
前版 CNN 移除结果保存在 [CNN 移除证据包](../build/verification/cnn_removal_regression.zip)，
删除前的专项结果保存在[十三模式与掩码证据包](../build/verification/color_mask_regression.zip)。
固定烧录文件的完整身份见 [发布清单](../build/release/release_manifest.json)。

## 工程检查

当前工程应包含 `display_effect_control.v`、`display_effects_rgb888.v`、
`gamma_lut_rgb888.v`、`video_mode_control.v`、`rgb_edge_switch_96.v`、
`scharr_edge_detect_96.v`、`motion_target_detect_96.v` 和
`target_detect_switch_96.v` 和 `target_frame_bridge.v`。若 TD 报未知模块，
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
| K1 / KEY1 | D5 | 单向循环下一个显示算法 |
| K2 / KEY2 | A9 | 红色/绿色/蓝色/帧差运动循环 |
| K3 / KEY3 | B9 | 保留引脚，无操作 |
| K4 / KEY4 | C7 | 保留引脚，无操作 |

顶层输入 `I_mode_key_n` 约束到 D5，`I_detect_key_n` 到 A9，
`I_effect_key_n` 到 B9，`I_param_key_n` 到 C7。
原例程 `I_button[0]`=N2、`I_button[1]`=J14 是 GPIO 扩展口控制信号，
不是板载 K1/K2；不要为了切换而短接扩展口。

## 实现位置

- `user_source/hdl_source/display_effect_control.v`：在 50 MHz 板载时钟下完成 K1 的两级同步、20 ms 按下/释放消抖，生成 0..12 单向循环模式请求；K3/K4 不参与控制，兼容参数接口固定为 0。
- `user_source/hdl_source/video_mode_control.v`：独立处理 K2，生成红、绿、蓝、运动四态循环请求。
- `user_source/hdl_source/isp/rgb_edge_switch_96.v`：帧首锁存显示配置；所有像素、标记、配置统一延迟 **11 拍**，模式 2/7 选择原 Scharr、4 选择浮雕、6 选择漫画、8 选择形态学、9..12 选择共用检测窗口的四位掩码，其余选择 RGB。兼容信号 `O_edge_mode` 仅在模式 2 置位。
- `user_source/hdl_source/isp/scharr_edge_detect_96.v`：保留原高斯、Scharr、NMS 和固定阈值通路；浮雕与形态学共享第一层灰度窗口；漫画另建低位宽彩色行缓存，与原 NMS 轮廓对齐后合成。
- `user_source/hdl_source/display_effects_rgb888.v`：DDR 读出后完成模式 0 原画 Gamma、1 灰度、3 反色、5 红绿保色、7 Scharr 取反，模式 2/4/6/8/9..12 直通；固定两拍，与原 mixer 像素延迟相同。
- `user_source/hdl_source/isp/red_target_detect_96.v`：在所选颜色掩码的行段连接中累计周长、面积和四方向投影特征；同文件 `color_shape_descriptor` 串行分类 Top4。
- `user_source/hdl_source/hdmi_mixer.v`：按当前显示帧锁存配置与形状，共用原字库显示十三项名称和两位编号，再叠加原 OSD、最多四个颜色目标框、颜色/形状标签及 COUNT/OVF。
- `user_source/hdl_source/isp/red_target_detect_96.v`：在同一套全分辨率颜色判定前选择主通道，复用多数滤波与闭运算、有界行段连接、Top4 和四槽确认/保持；三个窗口各用一个打包 ERAM 保存两行一位掩码；不是完整 CCL。
- `user_source/hdl_source/isp/motion_target_detect_96.v`：使用片上历史灰度数据进行帧差运动检测，输出单个合并外接框。
- `user_source/hdl_source/isp/target_detect_switch_96.v`：将 K2 的 2 位请求整体同步到摄像头时钟域，在帧首锁存颜色/运动模式；换色清除旧颜色轨迹，结果按原帧号选择模式。
- `user_source/hdl_source/isp/isp_top.v`：集成两个检测分支，保持原来的 96/128 位图像打包通路。
- `user_source/hdl_source/design_top_wrapper.v`：默认 `RED_MULTI_ENABLE=1`，实例化按键控制器与帧桥，将实际生效配置、四框和检测模式随真实 DDR 帧槽保存给 HDMI。
- `user_source/hdl_source/target_frame_bridge.v`：原始 10 位帧号、16 位代次与配置绑定实际写槽；完整写帧后方可显示，按实际读槽冻结整组结果，握手传往 HDMI。
- `user_source/constraints_source/pin.adc`：K1..K4 输入约束。两个顶层 SDC 排除异步机械按键输入路径，并约束配置握手邮箱；同步器后的控制逻辑仍需正常满足时序。

`ENABLE_EDGE` 只表示复位默认值：1 为模式 2 Scharr，0 为模式 0 原画加 Gamma；当前主工程默认值为 0，不用于综合时删除边缘模块。

当前 Scharr 是固定单阈值第一版，没有自适应、色度边缘或 Canny 追踪。
单阈值 20 对应 `abs(Gx)+abs(Gy)>=320`，不要照搬旧算法参数。
Scharr 轮廓相对原图向右、向下各移 3 像素；两类目标框在模式 2 均作相同补偿。
浮雕使用 `E=clip(128+2*(Y中心-Y左上),0,255)`，`Y=(R+2G+B)>>2`。
平坦区域输出中灰 128，轮廓一侧亮、一侧暗；前两行、前两列输出中灰。
共享 Scharr 第一层灰度 3×3 窗口，不增加 DDR 访问或行缓存。
浮雕空间偏移向右、向下各 1 像素，两类目标框在模式 4 均作相同补偿。
可对照[合成输入图](../build/verification/emboss_synthetic_input.png)与
[RTL 浮雕输出](../build/verification/emboss_synthetic_rtl.png)；
它们来自合成测试场景及 RTL 仿真，不是实物摄像头采集。
模式 5 红绿保色使用通道差值、比例和色相范围判定：红色或绿色主通道至少 24，
比其余通道至少高 6，并同时满足比例与色相条件。命中时保留 RGB，
未命中使用现有 `(77R+150G+29B+128)>>8` 灰度；不叠加 Gamma。
它与红色目标检测分支分开工作，不把绿色当作红色检测目标。
模式 6 漫画使用 RGB 各高 5 位做 `1 2 1; 2 4 2; 1 2 1` 高斯平滑，
每通道压到 3 位八级色阶，再扩展回 RGB888，并将原 Scharr/NMS 轮廓置黑。
彩色与轮廓统一向右、向下各偏移 3 像素，两类目标框均作相同补偿。
漫画前六行、前六列填黑；新增片上行缓存，不增加 DDR 图像读写次数。
模式 7 `SCHARR INV` 共用模式 2 的正 Scharr 像素，在 HDMI 端取反形成白底黑边，
其阈值、NMS 和向右下各 3 像素的框补偿均与模式 2 相同。
模式 8 `MORPH EDGE` 使用第一层 3×3 灰度窗口，
`M=clip(4*(max-min),0,255)`，分别对应灰度膨胀减腐蚀及四倍增强。
它输出灰度 RGB，前两行、前两列填黑，目标框向右下各补偿 1 像素。
新增模式 7/8 不增加行缓存、DSP 或 DDR 图像读写；具体逻辑增量以最终构建为准。
模式 9 输出原始颜色掩码，不作空间偏移；模式 10/11 复用第一层九个二值抽头，
分别作 AND/OR，向右下各补偿 1 像素。模式 12 是多数滤波后的 3×3 闭运算，
与形状判断共用同一结果，向右下各补偿 3 像素。四个掩码像素在末端才扩展为 RGB。
普通小孔、小缺口和轻微边缘抖动有回归覆盖，反复的大缺口仍可能为 `UNK`。
可对照[红绿保色 RTL 预览](../build/verification/color_keep_rtl_preview.png)、
[漫画合成输入](../build/verification/cartoon_synthetic_input.png)和
[漫画 RTL 输出](../build/verification/cartoon_synthetic_rtl.png)，以及
[形态学 RTL 输出](../build/verification/morph_synthetic_rtl.png)；均不是实拍图。
红色和运动检测独立读取 AWB RGB，在所有显示模式中叠加所选检测结果。
模式 1 灰度使用 `(77R+150G+29B+128)>>8`；
Scharr 内部沿用 `(R+2G+B)>>2`。

当前 AWB 可能在有效像素之前给出帧首脉冲，因此模式更新不能要求 `tuser` 与 `tvalid` 同时为 1。请求恰好到达帧首、尚未通过同步器时，会推迟到后续帧生效。新画面还需要经过已有 DDR 缓冲，按键响应不是零延迟。

## 本轮仿真与验证边界

本次形状回归、前版 CNN 移除集成回归与更早的掩码专项结果见
[当前颜色与形状结果及边界](../sim/README.md#当前颜色与形状结果及边界)。
前版 CNN 移除重新验证十三模式 mixer、颜色/形状标签、两项 DDR 帧槽对齐、
ISP 四正方形及清理掩码打包、延迟面板，以及实际 RAW 六帧运动和帧号短帧/回绕。
前版专项包含两种 RAM 模型、720p 四段逐行零消隐、K2 与跨 SOF 结果、原帧桥、
旋转形状与未知图形判定、四框/形状标签 mixer、生产 172,800 字/帧对齐及
去马赛克后 ISP→打包。形状检查入口为 `sim/run_color_shape_target.ps1 -Mode Both`。
ISP 回归在惰性 demosaic 边界注入 RGB/帧号；生产顶层对齐使用外设 stub 与受控接口激励。
它们验证数字逻辑，不替代真实 MIPI/DDR/HDMI 器件和板上摄像头验收。

十三模式检查入口：

```powershell
& './sim/run_display_effect_control.ps1'
& './sim/run_display_effects_rgb888.ps1'
& './sim/run_display_effects_mixer.ps1'
& './sim/run_target_frame_alignment.ps1'
& './sim/run_color_mask_pipeline.ps1' -Mode Both
```

前版十三模式控制器通过 632 项检查，覆盖 K1 三轮十三项循环、消抖、长按、全部复位编码，
K3/K4 忽略和参数固定为零。
像素模块通过 972,815 次独立参考对照与 1,945,630 次时钟边沿外保持检查，
覆盖十三种模式、3 种非法编码、全部 256 个兼容参数值及保色边界向量。
前版 CNN 移除通过十三项名称/mixer 的 40 帧、5,160,960 个像素，
以及 DDR 槽对齐的 36 次写入、读取和显示事件、105 次配置，覆盖全部十三模式。
前版掩码参考使用实际颜色选择器和显示选择器，便携/厂商 RAM 各检查 16 帧，
包含 RED/GRN/BLU/MOV、提前 SOF、帧中配置请求、空拍和固定 11 拍。
逐项结果见 [仿真说明](../sim/README.md#当前颜色与形状结果及边界)。

双击 `sim/run_video_mode.cmd` 运行当前核心算法的 64×48 测试。它先运行按键测试，
再运行 `tb_scharr_edge_detect_96.sv` 的独立图像参考，同时核对 Scharr、浮雕、漫画、形态学和选择器。
720p 命令保持不变：

```bat
sim\run_video_mode.cmd --no-pause 720
```

九模式核心 XSim 回归通过 64×48 的 28 帧（含截断帧）、77,376 像素，
64×49 的 28 帧、78,976 像素，以及
720p 的 22 帧、18,439,680 像素；最终 720p 脚本退出码为 0。
覆盖暗灰度边界、两种斜边、奇偶位置的一像素线、等亮度颜色、均匀图、噪声、
九模式切换、提前帧首、连续帧、空拍、复位与 11 拍对齐。
720p 浮雕核对全部 65,536 组中心/左上灰度组合，
漫画核对 376,150 个黑轮廓像素和 3,372,009 个彩色像素。
形态学核对 1,333,973 个未饱和灰度像素、1,715,746 个饱和像素，
九个位置分别取得极值，并覆盖小灰度差；Scharr 反色选择器核对 921,600 个像素。
成功标志为 `VIDEO_MODE_BUTTON_TEST_PASS`、`SCHARR_EDGE_TEST_PASS`、`EMBOSS_TEST_PASS`、
`CARTOON_TEST_PASS`、`INVERSE_SCHARR_SELECTOR_TEST_PASS`、`MORPHOLOGY_TEST_PASS`，
`result.txt` 为 `PASS`。所有产物写入打印出的 `%TEMP%\anlogic_video_mode_<随机编号>/`。
这些是合成图功能结果，不证明真实暗光画质。

新增 Scharr 反色、形态学 ISP 集成检查分别运行红色检测和运动检测配置：

```powershell
& './sim/run_isp_lighting_integration.ps1' -ScharrInverse
& './sim/run_isp_lighting_integration.ps1' -Motion -ScharrInverse
& './sim/run_isp_lighting_integration.ps1' -Morph
& './sim/run_isp_lighting_integration.ps1' -Motion -Morph
```

四项均以 RGB 注入已知场景，各检查 3 帧、691,200 组 AWB/选择器数据、
518,400 个打包字和 8,294,400 字节；各核对 921,600 个对应像素。
Scharr 反色在 ISP 端仍是正边缘数据，HDMI 取反由像素与 mixer 回归另行验证。
运动配置仍保留 13 拍结果延迟和原有三帧确认策略。此项验证 ISP 选择和打包，
没有模拟真实 MIPI、传感器响应和 DDR 器件。

按键测试将消抖参数缩短为 8 个时钟周期以加速仿真；实际顶层使用 1,000,000 个 50 MHz 周期，即 20 ms。2026-10-02 的历史检查覆盖当时两个真实 TD 工程的源码展开、引脚约束合法性检查和顶层 SDC 读取。



`run_video_mode.cmd` 覆盖按键、Scharr/浮雕/漫画/形态学和选择模块，不覆盖打包模块、
真实摄像头、完整 ISP、DDR/HDMI 联合仿真或板上画面。
原打包模块不支持任意位置的空拍，算法空拍测试不能用于改变打包接口的既有协议。
综合通过也不等于布局布线后的时序通过。

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

- 逐次按 K1，确认 `00 COLOR GAMMA → 01 GRAYSCALE → 02 SCHARR EDGE → 03 NEGATIVE → 04 EMBOSS → 05 COLOR KEEP → 06 CARTOON → 07 SCHARR INV → 08 MORPH EDGE → 09 BINARY → 10 EROSION → 11 DILATION → 12 CLOSE MASK → 00` 循环，且编号与画面一致。
- 检查默认原画有 Gamma，十三项画面与名称相符；K3、K4 单独、长按或同时按下均不应改变显示模式。
- 在浮雕画面中检查平坦墙面为中灰、轮廓有成对明暗边，并检查画面前两行、前两列为中灰。
- 在保色画面放置红、绿、蓝及灰色物体，检查红绿保色，其余变灰；暗色和低饱和色可能不满足颜色门槛。
- 在漫画画面检查彩色色块、减少的色阶和黑色轮廓，核对前六行、前六列填黑，红绿蓝物体仍可区分。
- 在 Scharr 反色画面检查轮廓与模式 02 一致但黑白相反；在形态学画面检查亮边、不同灰度强度以及前两行、前两列填黑。
- 用 K2 换色，检查 09..12 的白色区域随所选颜色变化，腐蚀缩小边缘、膨胀扩大边缘，清理掩码修复小孔；形状标签不随 K1 预览模式改变。
- 逐次按 K2，确认 `RED → GRN → BLU → MOV → RED` 循环；分别用对应颜色静物和运动物体区分四种模式。
- 在红、绿、蓝模式分别放置 2..4 个足够大的对应颜色物体，检查第二帧确认后分别出框、编号跟随，短暂遮挡保持两帧；拥挤、交叉和合并可能交换编号。
- 用填实的正方形、普通三角形和圆形检查 `SQR/TRI/CIR`，在画面平面内旋转正方形和三角形复查；空心、贴边及无法分类的色块应保留颜色框并显示 `UNK`。严重斜拍不作为本版透视恢复能力验收。
- 检查当前颜色的 COUNT 与框数一致；大量碎片导致容量溢出时应显示 OVF 并清框。切到运动后仍只显示一个运动总框。
- 在全部十三项画面分别测试 K2，核对目标框位置及 RED/GRN/BLU/MOV 标签；浮雕、形态学、腐蚀与膨胀各补偿 1 像素，Scharr、Scharr 反色、漫画与清理掩码各补偿 3 像素。
- 长按 K1、K2，确认只触发一次；松开后再按才能再次触发。
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
