# 当前代码入口

- `user_source/hdl_source/design_top_wrapper.v`：摄像头、ISP、DDR、固定框 CNN、HDMI 顶层。
- `user_source/hdl_source/handfixed/`：KEY4、背景采集、固定框缩放、分类解码、连续确认、控制器。
- `user_source/hdl_source/handcnn/`：共用 CNN 算子、快照、归一化与置信度 ROM。
- `user_source/hdl_source/resnet18/`：当前 CNN 共用的 UART、权重加载、DDR 仲裁。
- `user_source/hdl_source/resnet/resnet_ph1p_dsp.v`：当前 CNN 的原生 DSP 封装。
- `user_source/hdl_source/cnn/cnn_eram_byte_dp.v`：共用 ERAM 存储。
- `verification/handcnn_model.py`、`train_handcnn_gesture.py`：唯一保留的 hand7 网络与训练入口。
- `verification/run_handfixed_gesture.py`：桌面固定框整数模型预览。
- `verification/load_handfixed_uart.ps1`、`read_handfixed_status.ps1`：板上加载与状态。
- `verification/prepare_handfixed_project.py`：冻结当前源码；`build_handfixed_background.tcl`：完整构建。
- `verification/check_handfixed_project.py`：当前制品、源码、仿真和原始物理结果核对。

完整视频及通用模块仍在原位置。历史命名沿用，不表示仍保留旧网络。
