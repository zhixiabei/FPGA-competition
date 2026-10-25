# HX1P35A USB 串口与当前 HandCNN

板载 FT2232H 共享 Type-C：A 通道 JTAG，B 通道 UART。当前设备 VID:PID 为 0403:6042，整体绑定 WinUSB；`verification/FtdiWinUsbTransport.cs` 通过 associated interface 访问 B 通道，端点 OUT 04 / IN 83，无需虚拟 COM 口。UART 为 921600 baud、8N1。

在仓库根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/load_handfixed_uart.ps1 -ProbeUsb
powershell -NoProfile -ExecutionPolicy Bypass -File verification/load_handfixed_uart.ps1 -WinUsb
powershell -NoProfile -ExecutionPolicy Bypass -File verification/read_handfixed_status.ps1 -WinUsb
```

当前模型为 hand7 三分类，阈值 0.65，233,472 字节，共 912 个数据包。R18D 为历史协议标识，沿用 CRC32、逐包 ACK 和整模型校验，不代表加载 ResNet 网络。确认加载结果后清空识别框、等待背景参考就绪，再按 KEY4 启动。

模型已就绪时不要重复加载。暂停后仍保留 DDR 权重；复位、断电或重新下载 bit 后需要重新加载。Win32 5 可能表示 TD 下载窗口或 hwserver 占用同一 USB 设备，可先退出相关工具再测试。

若电脑已使用官方 VCP 驱动并枚举出 USB Serial Port，可使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verification/load_handfixed_uart.ps1 -ListPorts
powershell -NoProfile -ExecutionPolicy Bypass -File verification/load_handfixed_uart.ps1 -Port COM5
```

COM5 仅为示例，选择实际板载串口；蓝牙虚拟串口与板卡无关。当前 WinUSB 工作正常时无需更改驱动或 EEPROM。多板可通过 `-UsbSerial` 指定设备。
