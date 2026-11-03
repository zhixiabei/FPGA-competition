# 水果权重 Flash 加载

模型存放在独立用户 Flash U30。当前配置 `fruit_merged/handfixed_config.v` 要求模型 CRC32 `3a37bea7`。

## 当前操作

修改形状逻辑后，只需在主工程通过构建验收后更新主程序 bit；已经匹配的新权重无需重复烧录。电脑中有没有模型文件，不影响 FPGA 从 U30 读取已保存的权重。

模型检查点位于 `fruitcnn128_retrained_20261031/training/model.pt`，它是训练归档，不是可直接烧写的定点包。

## 上电流程

等待 DDR 校准后，主工程使用 SPI `03h` 从 U30 起始字节地址 `0xF00000` 读取模型，写入 DDR 的 `0x00C00000`，计算 Flash CRC，并从 DDR 全量读回计算第二次 CRC。两次均匹配配置才置位 `model_ready`。

`spi_flash_reader.v` 没有写入、擦除或改状态寄存器指令；`fruit_flash_boot.v` 中的写操作仅针对 DDR。CRC 不匹配时拒绝启动识别，不会把电脑上的旧文件写回 U30。U33 保存 FPGA 配置程序，U30 保存模型，两者不是同一芯片。

## 诊断

`verification/read_flash_model_status.ps1` 可查询启用了状态诊断接口的固件，需指定实际串口。生产配置是否开启诊断以顶层参数为准，不能把无回复直接认定为 Flash 失败。

主工程状态协议为 `FBT1`。成功时 `model_ready=true`，Flash 和 DDR CRC 匹配模型配置。历史临时烧写协议 `FPG1` 不代表主工程已启动。

`sim/run_fruit_flash.ps1` 保留 Flash 接口与加载逻辑的局部回归，它只调用仿真器，不连接板卡。当前工程状态见 [首页](../README.md)。
