# 仿真入口

当前手势模型仅为固定框 hand7 CNN。`tb_handfixed_system.sv` 覆盖完整预处理、CNN、DDR、KEY4 和背景参考；`tb_handfixed_refresh.sv` 覆盖 HDMI 结果刷新和跨时钟一致性，另有背景门控、按键和结果确认单元测试。

通过 `verification/generate_handfixed_background_tests.py --output build/handfixed_tests_new` 生成独立测试目录，具体 ModelSim 命令见 `docs/HANDCNN_FIXED_ROI_BACKGROUND.md`。

`resnet18_dsp_reference.sv` 是当前 CNN 共用 DSP 的仿真模型，名称沿用历史接口，不包含 ResNet 网络。其他摄像头、ISP、DDR、HDMI 仿真继续保留。
