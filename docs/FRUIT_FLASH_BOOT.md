# 水果权重 Flash 固化与自动加载

## 当前完成情况（2026-10-29）

已通过临时 JTAG bit 将现有五类水果模型写入独立用户 Flash U30。
板上读到 JEDEC ID `20BA18`，与原理图中的 N25Q128 对应。
烧写程序完成全量逐字节回读比对，返回 `FPG1 / state=21 / error=0 / finished=true`。

- 权重大小：170752 字节，SHA256：`b890089e104caf255f574c740732ab65b7eb14d369fdd7a6d31c2303eccc9db9`。
- 权重 CRC32：`BBD4ADEF`。
- U30 字节地址：`0xF00000` 至 `0xF29AFF`（含末尾）。
- DDR 目标字节地址：`0x00C00000`。
- 烧写程序只在目标区全空白时编程，不含擦除命令；内容完全相同时直接完成，其他非空内容会报错停止。

独立 Flash 的权重断电不丢失。DDR 的内容断电会丢失，由新版主工程上电重新加载。
本次未修改 U33 配置 Flash 内已有的启动程序。

## 用户继续编译和烧录

打开 `td_project/anlogic_edge_osd.al`。源码和主工程文件已接入自动加载，顶层默认 `FRUIT_FLASH_MODEL=1`。
由于 RTL 已改变，必须从综合开始重新运行，再进行布局布线和生成 bit；不能直接沿用旧综合结果。
主工程已通过 HDL 展开并进入综合，按用户要求停止自动构建，尚未完成主工程最终资源和时序验证。
现有 `best_result/anlogic_edge_osd.bit` 仍是 2026-10-29 20:44 的旧文件，尚不支持 Flash 自动加载。

生成新版主工程 bit 后，可先通过 Program SRAM 验证。需要断电后自动启动时，再将新版主工程 bit 通过 Program Flash 固化到原配置 Flash U33。
U33 和存放权重的 U30 是不同芯片；正常的主工程 Program Flash 操作不需重写 U30 权重。

不要把 `build/flash_model/programmer/fruit_flash_programmer.bit` 当主工程固化。它只是一份临时烧写程序，不含相机、HDMI 或识别算法。
当前 SRAM 运行的是这份临时程序；断电后会恢复 U33 中原有的旧主程序。权重仍留在 U30，但旧主程序仍等待串口权重。

## 新主工程加载流程

等待 DDR 校准完成，按标准 SPI `03h` 读 U30，将权重写入 DDR，计算 Flash 数据 CRC，再把 DDR 权重全部读回并计算第二次 CRC。
两次 CRC 都等于生成配置中的 `BBD4ADEF` 才置位 `model_ready`，之后才允许采集识别用图像和运行水果分类器。
读取失败、数据校验不匹配、DDR 失去校准或协议故障时保持模型未就绪。
主工程读取模块不包含 Flash 写入或擦除指令。既有 UART 权重加载路径保留为 `FRUIT_FLASH_MODEL=0` 的编译选项。

可以只查询状态（不会发送权重）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\vivado_work\anlogic_edge_osd\verification\read_flash_model_status.ps1" -Port COM3
```

新版主工程应返回 `FBT1`，正常终态为 `state=8 / error=0 / model_ready=true`，`flash_crc32` 和 `ddr_crc32` 均为 `0xBBD4ADEF`。
临时烧写程序返回 `FPG1`，不能把它的 `finished=true` 当作主工程已完成自动加载。

## 验证与硬件依据

`sim/run_fruit_flash.ps1` 已通过：空白写入、逐字节回读、重复烧写免写、非空保护、错误 ID 拦截、写保护拦截、Flash CRC、DDR CRC、DDR 背压。
临时烧写 bit 已完成布局布线：833 Slice，68 ERAM；最终 setup slack `+5.779 ns`，hold slack `+0.020 ns`。
这是临时烧写程序的结果，不是主工程的资源占用。

引脚取自 `HX1P35B_FT_40P_2.pdf`、`_3.pdf`、`_8.pdf` 原理图：U30 CS=D14，CLK=N6，DQ0=E13，DQ1=D16，DQ2=C16，DQ3=A13。
U33 使用 FPGA 配置专用引脚，历史安路烧写日志识别其厂商 ID 为 `C8`。
