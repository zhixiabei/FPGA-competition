# 无板仿真：先验证边缘检测模块

新增 K1 彩色/边缘切换测试：双击 `run_video_mode.cmd`；720p 测试运行 `run_video_mode.cmd --no-pause 720`。覆盖按键消抖、帧边界选择和实际 96/128 位打包，详见 [切换说明](../VIDEO_MODE_SWITCH.md)。原有独立边缘测试入口保持不变。

TD 中的 Read Design / Optimize / Generate Bitstream 是实现流程。功能仿真需要测试台（testbench）提供时钟、复位和输入像素，再由仿真器执行 RTL。

本目录直接使用合并工程原有的 `user_source/hdl_source/isp/edge_detect_96.v`。没有改写 TD 的算法源码，也没有把测试台加入 TD 的综合源文件列表。

## 推荐：直接在 Vivado 界面操作

用 Vivado **Open Project** 打开 [vivado/edge_gui.xpr](vivado/edge_gui.xpr)，点击 **Run Simulation → Run Behavioral Simulation**。工程已配置测试台、运行到结束和默认波形，不需要手工运行脚本。

详细的点击步骤、波形说明和结果图片位置见 **[Vivado 图形界面仿真](VIVADO_GUI.md)**。下面保留脚本方式，作为备选；两种方式引用同一份边缘源码和测试台。

## 脚本运行（备选）

1. 在资源管理器打开本目录，双击 `run_xsim.cmd`。
2. 程序依次编译、展开、运行；结束应显示 `PASS` 和 `ALL_TESTS_PASS`（后者在仿真日志中）。
3. 打开 `out/input.bmp` 查看输入图片，打开 `out/edge_output.bmp` 查看原 RTL 算出的边缘。
4. `out/edge_expected.bmp` 是独立的整帧参考算法结果；测试台已经逐像素比对，不需要靠肉眼判断。
5. 双击 `open_wave.cmd`，启动 Vivado 波形查看窗口并读取已保存的 `out/edge.wdb`。这里只使用 XSim / 波形查看功能，不是建立 Xilinx 板卡工程。

脚本默认使用本机已确认的 `D:\XILINX\Vivado\2021.1\bin`。换电脑后可修改两个启动脚本的 `SIM_BIN`，或设置环境变量 `VIVADO_SIM_BIN`。

小尺寸为 320×180，便于快速学习。双击 `run_720p.cmd` 则以 1280×720 参数运行同一套测试，结果单独保存在 `out_720p` 中。`open_wave.cmd` 默认查看小尺寸结果。

## 波形怎么看

| 信号 | 含义与检查方法 |
|---|---|
| clk | 本测试时钟周期 16 ns；这是行为仿真激励，不是时序收敛验证 |
| rst_n | 初始为 0，复位结束后为 1；第五帧前再复位一次 |
| in_valid | 为 1 时输入四个 RGB888 像素 |
| in_user | 一帧第一个有效像素组，与 in_valid 同时为 1 |
| in_last | 每行最后一个有效像素组；小尺寸每行 80 组，720p 每行 320 组 |
| in_data | 96 位；从高位到低位依次放四个 24 位 RGB 像素 |
| out_valid / out_user / out_last | 对应输入控制信号经过模块输出寄存器 |
| out_data | 原边缘 RTL 输出；每个像素只能是 000000 或 FFFFFF |
| frame_id | 0 到 4，标记正在运行哪一帧测试 |
| dut/x_grp、dut/y_pos | 边缘模块内部的像素组与行计数 |

使用 Wave 窗口的放大按钮，先看复位释放后几微秒；再查看行结束、帧切换附近。数据通常在时钟上升沿后更新，测试台在下降沿驱动输入，避开采样竞争。

## 检查了什么

- 第 0 帧：灰色背景、白色矩形和彩色矩形，导出 BMP。
- 第 1 帧：全白，输出应全黑，用于检查上一帧行缓存残留。
- 第 2 帧：全黑，输出应全黑。
- 第 3 帧：固定种子的随机彩色像素，插入 valid 空拍，检查算法在输入间歇时的状态。
- 第 4 帧：复位后输入条纹图，检查输出复位及行缓存重新填充。
- 每帧检查像素值、像素总数、帧首与行尾、输出寄存延迟；遇到 X/Z 或不一致立即失败。

参考模型按本 RTL 的行为计算：先用位移灰度化，再把相邻两像素平均，使用 3×3 Sobel 的 |Gx|+|Gy|，以 80 为阈值，最后复制每个结果到两个输出像素。首两行、每行前四像素置黑，窗口按当前输入位置结束。不能直接拿默认 OpenCV Sobel 输出当作逐像素真值。

## 验证边界

这次只验证独立的边缘检测模块，ready 固定为 1，帧首与第一个有效像素组对齐。未验证完整 ISP、AWB 到边缘模块的帧首时序、96/128 打包、OSD、DDR、MIPI 和 HDMI，也未验证随机反压。

特别注意：本测试给边缘模块插入 valid 空拍，不代表后面的原 96/128 打包模块也支持任意空拍。后者需要另外的接口测试。

后续建议顺序：边缘模块 → OSD 图像叠加 → 像素打包/拆包 → ISP 接口 → 帧缓存模型。整机仿真还需厂商 IP 仿真模型及摄像头/存储器激励。

## ModelSim / Questa 备选

如果已有 ModelSim / Questa，可在其 Transcript 输入：

```tcl
cd D:/vivado_work/anlogic_edge_osd/sim
do run_modelsim.do
```

结果在 `out_modelsim`。本模块不依赖安路原语，因此不需要先编译安路器件库；整机/IP 仿真不适用这一结论。本机实际验证使用 XSim，ModelSim 脚本仅提供备选，尚未运行验证。

## 出错时

查看对应输出目录里的 `compile_console.log`、`elaborate_console.log`、`simulate_console.log`，先处理第一条 ERROR/Fatal。`result.txt` 必须是 PASS 才算通过，生成波形或图片本身不代表通过。

不要把 `tb_edge_detect.sv` 加入 TD 的综合源文件。它有延时、文件读写和仿真结束语句，只供仿真器运行。
