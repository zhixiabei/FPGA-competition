# 在 Vivado 界面中仿真

已经建好工程，不需要手工运行 CMD 或 Tcl 脚本。

## 打开并运行

1. 启动 Vivado 2021.1，点击 **Open Project**，打开 [vivado/edge_gui.xpr](vivado/edge_gui.xpr)。也可以在资源管理器里双击这个 .xpr 文件。
2. 左侧 **Flow Navigator → SIMULATION → Run Simulation → Run Behavioral Simulation**。
3. 等待编译和仿真完成。工程已设置 Run Time=all，会运行到测试台的 `$finish`；下方 Tcl Console 应显示 `ALL_TESTS_PASS: 5 frames, 288000 pixels checked`。
4. 中间的 **Wave** 窗口已预置 15 个信号。点 **Zoom Fit** 查看整个过程，选中一小段区域放大，或用 **Zoom In** 看时钟边沿。

如果你修改过运行时长而只跑了一小段，点击仿真工具栏的 **Run All** 继续。这里不需要 Run Synthesis、Run Implementation 或 Generate Bitstream。

默认是 320×180、5 帧测试，适合快速调试。硬件工程仍是 TD 的 .al；这里是独立边缘模块的行为仿真工程。

## 怎么找源码

在 Sources 面板展开 **Simulation Sources**，双击 `tb_edge_detect` 查看测试台，展开它并双击 `dut` 查看边缘模块。

| 文件 | 用途 |
|---|---|
| [tb_edge_detect.sv](tb_edge_detect.sv) | 时钟、复位、测试图像、预期结果比较、BMP 输出 |
| [edge_detect_96.v](../user_source/hdl_source/isp/edge_detect_96.v) | 实际被测试的原有边缘检测模块 |
| [edge_gui.wcfg](vivado/edge_gui.wcfg) | 预先选好的波形和数值显示格式 |

工程直接引用上述两份代码，没有复制另一份算法。修改边缘模块会同时影响 TD 工程和仿真；修改测试台只改变测试条件。

## 波形先看这些

| 信号 | 看什么 |
|---|---|
| clk、rst_n | 时钟、复位释放；测试时钟周期 16 ns |
| in_valid、in_data | 有效输入，每拍四个 RGB888 像素，96 位总线按十六进制显示 |
| in_user、in_last | 帧首与行尾 |
| out_valid、out_data | 模块输出；每个像素应为 000000 或 FFFFFF |
| out_user、out_last | 输出帧首与行尾 |
| frame_id、received、total_pixels | 当前测试帧号、已接收像素数和累计像素数 |
| dut/x_grp、dut/y_pos | 模块内部的像素组位置、行位置 |

整个测试约 1.244 ms；Zoom Fit 时看见密集波形是正常的。先放大开头几微秒，观察复位及一行的起止。图像数组和内部大 RAM 没有加入默认波形，以免窗口太拥挤。

## 看图片结果

每次运行结束后，在资源管理器进入工程下面的目录：

```text
vivado/edge_gui.sim/sim_1/behav/xsim/
```

本机完整位置是：

```text
D:\vivado_work\anlogic_edge_osd\sim\vivado\edge_gui.sim\sim_1\behav\xsim
```

- `input.bmp`：第 0 帧测试输入。
- `edge_output.bmp`：边缘模块计算结果。
- `edge_expected.bmp`：参考算法预期结果。
- `result.txt`：本次状态，只有第一行是 PASS 才算通过。

图片只显示第 0 帧；测试台另外检查了全白、全黑、随机图和复位后的条纹图。

## 修改后如何重新运行

例如在测试台把 `THRESHOLD = 80` 改成 `160`，保存后点击仿真工具栏的 **Relaunch Simulation**，让 Vivado 重新编译并执行。如果找不到该按钮，可先 **Close Simulation**，再点 **Run Behavioral Simulation**。

仅点击 **Restart** 会重新执行当前已编译的仿真，不能用来保证新源码已编译。

要测试 720p，可将测试台顶部 WIDTH/HEIGHT 改为 1280/720 后重新启动仿真；测试更慢。恢复快速调试时再改回 320/180。这个 GUI 工程没有为尺寸设置额外覆盖值。

## 已配好的设置与范围

- 仿真顶层：tb_edge_detect；设计模块：edge_detect_96。
- 仿真器：XSim；运行时长：all；缺省时间单位：1ns/1ps。
- .xpr 中的器件为 xc7a35tcpg236-1，供 Vivado 建立工程；本测试是普通 RTL 行为仿真，不使用板卡外设或 Xilinx IP。
- 原安路整机工程含安路专用 IP，不能直接全部加入这个 Vivado 工程进行实现。
- 已验证独立边缘模块；尚未验证整条 ISP、OSD、DDR、MIPI 和 HDMI。ready 固定为 1。
- .xpr、.wcfg 和本文档可随 Git 提交；缓存、仿真输出和日志已由根目录 .gitignore 排除。
