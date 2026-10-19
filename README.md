# 安路 PH1P35 图像处理工程

**烧录文件固定为 [td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit](td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit)。**
当前源码为 2026-10-19 掩码清理与形状版，包含原画（含 Gamma）、灰度、Scharr 边缘、
反色、灰度浮雕、红绿保色、彩色漫画、Scharr 反色、形态学边缘，
以及所选颜色的二值掩码、腐蚀、膨胀和清理掩码预览，
以及红/绿/蓝所选颜色的最多四个独立框、正方形/三角形/圆形识别、
原有单框运动检测和延迟可视化。固定文件的实际发布身份见构建清单；
烧录前按构建清单核对版本，并在下载器中重新加载上述固定文件。
脚本构建的副本保存于 [firmware/anlogic_edge_osd.bit](firmware/anlogic_edge_osd.bit)，
其文件校验值、构建时间及最终时序见 [脚本构建记录](build/release/release_manifest.json)。

## 使用

1. 修改源码后先完成编译，在下载器中重新加载 `td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit` 后烧录。
   以后修改源码时，在 TD 中打开 [主工程](td_project/anlogic_edge_osd.al) 重新生成，或使用下方脚本。
2. **K1（D5）**单向循环切换显示算法；**K2（A9）**按红色、绿色、蓝色、帧差运动循环。
3. 上电默认原画加 Gamma，屏幕左上显示编号和名称。**K3（B9）**与 **K4（C7）**保留引脚，无操作。
   模式在摄像头帧首生效，配置随实际 DDR 帧槽传到显示端。
4. 固定摄像头，等待曝光稳定后持续移动物体。运动框连续 3 帧确认，
   停止后保持 2 帧，第 3 帧清除；位置平滑会带来少量跟随延迟。
   所选颜色检测最多显示四个框，新目标连续两帧匹配后显示，漏检保持两帧；
   标签例如 `1 GRN TRI OK` / `1 GRN TRI H`，左下显示 `RED/GRN/BLU COUNT:0..4`。
   `SQR/TRI/CIR/UNK` 分别表示正方形、三角形、圆形和未知；
   未知形状仍保留颜色框。形状面向填实、分离的色块，支持画面内旋转，
   未做透视矫正；算法和输入要求见[形状说明](docs/COLOR_SHAPE.md)。
   算法容量溢出时显示 `OVF` 并清框；详见[多目标说明](docs/RED_MULTI_TARGET.md)。
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
| 09 | BINARY | K2 所选颜色的原始二值掩码，命中为白，其他为黑 |
| 10 | EROSION | 原始颜色掩码的 3×3 腐蚀 |
| 11 | DILATION | 原始颜色掩码的 3×3 膨胀 |
| 12 | CLOSE MASK | 3×3 多数滤波 → 3×3 膨胀 → 3×3 腐蚀，与形状输入一致 |

K1 按 `00 → 01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11 → 12 → 00` 循环；
从默认画面按两次到 Scharr，按四次到浮雕。K3、K4 不改变画面或参数。
K1、K2 按下、释放消抖均为 20 ms，长按只触发一次。

十三种画面互斥选择，前端输出统一为 11 拍，在 HDMI 端共用两拍像素处理。
最终 HDMI 输出仍为三拍；文字、Logo、目标框及延迟面板保持原色。
框坐标按对应画面补偿：Scharr、Scharr 反色和漫画向右下各 3 像素，
浮雕、形态学边缘、腐蚀和膨胀各 1 像素，清理掩码各 3 像素，其余不偏移。

模式 09 的二值化按颜色筛选，不是按灰度阈值分割。K2 换色时，
09..12 随之显示红、绿或蓝的掩码；K2 为 MOV 时预览默认红色掩码，检测框仍为运动框。
所有 K1 模式的形状判断都使用同一份清理掩码，不会随预览切到原始或腐蚀结果。
先多数滤波去除孤立噪点，再闭运算修复小孔和小缺口；严重破损仍可能为 `UNK`。

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
这些模式属于图像显示；独立的所选颜色检测分支提供最多四框、形状及跟随编号，
运动分支仍是一个总框。本版采用有限容量的扫描线区域连接，
U 形、环形等复杂区域的空隙内目标仍可能合框，不等于完整 CCL。
实际能力、溢出规则和验证见[多目标说明](docs/RED_MULTI_TARGET.md)；
[完整连通域方案](docs/CONNECTED_COMPONENTS_PLAN.md)保留为后续设计规划。

合成测试图的[输入图](build/verification/emboss_synthetic_input.png)和
[RTL 浮雕输出](build/verification/emboss_synthetic_rtl.png)可直接对照。
漫画也有[合成输入](build/verification/cartoon_synthetic_input.png)和
[RTL 输出](build/verification/cartoon_synthetic_rtl.png)。
[红绿保色对照图](build/verification/color_keep_rtl_preview.png)可查看保色和灰度区域。
[形态学 RTL 输出](build/verification/morph_synthetic_rtl.png)来自本轮 720p 回归。
预览均为合成测试场景的 RTL 仿真结果；实拍画质仍需烧录后确认。
本轮十三模式按键、像素、名称、掩码预览、DDR 帧槽和框补偿回归已通过。
掩码预览使用独立整图参考，覆盖红、绿、蓝、运动、提前帧首、帧中切换请求和空拍，
并核对便携 RAM 与安路 ERAM 两种模型。完整范围与历史 720p 图像参考分列于
[仿真说明](sim/README.md)。
新掩码窗口每像素只存一位，Top4 特征移入既有候选 ERAM 的空余地址，
并去除重复特征寄存器；没有新增 DDR 访问、整帧缓存或独立分类器。

Gamma 保留在模式 00 的彩色画面，使用 [gamma_lut_rgb888.v](user_source/hdl_source/gamma_lut_rgb888.v)
的原曲线：暗部提亮、中灰保持、亮灰压低，黑白端点保持 0/255。
已经剪白的纹理不能通过此表恢复。其他模式分别处理其输入，不与默认 Gamma 叠加。
后续修改源码或仿真不会自动更新 bit；需要上板验证的新源码按下方流程重新生成。

历史红色多目标版 `src-9e019affb36a` 于 2026-10-17 21:44:57（北京时间）完成综合、布局布线和 bit 生成。
最终 Slice 17,483/21,216（82.40%）、LUT6 16,707、寄存器 17,555、ERAM 80/108、DSP 13/40；
建立余量 +0.108 ns，保持余量 +0.020 ns。相对九模式单框历史版增加
1,448 Slice、1,934 LUT6、3,982 个寄存器和 11 个 ERAM，DSP 不变。
两处 bit 内容一致；显示配置 13 ns 和目标元数据 20/20/13 ns 约束均通过全路径覆盖检查。
多目标回归含两种 RAM 模型、720p 四段无行消隐、去马赛克后 ISP、生产 DDR 字数和 HDMI 像素，
其中 ISP 在惰性 demosaic 边界注入 RGB/帧号，生产顶层使用外设 stub 与受控接口激励；
两项均不等于物理摄像头或 DDR/HDMI 器件验证。
该阶段日志及测试源码身份见[多目标证据包](build/verification/red_multi_target_regression.zip)。
上述历史资源不代表当前形状版；当前形状回归见
[多颜色目标说明](docs/RED_MULTI_TARGET.md)和[仿真说明](sim/README.md)。
当前十三模式与掩码清理版 `src-99b844d4d471` 于 2026-10-19 17:25:45（北京时间）
完成综合、最终布局布线和 bit 发布。最终 Slice 19,660/21,216（92.67%）、
LUT6 18,977、寄存器 18,330、ERAM 84/108、DSP 19/40；
建立余量 +0.034 ns、保持余量 +0.020 ns，均无违例。
相对前一形状版 `src-259cc85e48e1`，Slice 减少 370、LUT6 减少 134、
寄存器减少 914，ERAM 增加 2，DSP 不变；Slice 占用由 94.41% 降至 92.67%。
没有增加 DDR 图像读写或整帧缓存。当前剩余 1,556 Slice、24 个 ERAM，
后续扩展仍需关注容量和时序。
227 个源文件与构建清单一致，两处 bit 的 SHA256 均为
`12C57AF945EF7656FFC8998122BB4F21DF527E2DF16EB401239CFA3D1736FD2D`。
资源与最终时序见
[资源报告](build/release/system_phy.area)、[最终时序](build/release/system_pr.timing)
及[构建清单](build/release/release_manifest.json)；本轮日志和源码快照见
[十三模式与掩码回归证据包](build/verification/color_mask_regression.zip)。
TD 的 `phy_1` 报告仅对应 TD 界面中最近一次编译。Slice、LUT6 和寄存器不能相加计算剩余容量。
仿真入口与验证范围见 [sim/README.md](sim/README.md)，实拍画质和按键体验需重新烧录后确认。

## 修改后生成新 Bit

日常继续在 TD 中编译，成功后使用 `best_result/anlogic_edge_osd.bit`。
外部修改工程文件后，需要重新打开工程，使 TD 加载最新源码列表。
新增延迟功能需要 `video_latency_timebase.v`、`video_latency_monitor.v` 和
`video_latency_osd.v` 三项都登记在工程中。
显示算法需要 `display_effects_rgb888.v`、`display_effect_control.v` 和
`gamma_lut_rgb888.v`，多目标帧对应需要 `target_frame_bridge.v`，两份 `.al` 已登记。

也可以双击根目录的 [build_firmware.cmd](build_firmware.cmd)，或在 PowerShell 执行：

```powershell
& '.\verification\run_image_quality_build.ps1' -GenerateBit
```

脚本在独立临时目录完成综合、布局布线和 bit 生成，
仅在最终建立/保持时序均通过，且显示配置 13 ns、目标元数据 20/20/13 ns
约束覆盖全部有效路径后更新
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
- [红色多目标、跟随标签与验证](docs/RED_MULTI_TARGET.md)
- [完整连通域后续方案](docs/CONNECTED_COMPONENTS_PLAN.md)
- [运动检测规则和验证结果](docs/MOTION_DETECTION.md)
- [延迟读数、曲线和验证边界](docs/LATENCY_VISUALIZATION.md)
- [摄像头诊断](docs/SC520CS_TEST.md)、[RAW10 测量](docs/RAW_STATS_GUIDE.md)
- [参考资料导航](docs/参考资料导航.md)、[开题文档](docs/proposals/)、[Git 使用](docs/GITHUB_WORKFLOW.md)

旧版开发过程和实验数字集中到 [开发历史](docs/history/DEVELOPMENT.md)
与 [仿真历史](docs/history/SIMULATION.md)；其中的旧导出路径已停用。
