# 安路 PH1P35 图像处理工程

**烧录文件固定为 [td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit](td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit)。**
当前源码为 2026-10-17 九模式扩展版，包含原画（含 Gamma）、灰度、Scharr 边缘、
反色、灰度浮雕、红绿保色、彩色漫画、Scharr 反色和形态学边缘，
以及原有运动检测和延迟可视化。九模式回归、综合、布局布线和 bit 生成均已通过，
可在下载器中重新加载上述固定文件烧录。
脚本构建的副本保存于 [firmware/anlogic_edge_osd.bit](firmware/anlogic_edge_osd.bit)，
其文件校验值、构建时间及最终时序见 [脚本构建记录](build/release/release_manifest.json)。

## 使用

1. 修改源码后先完成编译，在下载器中重新加载 `td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit` 后烧录。
   以后修改源码时，在 TD 中打开 [主工程](td_project/anlogic_edge_osd.al) 重新生成，或使用下方脚本。
2. **K1（D5）**单向循环切换显示算法；**K2（A9）**切换红色/帧差运动检测。
3. 上电默认原画加 Gamma，屏幕左上显示编号和名称。**K3（B9）**与 **K4（C7）**保留引脚，无操作。
   模式在摄像头帧首生效，配置随实际 DDR 帧槽传到显示端。
4. 固定摄像头，等待曝光稳定后持续移动物体。运动框连续 3 帧确认，
   停止后保持 2 帧，第 3 帧清除；位置平滑会带来少量跟随延迟。
5. 右上角显示同帧 `TOTAL`、`ISP`、`BUF` 延迟、累计 `MIN/MAX`
   和最近 64 个显示帧的曲线，单位为 ms。无有效记录时显示 `N/A`。
   该读数测量 RAW 输入到 HDMI 输出的板内数字通路，不含传感器曝光及显示器响应。

## 显示算法

| 模式号 | 屏幕名称 | 显示效果 |
|---|---|---|
| 00 | COLOR GAMMA | 原画加原 Gamma 曲线，上电默认 |
| 01 | GRAYSCALE | 灰度 |
| 02 | SCHARR EDGE | 原高斯 → Scharr → NMS 边缘检测 |
| 03 | NEGATIVE | RGB 反色 |
| 04 | EMBOSS | 灰度浮雕，平坦区域中灰，轮廓两侧一亮一暗 |
| 05 | COLOR KEEP | 红色与绿色保留原色，其他区域转灰度 |
| 06 | CARTOON | 彩色高斯平滑、每通道八级色阶与 Scharr 黑轮廓 |
| 07 | SCHARR INV | 原 Scharr 结果反色，白底黑边 |
| 08 | MORPH EDGE | 灰度 3×3 膨胀减腐蚀，四倍增强，黑底亮边 |

K1 按 `00 → 01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 00` 循环；
从默认画面按两次到 Scharr，按四次到浮雕。K3、K4 不改变画面或参数。
此前独立的二值化、量化、亮度、对比度、饱和度、伪彩色和六种邻域显示算法不恢复。
K1、K2 按下、释放消抖均为 20 ms，长按只触发一次。

九种画面互斥选择，前端输出统一为 11 拍，在 HDMI 端共用两拍像素处理。
最终 HDMI 输出仍为三拍；文字、Logo、目标框及延迟面板保持原色。
框坐标按对应画面补偿：Scharr、Scharr 反色和漫画向右下各 3 像素，
浮雕与形态学边缘各 1 像素，其他画面不偏移。

浮雕使用 `E=clip(128+2*(Y中心-Y左上),0,255)`，其中 `Y=(R+2G+B)>>2`。
灰度值差为零时输出中灰 128，正负差形成亮暗轮廓；输出的前两行、前两列填中灰。
它复用 Scharr 第一层灰度 3×3 窗口，不增加 DDR 访问或行缓存；
乘 2 用移位实现。七模式历史版新增漫画彩色行缓存，ERAM/DSP 为 69/13；
新增的模式 07/08 复用已有结果与灰度窗口，不增加行缓存、DSP 或 DDR 图像访问。

红绿保色在 HDMI 端使用通道比例、差值和色相范围筛选红色与绿色，
命中的像素保持输入 RGB，其他像素使用现有灰度公式。
漫画在 CSI 端使用 RGB 各高 5 位构造 3×3 高斯平滑，
量化为每通道 3 位，再与原 Scharr/NMS 黑轮廓合成；前六行、前六列填黑。
漫画增加片上行缓存，不增加 DDR 图像读写次数，也不改变检测分支的原始 RGB 输入。

Scharr 反色在 CSI 端选取原 Scharr 正边缘图，在 HDMI 端按通道取反，
与模式 02 共用原阈值和 NMS。形态学边缘使用
`M=clip(4*(max(3×3灰度)-min(3×3灰度)),0,255)`，不做二值化，
前两行、前两列填黑；它共享浮雕所用的第一层灰度窗口。
这些模式属于图像显示，不会把现有单个检测总框变成多个目标框。
后续多目标分离的[低资源连通区域方案](docs/CONNECTED_COMPONENTS_PLAN.md)仅为设计规划，尚未实现。

合成测试图的[输入图](build/verification/emboss_synthetic_input.png)和
[RTL 浮雕输出](build/verification/emboss_synthetic_rtl.png)可直接对照。
漫画也有[合成输入](build/verification/cartoon_synthetic_input.png)和
[RTL 输出](build/verification/cartoon_synthetic_rtl.png)。
[红绿保色对照图](build/verification/color_keep_rtl_preview.png)可查看保色和灰度区域。
[形态学 RTL 输出](build/verification/morph_synthetic_rtl.png)来自本轮 720p 回归。
预览均为合成测试场景的 RTL 仿真结果；实拍画质仍需烧录后确认。
本轮九模式按键、像素与名称、DDR 帧槽和全部框补偿回归已通过；
720p 独立图像参考核对 22 帧、18,439,680 个像素，
浮雕参考覆盖全部 65,536 组中心/左上灰度组合，形态学覆盖九个极值位置、
低对比灰度差和饱和。完整范围见 [仿真说明](sim/README.md)。
Scharr 反色和形态学在红色、运动两种检测配置下的四项 ISP 集成均通过，
每项检查 3 帧、8,294,400 字节打包数据；Scharr 反色仍在 HDMI 端执行取反。

Gamma 保留在模式 00 的彩色画面，使用 [gamma_lut_rgb888.v](user_source/hdl_source/gamma_lut_rgb888.v)
的原曲线：暗部提亮、中灰保持、亮灰压低，黑白端点保持 0/255。
已经剪白的纹理不能通过此表恢复。其他模式分别处理其输入，不与默认 Gamma 叠加。
后续修改源码或仿真不会自动更新 bit；需要上板验证的新源码按下方流程重新生成。

九模式版 `src-0917069cbe5c` 于 2026-10-17 20:11:21（北京时间）完成综合、布局布线和 bit 生成。
最终 Slice 16,035/21,216（75.58%）、LUT6 14,773、寄存器 13,573、ERAM 69/108、DSP 13/40；
建立余量 +0.128 ns，保持余量 +0.020 ns。相对七模式版增加 789 Slice、796 LUT6、
387 个寄存器，ERAM 和 DSP 不变。221 个生产构建输入与当前文件 SHA256 一致，两处 bit 内容一致；
显示配置跨时钟的 13 ns 约束覆盖全部 4 条有效路径。此构建不含连通区域或多目标框。
资源与最终时序见
[资源报告](build/release/system_phy.area)、[最终时序](build/release/system_pr.timing)
及[构建清单](build/release/release_manifest.json)。
TD 的 `phy_1` 报告仅对应 TD 界面中最近一次编译。Slice、LUT6 和寄存器不能相加计算剩余容量。
仿真入口与验证范围见 [sim/README.md](sim/README.md)，实拍画质和按键体验需重新烧录后确认。

## 修改后生成新 Bit

日常继续在 TD 中编译，成功后使用 `best_result/anlogic_edge_osd.bit`。
外部修改工程文件后，需要重新打开工程，使 TD 加载最新源码列表。
新增延迟功能需要 `video_latency_timebase.v`、`video_latency_monitor.v` 和
`video_latency_osd.v` 三项都登记在工程中。
显示算法需要 `display_effects_rgb888.v`、`display_effect_control.v` 和
`gamma_lut_rgb888.v`，两份 `.al` 已登记。

也可以双击根目录的 [build_firmware.cmd](build_firmware.cmd)，或在 PowerShell 执行：

```powershell
& '.\verification\run_image_quality_build.ps1' -GenerateBit
```

脚本在独立临时目录完成综合、布局布线和 bit 生成，
仅在最终建立/保持时序均通过，且显示配置跨时钟的 13 ns 约束覆盖全部有效路径后更新
`td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit`，
并将同一文件同步到 `firmware/anlogic_edge_osd.bit`，校验 SHA256 一致；
失败时保留上一份成功的 bit。
TD 界面编译更新 `best_result`；脚本构建成功则同步两处。统一使用 `best_result` 主路径烧录。
每次都重新加载本次实际生成的文件后再烧录。

## 目录

| 位置 | 内容 |
|---|---|
| [firmware/](firmware/) | 脚本构建同步的 bit 副本和说明；TD 界面编译不会更新这里 |
| [td_project/anlogic_edge_osd.al](td_project/anlogic_edge_osd.al) | 主 TD 工程，顶层 `design_top_wrapper` |
| [user_source/](user_source/) | HDL、IP、初始化数据和引脚约束 |
| [sim/README.md](sim/README.md) | 仿真入口与验证范围 |
| [verification/](verification/) | TD 构建、工程检查和修复脚本 |
| [docs/](docs/) | 使用、代码导航、诊断、参考资料及开题文档 |
| [build/release/](build/release/) | 当前构建报告、校验清单及压缩验证证据 |
| [build/verification/](build/verification/) | 算法回归的压缩日志和测试源码校验值 |

`td_project` 包含两套工程的 `.al` 和 `.sdc` 文件；
TD 界面编译会在这里生成 `*_Runs` 和 `best_result`。
源码和工程路径保持原位；不要把整个源码目录重复加入 TD。

## 常用说明

- [按键使用与上板检查](docs/VIDEO_MODE_SWITCH.md)
- [代码与配置导航](docs/CODE_MAP.md)
- [低资源多目标连通区域方案（未实现）](docs/CONNECTED_COMPONENTS_PLAN.md)
- [运动检测规则和验证结果](docs/MOTION_DETECTION.md)
- [延迟读数、曲线和验证边界](docs/LATENCY_VISUALIZATION.md)
- [摄像头诊断](docs/SC520CS_TEST.md)、[RAW10 测量](docs/RAW_STATS_GUIDE.md)
- [参考资料导航](docs/参考资料导航.md)、[开题文档](docs/proposals/)、[Git 使用](docs/GITHUB_WORKFLOW.md)

旧版开发过程和实验数字集中到 [开发历史](docs/history/DEVELOPMENT.md)
与 [仿真历史](docs/history/SIMULATION.md)；其中的旧导出路径已停用。
