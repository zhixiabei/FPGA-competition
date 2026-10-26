# 当前 RGB128 水果识别

2026-10-26 新增 main + 水果 + SW2 源码工程：`build/fruit/td_main_sw2/handfixed_candidate.al`，SW2=B4，ON 连续识别、OFF 返回 main 检测显示，无需 KEY4。本轮未编译或烧录。以下 bit 哈希、KEY4 操作与物理报告仅对应原冻结版，详见 [整合记录](MASTER_MAIN_MERGE.md)。

分类顺序：apple、banana、grape、orange、strawberry。第五类 HDMI 显示为 `STRAWBR`。

## 文件位置

- bit：`td_project/anlogic_edge_osd_Runs/best_result/fruitfixed_candidate.bit`。
- 现有 TD 工程：`build/fruit/td/handfixed_candidate.al`。
- 原始训练权重：`build/fruit/training/model.pt`。
- W8A12 权重：`build/fruit/weights/model.bin`。
- 物理验收：`build/fruit/td/release_verification.json`。

bit SHA256：`7db8dd38d1a6263ca1273d5c417729caf000df070c1cc986e66925ef292a0b7e`。
权重 SHA256：`b890089e104caf255f574c740732ab65b7eb14d369fdd7a6d31c2303eccc9db9`；CRC32：`bbd4adef`。

先用 TD Programmer 下载 bit，再在根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/load_handfixed_uart.ps1 -Fruit -WinUsb
```

读取状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/read_handfixed_status.ps1 -Fruit -WinUsb -Samples 3
```

水果模式默认绑定当前草莓工程及权重。清空中央识别框等待约 1～2 秒，再按 KEY4 启动。再次按 KEY4 停止并更新背景；水果完整放在固定 480×480 方框内。

## 已验证结果

当前量化模型模拟硬件缩放测试为 179/189；香蕉 50/52，其中两张被判为橘子。置信度门槛 0.65 时，接受正确 170、接受错误 5、拒识 14。这些数值是离线测试结果。

逐层数值检查 50 项、解码边界检查 123 项，以及背景、按键、状态仿真均通过。物理结果：Slice 18,884/21,216、ERAM 105/108、DSP 37/40；setup +0.107 ns、hold +0.020 ns，TNS 为零，约束健康检查通过。

使用 7 层卷积、Scharr/Laplacian 特征、128×128 RGB 输入，权重 INT8，激活有符号 12 位，DDR 使用 INT16 容器。置信度不足输出 UNKNOWN，结果滤波需要连续两次获取类别、连续三次切换。

## 后续构建

当前 bit 仅整理位置，内容与整理前完全相同。没有重新训练、布局布线或下载硬件。

现有构建入口 `build_firmware.cmd -Fruit` 使用保留的水果工程，bit 直接输出到上述公共 `best_result`，物理报告仍保存在该工程目录。入口在已有最终 bit 时会拒绝覆盖，需要有意重编译时先移走该功能的 bit。

校验当前文件：

```powershell
.\.conda\fruitcuda\python.exe verification/check_fruit128_release.py --project build/fruit/td --physical
```
