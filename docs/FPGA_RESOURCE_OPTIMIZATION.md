# 当前 HandCNN 全系统资源

采用 PH1P35MDG324，当前发布固件为固定框 hand7、KEY4 启停和背景参考版本，包含摄像头、ISP、DDR、HDMI、OSD。以下来自原始背景版最终布局布线报告：

| 资源 | 使用量 | 总量 | 比例 |
|---|---:|---:|---:|
| Slice | 18,868 | 21,216 | 88.93% |
| LUT6 | 18,018 | 21,216 | 84.93% |
| 寄存器 | 16,926 | 42,432 | 39.89% |
| ERAM | 107 | 108 | 99.07% |
| DSP | 37 | 40 | 92.5% |

Setup WNS +0.149ns，hold WNS +0.020ns，TNS 均为 0，时序覆盖 95.82%。报告位于 `build/gesture/td/handfixed_candidate_Runs/phy_1/`。

清理后仅移除其他模型和不参与当前版本的分支，不重新生成 bit。清理后的源码已重新通过综合；综合估算不能替代最终布局布线占用。原始构建证据与当前源码清单分别保存于清理记录和 `source_cleanup.json`。

ERAM 和 DSP 已接近上限，扩展功能需针对新增存储、乘法器和时序重新评估。当前模型结构和入口见 `HANDCNN_GESTURE.md`，当前固件使用及验证见 `HANDCNN_FIXED_ROI_BACKGROUND.md`。
