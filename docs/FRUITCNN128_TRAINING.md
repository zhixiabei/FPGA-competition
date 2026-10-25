# 当前水果训练入口

在 PyCharm 中直接运行 `verification/train_fruitcnn128.py`，无需训练启动脚本。

- 解释器：`E:\aaa\FPGA-competition-main\FPGA-competition-main\.conda\fruitcuda\python.exe`。
- 工作目录：`E:\aaa\FPGA-competition-main\FPGA-competition-main`。
- 参数：留空即可使用当前草莓数据集和 CUDA 默认设置。
- 已配置的运行项：**Train Fruits 128 Strawberry CUDA**。
- 默认数据集：`E:\aaa\FPGA-competition-main\fruits5_strawberry_clean_20261025\data_manifest.json`。

类别顺序为 apple、banana、grape、orange、strawberry，训练/验证/测试共 875/189/189 张。

当前保留的用户训练结果是 `build/fruit/training/model.pt`。再次训练会创建新的时间戳目录，不覆盖该权重。断点续训时在 PyCharm 参数中填写 `--resume build/实际运行目录/last.pt`。仅检查数据时填 `--check-data-only`，检查后清空参数再正式训练。

电脑摄像头测试使用 **Test Fruits Camera CUDA**，或直接运行 `verification/predict_fruitcnn128.py`，参数填写：

```text
--checkpoint build/fruit/training/model.pt --camera 0 --device cuda
```

新训练结果还需要重新量化并与 FPGA 工程匹配，当前 bit 和权重配套关系见 [水果上板说明](FRUITCNN128_FPGA.md)。
