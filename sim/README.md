# 仿真入口

以下命令均在项目根目录执行。测试会将编译产物和日志写到打印出的 TEMP 目录，
测试台与脚本留在本目录，不生成或更新 `firmware` 中的烧录文件。
CNN 厂商模型测试将向量和日志写入 `tmp/cnn_*`；同样只运行仿真。

## 常用检查

| 内容 | 命令 |
|---|---|
| CNN 安路真实 RAM、独立数值参考、逐层张量和来帧保护 | `& './sim/run_cnn_fixed_reference.ps1'` |
| CNN 实际裁剪框、五类标签、旧结果超时与显示同步 | `& './sim/run_cnn_display_status.ps1'` |
| CNN 两种地址生成实现逐拍一致性（同步读行为模型） | `& './sim/run_cnn_infer_32.ps1'` |
| 原画 Gamma、灰度、反色、红绿保色、Scharr 取反、空间效果直通与两拍延迟 | `& './sim/run_display_effects_rgb888.ps1'` |
| K1 消抖、十三模式单向循环、K3/K4 忽略和参数恒零 | `& './sim/run_display_effect_control.ps1'` |
| 十三项名称、旧参数区清除与 HDMI 帧首配置 | `& './sim/run_display_effects_mixer.ps1'` |
| 配置邮箱全部 12 位值、复位默认和异步时钟 | `& './sim/run_camera_diag_cdc.ps1'` |
| 固定色调查表、RGB 独立地址和禁用时序 | `& './sim/run_gamma_lut_rgb888.ps1'` |
| 延迟时基、同帧元数据与生产 DDR 字数边界 | `& './sim/run_video_latency.ps1'` |
| 真实 ISP 帧号、短帧恢复与回绕 | `& './sim/run_video_latency_frame_tag.ps1'` |
| 延迟数字、64 帧曲线与完整 HDMI 像素 | `& './sim/run_video_latency_osd.ps1'` |
| DDR 帧槽、显示配置及红色/运动框对应 | `& './sim/run_target_frame_alignment.ps1'` |
| 红色多目标检测：便携/真实安路 RAM | `& './sim/run_red_multi_target.ps1' -Mode Both` |
| 红色多目标 720p、四段逐行零消隐 | `& './sim/run_red_multi_target.ps1' -Mode Portable -Width 1280 -Height 720` |
| 所选颜色的正方形/三角形/圆形：便携/真实安路 RAM | `& './sim/run_color_shape_target.ps1' -Mode Both` |
| 720p 形状、高坐标矩和投影范围 | `& './sim/run_color_shape_target.ps1' -Mode Portable -Width 1280 -Height 720 -TimeoutSeconds 900` |
| 红/绿/蓝掩码与黄绿、青绿及拒绝颜色边界 | `& './sim/run_color_target_modes.ps1'` |
| 所选颜色的二值化、腐蚀、膨胀及降噪闭运算预览：两种 RAM、独立图像参考 | `& './sim/run_color_mask_pipeline.ps1' -Mode Both` |
| 720p 独立掩码参考：红色的四种预览逐像素比较 | `& './sim/run_color_mask_pipeline.ps1' -Mode Portable -Width 1280 -Height 720 -ColorCount 1 -TimeoutSeconds 600` |
| 共享比较器优化前后的所有 RGB、颜色模式和参数等价性 | `& './verification/check_color_mask_equivalence.ps1'` |
| 多目标/真实运动选择、跨 SOF 原帧身份 | `& './sim/run_red_multi_switch.ps1' -Mode Both` |
| 帧身份、实际 DDR 槽、形状元数据及读冻结桥 | `& './sim/run_target_frame_bridge.ps1'` |
| 四框、颜色/形状标签、紧凑退化及固定 OSD 优先 | `& './sim/run_multi_target_mixer.ps1'` |
| 多目标生产顶层、颜色/形状绑定、172800 字/帧及框补偿 | `& './sim/run_red_multi_frame_alignment.ps1'` |
| 去马赛克后 RGB 注入→AWB→四个正方形→DDR 打包 | `& './sim/run_isp_red_multi.ps1'` |
| 运动稳定性：生产参数、两种 RAM 模型 | `& './sim/run_motion_stability.ps1' -Pipeline Stable -Mode Both -CheckBehavior` |
| 三帧确认、短暂保持、平滑和复位 | `& './sim/run_motion_result_stabilizer.ps1'` |
| 真实 RAW 全链路六帧、连续 4 像素右移 | `& './sim/run_isp_motion_camera.ps1' -LineBlanking 32 -MovePixels 4` |
| 运动分支与 ISP 打包 | `& './sim/run_isp_lighting_integration.ps1' -Motion` |
| 红色分支与 ISP 打包 | `& './sim/run_isp_lighting_integration.ps1'` |
| 浮雕选择与 ISP 打包：红色检测配置 | `& './sim/run_isp_lighting_integration.ps1' -Emboss` |
| 浮雕选择与 ISP 打包：运动检测配置 | `& './sim/run_isp_lighting_integration.ps1' -Motion -Emboss` |
| 漫画选择与 ISP 打包：红色检测配置 | `& './sim/run_isp_lighting_integration.ps1' -Cartoon` |
| 漫画选择与 ISP 打包：运动检测配置 | `& './sim/run_isp_lighting_integration.ps1' -Motion -Cartoon` |
| Scharr 反色选择与 ISP 打包：红色检测配置 | `& './sim/run_isp_lighting_integration.ps1' -ScharrInverse` |
| Scharr 反色选择与 ISP 打包：运动检测配置 | `& './sim/run_isp_lighting_integration.ps1' -Motion -ScharrInverse` |
| 形态学选择与 ISP 打包：红色检测配置 | `& './sim/run_isp_lighting_integration.ps1' -Morph` |
| 形态学选择与 ISP 打包：运动检测配置 | `& './sim/run_isp_lighting_integration.ps1' -Motion -Morph` |
| 颜色二值掩码、真实 AWB 及 ISP 打包 | `& './sim/run_isp_lighting_integration.ps1' -Binary` |
| 颜色掩码腐蚀、真实 AWB 及 ISP 打包 | `& './sim/run_isp_lighting_integration.ps1' -Erosion` |
| 颜色掩码膨胀、真实 AWB 及 ISP 打包 | `& './sim/run_isp_lighting_integration.ps1' -Dilation` |
| 降噪后闭运算掩码、真实 AWB 及 ISP 打包 | `& './sim/run_isp_lighting_integration.ps1' -CloseMask` |
| 运动检测下的掩码预览及 ISP 打包 | `& './sim/run_isp_lighting_integration.ps1' -Motion -CloseMask` |
| 原始帧差与模式选择器 | `& './sim/run_motion_target_detect.ps1' -Mode Both` |
| 原始帧差慢移图像参考 | `& './sim/run_motion_realistic.ps1' -RequireDetections` |
| 自动曝光、RAW 统计和闭环 | `& './sim/run_auto_exposure.ps1'` |
| 白平衡与连续行尾 | `& './sim/run_awb_frame_adaptation.ps1'` |
| RAW 解包和去马赛克 | `& './sim/run_demosaic_quality.ps1' -CsiSource -Width 1280 -Height 720` |
| FIFO 图像完整性 | `& './sim/run_video_fifo_frame_integrity.ps1' -RawSource` |
| RAW10 分区统计与 HDMI 数字表 | `& './sim/run_raw_stats.ps1'` |
| 红色检测照明场景 | `& './sim/run_red_target_lighting.ps1'` |

CNN 的尺度说明、验证范围及此前 99.2% 指标的纠正见
[CNN 修正与验证](../docs/CNN_VALIDATION.md)。

按键、Scharr/浮雕/漫画/形态学和显示切换：

```powershell
.\sim\run_video_mode.cmd --no-pause 720
```

摄像头 I2C 配置：

```powershell
.\sim\run_sc520.cmd --no-pause
```

## 当前颜色与形状结果及边界

生产顶层默认 `RED_MULTI_ENABLE=1`。红/绿/蓝分支复用同一套全分辨率颜色掩码，
先进行 3×3 多数滤波，再进行 3×3 膨胀和 3×3 腐蚀组成的闭运算，
修补小高光孔洞和轻微边缘毛刺。三个窗口只缓存二值行，共用形状检测和预览通路，
不增加整帧 DDR 图像读写。
使用行程段、64 深度 FIFO、16 项活动候选和最大四候选选择，
再由共享形状描述器分类、四轨迹完成两帧确认、两帧保持及跟随编号。
形状描述结合区域面积、Q3 近似轮廓周长、投影跨度与一阶矩，
在四个候选之间串行复用，不增加整帧边缘图或透视矫正。
支持实心正方形、三角形和圆形；不确定区域保留框并标为 `UNK`，
长方形、椭圆、大孔环形、分叉和截边区域有 `UNK` 用例覆盖。
白色五点高光、2×3/3×2 灰色小孔、±1 像素边界抖动及少量宽 2、深 1 像素浅缺口有正例；
四边反复出现的密集宽 3 像素、深 1/2/3 像素凹口保留 `UNK` 负例，
宽 2、深 2 像素的边缘缺口仍可能产生 `UNK`；内孔修补范围不能直接当作边口修复范围。
未扩大窗口或放宽三角形保护。小圆及带半像素中心的 12..14 像素小正方形
另有正例，覆盖小尺寸、45° 旋转、高填充及栅格化周长边界。
这部分测试将候选面积门槛设为 64 以检查分类边界；生产门槛仍为 128，
不保证所有 12..14 像素目标都能被检出。约 20 像素的小圆叠加边缘噪声后仍可能被判为 `SQR`；
小尺寸、噪声和栅格采样共同限制了形状区分能力，不能将干净小圆正例推广到所有噪声场景。
青绿色正例使用 `RGB=(32,150,120)`，包含绿色阈值的等号边界；
`RGB=(32,150,144)` 不满足绿色饱和度门槛，另保留实际 RGB 拒绝用例。
这些回归通过实际 RGB 阈值路径，未直接强制内部掩码或形状统计量。
图像平面内旋转有回归覆盖，明显透视变形仍可能降为 `UNK`。
FIFO 或候选表溢出令整帧无效、清轨迹并显示 `OVF`，不会退回原单总框。
运动分支仍为单个总框和原三帧确认策略，K2 在摄像头帧首按红/绿/蓝/运动循环。
K1 单向循环 0..12：原九项保留，9 为所选颜色二值掩码、10 为掩码腐蚀、
11 为掩码膨胀、12 为降噪后的闭运算掩码。9/10/11 从原始所选颜色掩码生成；
12 显示形状判断实际使用的多数滤波→膨胀→腐蚀结果。
所有 K1 模式都运行相同的形状判断链，K1 只选择画面。K2 仍保留红/绿/蓝/运动。
预览与原像素、帧首、行尾和完整配置统一保持 11 拍；
10/11 的框向右下各补偿 1 像素，12 各补偿 3 像素，9 无补偿。
旧单框颜色结果为 9 拍，真实 ISP 集成测试观测为 10 拍；运动结果仍为 13 拍。

每个轨迹使用两位形状码：`00 UNK`、`01 SQR`、`10 TRI`、`11 CIR`；
四槽打包为 `O_multi_shapes[7:0]`，槽 0 位于 `[1:0]`。
完整跟随标签如 `1 RED SQR OK`、`1 GRN TRI H`、`1 BLU CIR OK`，
空间不足时使用 `1 SQR OK` / `1 TRI H`，仍避开固定 OSD 和其他标签。
运动标签继续使用 `1 MOV OK`，紧凑形式为 `1 OK`。
框、形状、保持位和所选颜色绑定同一来源帧及 DDR 槽，显示帧内保持不变；
漏检保持时保留原形状，K2 切换时一起清除。

本版不是完整 CCL：候选每行只保留一个合并区间，
U 形、环形空隙内的独立目标可能被合并；四像素拍内部也有合段近似。
最近邻关联在目标交叉、合并或快速移动时可能换号或重建轨迹。
具体操作、容量、标签和帧对应见 [红色多目标说明](../docs/RED_MULTI_TARGET.md)。

下表列出本轮掩码清理与十三模式更新已运行的检查。未列为本次结果的历史回归不能视为已用当前源码复跑。
日志和测试源码快照位于各脚本打印的 TEMP 目录。
本轮日志、实际执行源码快照、校验值和最终发布报告见
[十三模式与掩码回归证据包](../build/verification/color_mask_regression.zip)。
此前[颜色与形状回归证据包](../build/verification/color_shape_regression.zip)
属于 `src-259cc85e48e1` 历史基线。新包保留各次快照的真实哈希，
前期显示控制测试中未涉及的检测器文件可能早于最终版，不能将所有测试快照视为同一份源码。

| 本次入口 | 结果与覆盖 |
|---|---|
| `run_display_effect_control.ps1` | 632 项；十三模式、全部 16 个默认编码、三轮 K1 循环、消抖/长按及 K3/K4 忽略 |
| `run_display_effects_rgb888.ps1` | 972,815 次逐像素对照、1,945,630 次边沿外保持；十三模式、3 个非法值、256 个参数及原 Gamma |
| `run_display_effects_mixer.ps1` | 40 帧、5,160,960 像素；十三项名称、153,600 个标签区像素、全部模式的目标/OSD 覆盖；颜色目标兼容用例另核对 7,372,800 像素 |
| `run_color_mask_pipeline.ps1 -Mode Both` | 两种 RAM 各 16 帧、49,152 像素、14,990 拍；红/绿/蓝/运动×四种掩码预览，独立二维参考、8 次提前 SOF、16 次帧中 K1/K2 请求及 2,702 空拍 |
| 同脚本 `-Mode Portable -Width 1280 -Height 720 -ColorCount 1` | 红色的四种预览共 4 帧、3,686,400 像素、1,009,810 拍；2 次提前 SOF、4 次帧中 K1/K2 请求、88,210 空拍及 27,667 个清理变化像素 |
| `run_color_shape_target.ps1 -Mode Both` | 两种 RAM 各 96 个结果、194 项检查；30 个真实 RGB 小孔/边噪/小几何用例、十三种 K1 配置、三色及青绿色饱和度边界与拒绝用例 |
| 同脚本 `-Mode Portable -Width 1280 -Height 720` | 98 个结果、200 项检查；包含上述 30 个用例及生产分辨率高坐标三种形状、矩与投影范围 |
| `run_red_multi_target.ps1 -Mode Both` | 两种 RAM 各 30 个结果、50 项检查；四目标、排序、保持、FIFO 高水位 63 及溢出保护 |
| `run_red_multi_switch.ps1 -Mode Both` | 两种 RAM 各 18 个结果、28 项检查；3 次跨 SOF 切换、11 个原始运动检测器结果及模式清理 |
| `run_motion_target_detect.ps1 -Mode Both` | 两种 RAM 的原始运动各 41 帧、旧模式切换 6 项、跨 SOF 3 项、720p 4 帧；保留运动分支时序与结果 |
| `run_target_frame_bridge.ps1` | 30 项；形状与颜色完整元组跨时钟，9 项位移/裁切场景，含模式 9..12、回绕/繁忙/冻结/碰撞及生产字数 |
| `run_target_frame_alignment.ps1` | 36 次写/读/显示、34 次结果、105 次配置；全部十三模式、提前请求与新模式边界裁切 |
| `run_red_multi_frame_alignment.ps1` | 写入 23、读取/显示各 19，四框帧 14、运动 2；几何/形状各 58、绿色 6、蓝色 4；含模式 9..12、短帧/迟到/回滚/冻结及每帧 172,800 字 |
| `run_isp_lighting_integration.ps1 -Binary/-Erosion/-Dilation/-CloseMask` 分别执行 | 每项 3 帧、AWB/选择器各 691,200 组、518,400 个打包字、8,294,400 字节、3 次曝光/目标结果及 921,600 个掩码像素；AWB 后独立图像参考包含小高光孔 |
| 同脚本 `-Motion -CloseMask` | 同样 3 帧和打包字数；运动结果时序仍为 13 拍，灰色运动场景的颜色掩码为全黑 |

成功标志包括 `COLOR_MASK_PIPELINE_PASS`、`COLOR_SHAPE_TARGET_PASS`、`COLOR_TARGET_MODES_PASS`、
`TARGET_FRAME_BRIDGE_PASS`、`MULTI_TARGET_MIXER_PASS`、
`RED_MULTI_FRAME_ALIGNMENT_PASS` 和 `ISP_RED_MULTI_PASS`。

颜色阈值共享 max/min 比较器后的独立 C# 穷举入口为
`verification/check_color_mask_equivalence.ps1`，共比较 167,772,160 个 RGB/分支/参数组合；
它只证明阈值重写前后等价，不能替代实物在光照、AWB 和饱和裁切下的颜色验收。

形状类别、真实 RGB 小孔/毛刺与矩范围由 `run_color_shape_target.ps1` 核对。
零行消隐四矩形场景也不代表任意高段密度图案均不溢出。
真实 RAW 运动全链路 `run_isp_motion_camera.ps1`、帧号 `run_video_latency_frame_tag.ps1`
的历史数字不能直接作为本轮通过记录；显示效果 mixer 的本轮结果为上表 40 帧。

`run_isp_red_multi.ps1` 使用惰性 demosaic 模块边界，在其输出注入 RGB、时序与帧号；
AWB、检测、显示选择/延迟和打包使用生产 RTL，不验证 RAW 解包和去马赛克算法。
`run_red_multi_frame_alignment.ps1` 使用生产系统顶层与外设 stub，
注入 ISP 结果、DDR 写字及显示接口，验证帧/槽/框/颜色/形状对应，不模拟物理 MIPI、DDR 或 HDMI 器件。

帧号随排队任务和结果传递，不用下一帧 SOF 的当前模式替代。
实际 DDR 槽绑定 10 位帧号、16 位 nonce 和模式；只对完整 172,800 字图像发布有效槽记录。
四槽形状码共 8 位，与框和保持位一起传输；运动结果的形状码为零。
读槽选择冻结元数据，HDMI 帧首提交并保持整帧。
约束为帧上下文 20 ns、检测结果 20 ns、读快照 13 ns，
显示配置系统→CSI 邮箱另外为 13 ns。当前发布三组目标路径分别
6,216/2,312/257 条、显示配置 4 条，均通过覆盖检查，没有无效约束或无路径约束。

当前十三模式与掩码清理版 `src-99b844d4d471` 于 2026-10-19 17:25:45（北京时间）
完成最终布局布线和 bit 发布：Slice 19,660/21,216（92.67%）、LUT6 18,977、
寄存器 18,330、ERAM 84/108、DSP 19/40，建立/保持余量 +0.034/+0.020 ns。
相对前一形状版减少 370 Slice、134 LUT6、914 个寄存器，ERAM 增加 2，DSP 不变。
227 个生产输入与当前工作区及构建清单一致，两份 bit SHA256 均为
`12C57AF945EF7656FFC8998122BB4F21DF527E2DF16EB401239CFA3D1736FD2D`；
最终资源、时序与烧录文件身份见 [发布清单](../build/release/release_manifest.json)。
这些验证没有替代真实摄像头、真实 DDR 器件或板上 HDMI 的最终验收。

## 九模式验证基线（历史）

以下属于加入多目标前的 `src-0917069cbe5c`。
显示算法保留，但下述旧单框 mixer/对齐结果及资源不能代替本轮多目标回归。
本节及后续历史节未列入上表的测试没有因本次形状更新而重新运行；
历史证据包也不能作为本次形状源码的通过记录。

该历史版九种画面为 0 原画加原 Gamma、1 灰度、2 原 Scharr 边缘、3 反色、
4 灰度浮雕、5 红绿保色、6 彩色漫画、7 Scharr 反色和 8 形态学边缘。
K1 单向循环 0..8，K3/K4 无操作，K2 仍切换红色/运动检测。
模式 2/7 在 CSI 侧选择原 Scharr，4 选择浮雕，6 选择漫画，8 选择形态学，
其他模式输出延迟 RGB。HDMI 完成 Gamma、灰度、反色、红绿保色或模式 7 取反，
Scharr/浮雕/漫画/形态学直通；
前端统一 11 拍，像素处理固定两拍，最终 mixer 输出保持三拍。
浮雕参考公式为 `E=clip(128+2*(Y中心-Y左上),0,255)`，`Y=(R+2G+B)>>2`；
前两行、前两列输出中灰 128，浮雕目标框向右下各补偿 1 像素。
红绿保色在符合通道差值、比例和色相条件时保留 RGB，其他使用现有灰度公式。
漫画以 RGB 各高 5 位做 3×3 高斯平滑，量化至每通道 3 位并扩展回 RGB888，
再叠加原 Scharr/NMS 黑轮廓；前六行、前六列填黑。
其颜色和轮廓同向右下偏移各 3 像素，目标框使用相同补偿。
漫画新增片上行缓存，不增加 DDR 图像读写次数。

模式 7 与原 Scharr 共用阈值和 NMS，在 HDMI 端取反；目标框各向右下补偿 3 像素。
模式 8 计算第一层灰度 3×3 窗口的 `clip(4*(max-min),0,255)`，
前两行、前两列填黑，目标框各向右下补偿 1 像素。
新增模式 7/8 不增加行缓存、DSP 或 DDR 图像读写。
兼容信号 `O_edge_mode` 仍只在模式 2 置位，选择器使用完整模式配置。

该历史版九模式控制器通过 468 项检查，覆盖全部 16 个复位编码、K1 三轮九项单向循环、
按下/释放消抖、长按、K3/K4 忽略和参数恒零。
逐像素模块通过 709,647 次独立参考对照和 1,419,294 次时钟边沿外保持检查，
覆盖九模式、7 个非法编码、全部 256 个兼容参数及原 Gamma 曲线。
保色边界仍覆盖 109,228 个向量，保红/保绿/拒绝分支计数分别为 42,678/42,476/90,384；
这些计数的统计范围不同，不能相加当作向量总数。
名称/mixer 检查通过 28 帧、3,612,672 个像素，含 107,520 个标签区像素及
18 帧参数忽略；原目标框 mixer 另通过 7,372,800 个像素。
DDR 对齐通过 32 次写入、读取和显示事件、30 次结果及 93 次配置，
覆盖全部模式，含浮雕 2 次、Scharr 2 次、漫画 2 次、反色 Scharr 1 次、形态学 1 次边界裁剪。

核心独立整数图像参考通过 64×48 的 28 帧/77,376 像素、
64×49 的 28 帧/78,976 像素，以及关闭 Scharr 高斯时的 28 帧/77,376 像素。
720p 回归通过 22 帧/18,439,680 像素，运行 5,037,905 个周期和 427,882 次空拍，
最终脚本退出码为 0。覆盖全部九模式、提前帧首、连续帧、截断帧恢复、复位和固定 11 拍。
浮雕仍核对全部 65,536 组中心/左上灰度组合；
漫画核对 376,150 个黑轮廓像素和 3,372,009 个彩色像素；
反色 Scharr 选择器核对 921,600 个正边缘像素，ISP 内取反数为 0。
形态学核对 15,389,961 个零值、1,715,746 个饱和和 1,333,973 个未饱和像素，
覆盖 2,872 个小灰度差样本、全部九个极值位置和 3,690,240 个选择器像素。
成功标志包括 `SCHARR_EDGE_TEST_PASS`、`EMBOSS_TEST_PASS`、`CARTOON_TEST_PASS`、
`INVERSE_SCHARR_SELECTOR_TEST_PASS` 和 `MORPHOLOGY_TEST_PASS`。

新增四项 ISP 回归为 `-Morph`、`-Motion -Morph`、`-ScharrInverse` 和
`-Motion -ScharrInverse`，各通过 3 帧、691,200 组 AWB/选择器数据、
518,400 个打包字、8,294,400 字节、3 次曝光统计、3 次目标结果和 921,600 个效果像素。
形态学红色配置的黑/白/中间灰像素为 919,524/1,244/832，
运动配置为 920,480/1,120/0；反色 Scharr 的 ISP 输出仍为正边缘，
红色配置黑/白为 920,987/613，运动配置为 921,044/556。
HDMI 取反由像素和 mixer 回归核对。运动结果保持 13 拍延迟，
三帧输入只有两次运动候选，尚未满足连续三次确认，公开结果未确认符合原策略。
这四项采用 RGB 注入，不模拟真实 MIPI、传感器响应或 DDR 器件。

可对照[浮雕输入](../build/verification/emboss_synthetic_input.png)与
[RTL 浮雕输出](../build/verification/emboss_synthetic_rtl.png)、
[漫画输入](../build/verification/cartoon_synthetic_input.png)与
[RTL 漫画输出](../build/verification/cartoon_synthetic_rtl.png)、
[红绿保色预览](../build/verification/color_keep_rtl_preview.png)，以及
[本轮 720p 形态学输出](../build/verification/morph_synthetic_rtl.png)。
这些均为合成场景的 RTL 仿真结果，实拍画质和按键体验仍须重新烧录确认。

九模式版 `src-0917069cbe5c` 于 2026-10-17 20:11:21（北京时间）完成 bit 生成。
最终 Slice 16,035/21,216（75.58%）、LUT6 14,773、寄存器 13,573、ERAM 69、DSP 13；
建立/保持余量 +0.128/+0.020 ns，13 ns 配置约束覆盖全部 4 条有效路径。
当时 221 个生产构建输入与当时文件 SHA256 一致，两处 bit 内容一致。
固定发布清单随成功构建更新，不能用于核对这一历史身份。
该版 12 套运行（控制、像素、mixer、对齐、4 套核心图像和 4 套 ISP）的日志、
源码校验值及合成预览见[算法回归证据包](../build/verification/algorithm_regression.zip)；
以前各版结果单独作为历史保存，不算作本轮多目标已重跑。
该历史 bit 不含多目标；当前源码的实际实现与形状版构建状态见上节，
原[完整连通域方案](../docs/CONNECTED_COMPONENTS_PLAN.md)继续作为后续规划。

## 七模式验证基线（历史）

以下属于新增模式 7/8 前的七模式版 `src-2c7e7b44c9ac`，不能代替当前九模式回归。
当时七模式控制器通过 386 项检查，覆盖全部 16 个复位编码、K1 三轮七项单向循环、
按下/释放消抖、长按、K3/K4 单独或同时按下忽略，以及兼容参数恒零。
逐像素模块通过 578,063 次独立参考对照和 1,156,126 次时钟边沿外保持检查，
覆盖七模式、9 个非法编码、全部 256 个兼容参数值及原 Gamma 曲线。
其中含 109,228 个保色边界向量，保红 42,678 次、保绿 42,476 次、拒绝保色 90,384 次；
边界向量数与这些分支计数的统计范围不同，不能直接相加。
名称/mixer 检查通过 22 帧、2,838,528 个像素，核对 84,480 个标签区像素和
14 帧参数忽略；保留原 OSD、目标框和最终三拍时序。
DDR 槽对齐检查通过 30 次写入、读取和显示事件，核对 28 次结果、87 次配置和七项模式；
裁剪检查为浮雕 2 次、Scharr 1 次、漫画 2 次。

Scharr/浮雕/漫画独立图像参考通过 64×48 的 22 帧/61,824 像素、
64×49 的 22 帧/63,104 像素，以及关闭 Scharr 高斯时的 22 帧/61,824 像素。
最终 1280×720 回归通过 16 帧/13,827,840 像素，运行 3,720,337 个周期和
263,312 次空拍，覆盖七项模式、提前帧首、连续帧、截断帧恢复、复位与固定 11 拍。
浮雕仍核对全部 65,536 组灰度组合；漫画核对 26,045 个黑轮廓像素及
2,868,556 个彩色像素，颜色与原轮廓分别由整数图像参考计算。
成功标志包括 `SCHARR_EDGE_TEST_PASS`、`EMBOSS_TEST_PASS` 和 `CARTOON_TEST_PASS`。

漫画 ISP→DDR 打包在红色和运动两种检测配置下均通过，
各检查 3 帧、921,600 个漫画像素、8,294,400 字节、3 次曝光统计和 3 次目标结果。
红色配置含 889,771 个彩色像素及 12,577 个黑像素，运动配置含 12,520 个黑像素。
运动结果仍保持 13 拍延迟，三帧场景未满足连续三次运动候选，公开结果未确认符合原策略。
此项采用 RGB 注入，不模拟真实 MIPI、传感器响应或 DDR 器件。

可对照[漫画合成输入](../build/verification/cartoon_synthetic_input.png)与
[漫画 RTL 输出](../build/verification/cartoon_synthetic_rtl.png)，以及
[红绿保色 RTL 预览](../build/verification/color_keep_rtl_preview.png)。
这些是合成测试场景与 RTL 结果，真实摄像头画质和板上体验须重新烧录确认。
七模式 `src-2c7e7b44c9ac` 于 2026-10-17 19:28:37（北京时间）完成 bit 生成。
最终 Slice 15,246、LUT6 13,977、寄存器 13,186、ERAM 69、DSP 13；
建立/保持余量 +0.122/+0.020 ns，13 ns 配置约束覆盖全部 3 条有效路径。
当时 221 个生产构建输入与当时文件 SHA256 一致，两处 bit 内容一致；
该版构建身份保存在当前证据包内的 `history/seven_mode_algorithm_regression.zip`。
该次 13 套运行（控制、像素、mixer、对齐、4 套核心图像、4 套 ISP 和保色预览）
的日志、源码校验值与合成预览归档于
[算法回归证据包](../build/verification/algorithm_regression.zip)。
固定发布清单和证据包随当前版本更新；七模式结果作为历史保存，不算作本轮九模式已重跑结果。

## 五模式浮雕验证基线（历史）

以下属于七模式扩展前的五模式版 `src-b81e1a687c70`。
当时控制器通过 238 项检查，覆盖五项正反循环、复位编码、消抖、长按、
同时按下优先级、K4 忽略和参数恒零。
像素模块通过 337,251 次独立参考对照和 674,502 次时钟边沿外保持检查，
覆盖五模式、11 个非法模式、全部 256 个兼容参数值和复位首拍。
五项名称/mixer 回归通过 16 帧、2,064,384 个像素，原目标框 mixer 另通过
7,372,800 个像素。Gamma 表和曲线保持原值。
实际 DDR 槽对齐通过 30 次写帧、读帧和显示事件，覆盖全部五种显示模式；
浮雕边界裁剪检查 2 次，Scharr 边界裁剪检查 1 次。

Scharr/浮雕独立图像参考通过 64×48 的 19 帧/55,488 像素，
64×49 的 19 帧/56,640 像素，以及 1280×720 的 13 帧/11,980,800 像素。
720p 脚本退出码为 0，共 3,192,733 个时钟周期和 197,484 次空拍；
浮雕参考核对全部 65,536 组中心/左上灰度组合，覆盖负差、正差、中灰和两端饱和，
其中饱和暗像素 132,410 个、饱和亮像素 132,201 个、中灰像素 11,383,044 个。
逐拍检查同时覆盖提前帧首、有效空拍、连续帧、截断帧恢复、复位和固定 11 拍输出。

可直接对照[合成输入 PNG](../build/verification/emboss_synthetic_input.png)和
[RTL 浮雕输出 PNG](../build/verification/emboss_synthetic_rtl.png)。
这两张图来自五模式合成测试场景及 RTL 仿真，不是实物摄像头采集，
不能作为实拍画质和板上按键体验的验证结果。
新增浮雕的 ISP→DDR 打包集成检查在红色和运动两种检测配置下均通过，
各检查 3 帧、691,200 组 AWB/选择器数据、518,400 个打包字和 8,294,400 字节，
并核对 3 次曝光统计、3 次目标结果及 921,600 个浮雕像素。
红色配置覆盖亮/暗/中灰像素 207/414/920,979 个，运动配置为 279/279/921,042 个，
两项均覆盖上下限饱和。运动结果保持原有 13 拍延迟，三帧场景尚不满足连续三次运动候选，
因此公开目标结果均未确认，符合原稳定策略。该检查用 RGB 注入，不替代真实 RAW/MIPI 验证。

五模式浮雕版 `src-b81e1a687c70` 于 2026-10-17 18:44:37（北京时间）完成 bit 生成，
最终建立/保持余量 +0.117/+0.020 ns，13 ns 配置约束覆盖全部 3 条有效路径。
当时 221 个构建输入 SHA256 与工作区一致，两处 bit 内容一致。固定路径的
[发布清单](../build/release/release_manifest.json) 随后续成功构建更新，不能用于核对历史身份。
当时 10 套回归的日志、源码校验值和预览集中在
[算法回归证据包](../build/verification/algorithm_regression.zip)，
包内此前 17 套测试结果单独作为历史保留，不算作本次已重跑结果。

## 四模式验证基线（历史）

以下数字属于加入浮雕前的四模式版 `src-5465baecfd7a`，不能代替当前九模式回归。
2026-10-17 控制器通过 227 项检查，覆盖全部 16 种复位参数编码、
四项正反向循环、消抖、长按、同时按下优先级、K4 忽略和输出参数恒零。
逐像素处理通过 271,459 组独立参考对照和 542,918 次时钟边沿外保持检查，
覆盖 65,536 组 R/G 输入、12 个非法模式、全部 256 个兼容参数值以及复位首拍。
四模式名称/mixer 回归通过 13 帧、1,677,312 个像素，核对四个名称、
49,920 个标签区像素、23,296 个旧参数区像素，以及原 OSD、目标框和三拍时序。
原目标框 mixer 回归另通过 7,372,800 个像素。Gamma 表及其曲线没有修改。

实际 DDR 槽配置回归通过 30 次写帧、读帧及显示事件，核对 87 次配置，
包含缓存旧帧、无目标、无效槽、K2 检测切换及四种显示模式。
仅模式 2 的目标框向右下各补偿 3 像素。
配置邮箱在复位值 000/080/F80 下分别验证全部 4,096 个 12 位数据，
覆盖快速源时钟、目的时钟暂停、传输中复位和无需伪请求的默认值恢复。

RAW 统计回归通过四种 Bayer 排列的 64×48/1280×720 输入，HDMI 数字表
核对 6,451,353 个像素。真实 ISP 帧号测试通过 518,400 个带标签输出字；
红色和运动 ISP 集成各通过 3 帧、518,400 个打包输出字。
真实 RAW 六帧运动回归通过 1,036,800 个打包字，每帧保留 720 个行尾，
核对第 4 帧确认及第 5 帧保持行为。

该版 Scharr 独立参考回归通过 64×48 的 17 帧/49,344 像素、
64×49 的 17 帧/50,368 像素，以及关闭高斯时的 17 帧/49,344 像素。
最终 1280×720 回归通过 11 帧/10,137,600 像素，运行脚本退出码为 0。
DDR/FIFO 回归写入 6,512,640 字节、读出 3,686,400 个像素，
图像错误、上下溢及读空计数均为 0。
延迟 OSD 回归通过 495 项检查、128,262 个独立像素及四帧
3,686,400 个 mixer 输出像素。

该版原始日志、结果摘要、测试源码校验值和延迟预览集中保存于
[算法回归证据包](../build/verification/algorithm_regression.zip)。
四模式 bit 为 `src-5465baecfd7a`；该次完整构建时序通过，见
证据包中的历史记录。固定路径下的[发布清单](../build/release/release_manifest.json)
会随成功构建更新，不能用于核对该四模式历史身份。上述仿真检查数字逻辑和流水对齐，
不证明真实摄像头画面的美观或识别效果。

## 更早验证基线（历史）

以下为模式扩展前的固定色调查表基线记录，保留其原有验证范围：
2026-10-17 固定色调查表测试通过 1,281 组像素、2,560 次时钟边沿外保持和
255 次单调检查，覆盖全部 256 个灰阶、混色和三通道独立扫址。
使用独立分段公式核对输出，并检查黑白端点及开启/关闭时的一拍寄存。
独立 Gamma 综合网表另用官方安路原语模型通过 5,120 组参考对照；
该检查没有 SDF，仅验证门级功能和寄存拍数，全系统时序由 TD Routed 报告确认。
最终逻辑 ROM 源码的完整 HDMI 回归核对四帧 3,686,400 个像素，
RAW 数字表回归核对 6,451,353 个像素，目标框测试核对八帧 7,372,800 个像素；
DDR 槽与显示对应测试通过 30 次显示事件。
背景期望根据输入坐标或已知源像素独立计算，检查曲线生效且原 OSD、框与同步位置保持。
该版资源和最终时序见 [代码导航](../docs/CODE_MAP.md) 的前版基线；该次检查没有生成或更新 bit。
这些合成像素不能代替实拍画质确认。

2026-10-16 延迟监测测试通过 49 个显示样本、29 次 Gray 计数回绕及生产
172799/172800 写计数边界；真实 ISP 侧带测试核对 518400 个输出字，
覆盖两次短帧中止和帧号回绕。OSD 检查 495 项、128262 个独立像素，
并核对四帧共 3686400 个 mixer 输出像素。
读数含义与测量范围见 [延迟可视化说明](../docs/LATENCY_VISUALIZATION.md)；
新增验证证据集中在 `build/release/latency_validation.zip`。

2026-10-16 运动稳定性测试在便携 RAM、厂商 ERAM 下各通过 406 帧：
静止/干扰误触 0/168，8 组要求运动在前两帧确认后检出 120/120。
真实 RAW 六帧回归通过，每帧保留 720 个行尾。
完整规则、灵敏度和跟随延迟见 [运动检测说明](../docs/MOTION_DETECTION.md)。
日志和逐帧 CSV 归档在 [当前验证记录](../build/release/validation.zip)。

原始帧差测试直接实例化 `motion_target_detect_96` 的历史 6/8 默认参数，
选择器兼容测试关闭稳定器；它们不能代替生产 10/12 参数的稳定性回归。
测试不模拟 MIPI/HDMI 电气、真实 DDR 器件或传感器感光响应；
综合与时序另由 [构建入口](../build_firmware.cmd) 检查。

详细历史数字与旧版验证范围见 [仿真历史](../docs/history/SIMULATION.md)。
