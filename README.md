# 安路 PH1P35 边缘检测 + OSD 合并工程

在 TD 中选择 File → Open Project，打开：

    td_project/anlogic_edge_osd.al

目标器件：PH1P35MDG324，速度等级 -3。顶层：design_top_wrapper。
原工程及本次检查使用 TD 6.2.168116。

## 合并内容

以 Lab2（lab_ex2_edge）为基础，保留原有摄像头、RAW10 解包、ISP、边缘检测、DDR 和 HDMI 通路。
使用 Lab3 的 hdmi_mixer.v 替换显示混合模块，并加入 anlogic_logo_rom.v、osd_char_lib.v。
输出通路：SC500CS → ISP → 边缘检测 → DDR → 安路 Logo / 字符 / 帧计数叠加 → HDMI。
分辨率保持 1280×720；顶层 DEBUG_MODE 保持 0。

已复制全部 user_source，工程文件引用均指向本文件夹内的文件。
新工程名称为 anlogic_edge_osd；原来的两个例程未修改。
未复制原工程的历史运行目录、旧下载文件和旧编译成功标记。
综合使用默认生成脚本，便于 TD 按当前工程源文件清单重新编译。

## 打开后操作

1. 打开 td_project/anlogic_edge_osd.al，不需要重新创建工程或手工添加文件。
2. 检查目标器件和顶层名称，然后运行 Synthesis。
3. 再运行布局布线，查看资源和时序报告；通过后生成下载文件。
4. 没有开发板也可以编译；下载和摄像头、HDMI 实物验证需要 HX1P35A。

不要把整个源码文件夹中的所有 .v 再加入工程：其中有历史版本和同名模块。
特别是 data_96bit_to_128bit 模块已经由 isp/data96_128/data96_128.v 提供，不能再添加根目录的同名模块文件。
有效引脚约束为 user_source/constraints_source/pin.adc；有效顶层时序约束为 td_project/anlogic_edge_osd.sdc。

## 验证记录

verification/source_check.txt：文件引用、合并文件一致性和重复模块检查。
verification/check_td.tcl：使用实际 .al 工程做 TD 源码解析和层次展开。
verification/synth_td.tcl：TD 综合资源检查脚本。
verification/synthesis_console.log：本次综合完整输出，以末尾 PASS/FAIL 标志及资源报告为准。

目前合并保留了原例程的算法和时序行为，不代表完成了功能仿真或实物验证。
原例程中的未连接输入、位宽等告警需要结合后续仿真和上板调试审查。
OSD 中的运行计数按显示帧递增，不是秒计时。
## 本次 TD 综合结果（2026-09-23）

- 工程打开、源码分析和层次展开：通过。
- RTL 优化、门级综合、物理实例合法化：完成，synthesis_console.log 末尾为 MERGED_PROJECT_SYNTHESIS_PASS。
- 综合阶段资源：Slice 13510/21216（63.68%），ERAM 40/108（37.04%），DSP 9/40（22.50%），寄存器 13768/42432（32.45%）。均未超出报告容量；最终用量以布局布线为准。
- 综合时序估计：Setup WNS = -1.477 ns，Hold WNS = 0.114 ns，STA coverage = 95.32%。综合完成不等于时序通过。请继续布局布线，检查最终时序以及未约束路径。
- 原 PLL 配置保持不变。综合报告显示 HDMI 像素时钟约 75.002 MHz；不是重新生成的标准 74.25 MHz 配置。
- 未执行布局布线、下载文件生成、功能仿真或实物验证。
- 完整资源报告：verification/merged_gate.area；综合时序报告：verification/merged_gate.timing。

本次检查还报告了原边缘模块 RAM_STYLE 设置未按预期采用、部分原例程信号未连接和位宽等告警。保留日志供后续审查，未为消除告警改写原算法。
## 新增：边缘模块无板仿真（2026-09-23）

已添加 sim 文件夹，不影响 TD 综合工程和算法源码。
双击 sim/run_xsim.cmd 可运行 320×180 测试；双击 sim/run_720p.cmd 可运行 1280×720 测试。
两种尺寸都已在本机 XSim 2021.1 通过，每种 5 帧逐像素比较。
双击 sim/open_wave.cmd 查看小尺寸波形；在 sim/out 或 sim/out_720p 打开 BMP 查看图像。
使用说明见 sim/README.md，验证范围见 sim/validation.txt。仅验证独立边缘模块，整机功能尚未验证。