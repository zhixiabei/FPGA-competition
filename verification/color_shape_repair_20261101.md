# 颜色、形状与跟踪修复验证（2026-11-01）

本次修改只涉及颜色检测 RTL 和相关仿真。工程文件、约束、CNN 精度及并行数、显示布局、语音、称重、Flash 和 bit 输出设置均未修改。未运行布局布线或生成 bit。

基线为本轮修改前的 `1f6f469`。最终 RTL SHA256：`7F520CA0F8D24222111B5E94102C5D89722104AB2433A6327DB3DEBA940B482B`。综合输入清单对比确认，HDL/工程/约束输入中只有 [red_target_detect_96.v](D:/vivado_work/anlogic_edge_osd/user_source/hdl_source/isp/red_target_detect_96.v) 改变。

修复内容：

- 红色由对称约 ±12° 改为橙色方向约 15°、另一侧约 20°；次通道上限由 `2R/3` 调整为 `3R/4`。测试中的暖红、偏品红和适度低饱和红不再漏检，测试中的橙色、白色和低饱和干扰仍排除。绿、蓝规则保留。门槛仍需要真实相机 AWB 后的样本校准。
- 先记录完整行区间，再判断与上一行的连通关系，消除原先逐拍 ±16 像素门限对轻微旋转正方形、大圆边缘的截断。无关行区间可被丢弃后继续寻找；锁定后，位于原目标上方的独立干扰区域不再提前结束搜索。
- 关联检查中心距离、尺寸变化和重叠。无可靠形状支持的大尺寸跳变需要连续一致测量；旋转正方形具有一致形状支持时可立即更新。关联使用原始框，显示使用平滑框。
- 显示中心保留 2 像素死区；快速移动需要尺寸稳定。宽高扩大立即响应，缩小逐步收敛，避免旋转轮廓被旧显示框压住。连续确认、两帧漏检保持、有限形状保持、空洞和破损轮廓的 UNKNOWN 保护保留。
- 复用结果队列和形状计算的非重叠暂存，形状运算采用 4 位分组且保留原算术精度。行级尺寸资格随下一行元数据提前计算；累加器先运算，再选择是否重启轮廓，避免新增关联判断串入完整进位链。

仍为单行区间、单目标架构，没有恢复 8 候选表。首次捕获仍选第一个尺寸合格的轮廓。接触的同色背景、交叉重叠的同色目标、真实白色高光孔洞仍可能使分割或形状判断失败；不能把这次修复理解为完整多目标分离。有效目标门槛仍为面积至少 128 像素、宽高至少 8 像素；形状分类另要求宽高至少 12 像素，并避开图像边缘。

同配置、同工具综合比较（Tang Dynasty v6.2.168116，PH1P35MDG324，speed 3）：

| 指标 | 修改前 | 修改后 | 差值 |
| --- | ---: | ---: | ---: |
| LUT | 29,542 | 29,686 | +144 |
| 寄存器 | 19,586 | 19,459 | −127 |
| Optimize-Gate Slice 估算 | 22,919 | 22,986 | +67，约 +0.29% |
| ERAM | 100 | 100 | 0 |
| DSP | 39 | 39 | 0 |
| F7 / F8 | 115 / 16 | 115 / 16 | 0 |
| 建立时间最差裕量 | +0.128 ns | +0.141 ns | 已分析路径无违例 |
| 保持时间最差裕量 | +0.114 ns | +0.114 ns | 已分析路径无违例 |

最终建立/保持总负裕量均为 0。MIPI、DDR 用户时钟、HDMI 像素时钟的建立裕量分别为 +0.141、+0.364、+0.747 ns。STA 覆盖率为 94.23%，沿用既有约束。上述 Slice 是综合估算，工具明确说明需物理优化后才能得到实际值，不能与先前布线后的 20,258 个 Slice 直接比较。

当前综合余量较小。本次已消除修复过程中发现的新增检测长路径，但未测量最终拥塞、布线时间或布线后时序，不能保证一定不堵塞或一定通过布线。请重新综合，再由你运行布局布线，以最终报告中建立/保持时间无负裕量为准；不要沿用旧综合网表。

验证记录：

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 旧版故障复现 | 暖红漏检、轻微负角度旋转正方形 UNKNOWN、旋转显示框过小、上方干扰截断搜索均可复现 | [颜色复现](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/baseline_color/portable_console.log)、[几何复现](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/baseline_geometry_v2/portable_console.log)、[跟踪复现](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/baseline_track/portable_console.log) |
| 形状算术对照 | 4,800 组通过；涵盖两种输入保持模式、乘积/偏差/标志/输出，以及复位和取消 | [数值验证日志](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/descriptor_equivalence/console.log) |
| 跟踪及协议回归 | Portable、Vendor 均通过；每种 103 个结果、227 项检查 | [跟踪验证清单](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/robust_verified_v2/validation_manifest.json) |
| 修复场景回归 | Portable、Vendor 均通过；每种 56 帧、60 项检查 | [修复验证清单](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/repair_verified_v2/validation_manifest.json) |
| 1280×720 厂商模型回归 | Vendor 通过；25 个场景、66 个结果、159 项检查 | [720p 验证清单](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/production_720p/validation_manifest.json) |
| 保留的多目标分支兼容回归 | Portable 通过；109 个结果、215 项检查；未在工程启用此分支 | [兼容验证日志](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/multi_compatibility/portable_console.log) |
| 整机综合与时序 | 通过，未运行 place/route/bitgen | [综合资源](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/final/system_gate.area)、[综合时序](D:/vivado_work/anlogic_edge_osd/build/color_shape_repair_20261101/final/system_gate.timing) |

修复场景包含 11 个正负旋转角度的正方形、连续旋转、大圆、适度偏白红色条纹、同一行及上方独立干扰、瞬时边缘缺失。原有回归继续验证静止抖动、快慢移动、漏检保持和释放、空洞/U 形 UNKNOWN、颜色/预览切换、半帧、复位、连续行和结果帧号。

最终形状描述器与数值验证快照逐字一致。测得最慢分类为 1,212 个时钟，基线最多 402 个；增加最多 810 个时钟，按 103.52 MHz 约 7.8 微秒。此计算每帧执行，不改变每拍四像素的输入吞吐；不等于整机显示延迟的测量结果。

在工程根目录可复跑：

```powershell
.\sim\run_single_color_repair.ps1 -Mode Both -TimeoutSeconds 900
.\sim\run_single_color_track_robust.ps1 -Mode Both -TimeoutSeconds 900
.\sim\run_single_color_shape.ps1 -Mode Vendor -Width 1280 -Height 720 -TimeoutSeconds 1800
.\sim\run_shape_descriptor_equivalence.ps1 -ReferenceRtl build/color_shape_repair_20261101/baseline/red_target_detect_96.v -TimeoutSeconds 600
.\verification\run_image_quality_build.ps1 -SkipRoute
```

上板重点检查红橙同屏、静止目标、正方形正负角度旋转、大圆、快慢平移和短暂遮挡；先用 `09 BINARY`、`12 CLOSE MASK` 看分色和轮廓，再判断框和形状。需要真实相机画面验收才能确认现场效果。
