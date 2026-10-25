# 固件位置

bit 统一位于 `td_project/anlogic_edge_osd_Runs/best_result/`，此目录仅保留手势清单，不再复制 bit。

- 水果：`fruitfixed_candidate.bit`，当前苹果、香蕉、葡萄、橘子、草莓五分类。
- 手势：`anlogic_edge_osd.bit`，最终 KEY4 与背景判断版；SHA256 为 `e0a302c6e0b4aa23b8908b6359f0ca417c0a1a76417dc12dff798aade08cd850`。

两种功能下载各自 bit，再加载对应 DDR 权重。配套文件见根目录 README，手势文件清单见 `handcnn_manifest.json`。
