# 安路 PH1P35 图像处理工程

**日常烧录只选 [firmware/anlogic_edge_osd.bit](firmware/anlogic_edge_osd.bit)。**
该文件为 2026-10-16 运动检测稳定版；旧版和重复的导出 bit 已清理。
文件校验值、构建时间及最终时序见 [当前构建记录](build/release/release_manifest.json)。

## 使用

1. 在下载器中重新选择 `firmware/anlogic_edge_osd.bit`，按原流程烧录。
2. **K1（D5）**切换彩色/Scharr 边缘；**K2（A9）**切换红色/帧差运动检测。
3. 固定摄像头，等待曝光稳定后持续移动物体。运动框连续 3 帧确认，
   停止后保持 2 帧，第 3 帧清除；位置平滑会带来少量跟随延迟。

## 修改后生成新 Bit

保存源码和 TD 工程后，双击根目录的 [build_firmware.cmd](build_firmware.cmd)。
它在独立临时目录完成综合、布局布线和 bit 生成，
仅在最终建立/保持时序均通过后更新固定烧录文件。
失败时保留上一份成功的 bit。以后无需在日期目录之间寻找文件。

也可以在项目根目录的 PowerShell 执行：

```powershell
& '.\verification\run_image_quality_build.ps1' -GenerateBit
```

每次重新生成后，在下载器中重新加载该文件再烧录。
TD 图形界面直接编译产生的 `*_Runs` 是工具内部输出，
根目录构建入口才会自动更新 `firmware`。
其中 `best_result` 和 `phy_1` 中的普通、压缩 bit 都是工具生成的副本。
本次已清除旧运行缓存；以后直接在 TD 图形界面编译时，这些目录还会重新生成。

## 目录

| 位置 | 内容 |
|---|---|
| [firmware/](firmware/) | 唯一的日常烧录 bit 和说明 |
| [td_project/anlogic_edge_osd.al](td_project/anlogic_edge_osd.al) | 主 TD 工程，顶层 `design_top_wrapper` |
| [user_source/](user_source/) | HDL、IP、初始化数据和引脚约束 |
| [sim/README.md](sim/README.md) | 仿真入口与验证范围 |
| [verification/](verification/) | TD 构建、工程检查和修复脚本 |
| [docs/](docs/) | 使用、代码导航、诊断、参考资料及开题文档 |
| [build/release/](build/release/) | 当前构建报告、校验清单及压缩验证证据 |

`td_project` 当前只保留两套工程的 `.al` 和 `.sdc` 文件。
旧运行缓存和日志已清理，下次通过 TD 图形界面编译需要重新运行综合、布局布线。
源码和工程路径保持原位；不要把整个源码目录重复加入 TD。

## 常用说明

- [K1/K2 使用与上板检查](docs/VIDEO_MODE_SWITCH.md)
- [代码与配置导航](docs/CODE_MAP.md)
- [运动检测规则和验证结果](docs/MOTION_DETECTION.md)
- [摄像头诊断](docs/SC520CS_TEST.md)、[RAW10 测量](docs/RAW_STATS_GUIDE.md)
- [参考资料导航](docs/参考资料导航.md)、[开题文档](docs/proposals/)、[Git 使用](docs/GITHUB_WORKFLOW.md)

旧版开发过程和实验数字集中到 [开发历史](docs/history/DEVELOPMENT.md)
与 [仿真历史](docs/history/SIMULATION.md)；其中的旧导出路径已停用。
