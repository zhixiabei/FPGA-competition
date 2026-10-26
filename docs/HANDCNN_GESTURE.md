# 当前手势分类 CNN

仅保留 hand7：7 个 3×3 卷积层，通道依次为 16、24、48、48、64、64、96，每层卷积后为 BatchNorm 和 ReLU。2×2 平均池化后接三类全连接，156,675 个参数。模型定义：`verification/handcnn_model.py`。

输入为 96×96 RGB，采用 ImageNet 均值和标准差；类别顺序为 PEACE、PUNCH、STOP。当前权重温度系数 0.44442132115364075，置信阈值 0.65。NOTHING 通过背景、纹理和置信度规则输出，没有第四类分类头。背景差分的前景并不保证一定是手。

当前原始权重 `build/gesture/training/model.pt`，SHA256 为 `4a93dec7502a1bfb1db3bfea9bc1157035527272ea554569e953d396006578ea`。保留的训练历史和评估记录描述训练时的裁剪流程；当前固定框部署的实际准确率需以现场测试为准。

## 训练与测试

```powershell
E:/Python314/python.exe verification/train_handcnn_gesture.py --output build/gesture/new_training
.\run_handfixed_desktop.cmd
```

训练使用已保留的裁剪图片、审计清单及原始照片哈希，不依赖其他分类或定位模型。数据清单内的定位模型信息仅为历史数据来源记录。训练会生成新权重，不会替换当前已上板的定点权重；新训练权重还需要重新量化和硬件验证。

复原现有定点包（不重新校准或量化）：

```powershell
E:/Python314/python.exe verification/export_handfixed_fpga.py --output build/gesture/export_new
```
