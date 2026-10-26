# 当前水果 CUDA 环境

PyCharm 解释器选择项目内 `.conda/fruitcuda/python.exe`，运行原文件 `verification/train_fruitcnn128.py`。训练配置、数据路径及测试方式见 [当前训练说明](FRUITCNN128_TRAINING.md)。

保留的环境为 Python 3.11、PyTorch 2.6.0 + CUDA 12.4，已在 RTX 4060 Laptop GPU 上训练当前模型。依赖清单为 `verification/requirements_fruitcuda.txt`，环境重建工具为 `verification/setup_fruitcuda.ps1`。旧 Lite、拍屏增强版训练入口和对应 PyCharm 配置已删除。
