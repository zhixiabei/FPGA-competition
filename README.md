# 安路 PH1P35 图像处理工程

**使用 TD 编译时，烧录 `td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit`。**
当前源码为 2026-10-16 延迟可视化版，包含原有运动检测稳定功能。
脚本已编译好的版本另存于 [firmware/anlogic_edge_osd.bit](firmware/anlogic_edge_osd.bit)，
其文件校验值、构建时间及最终时序见 [脚本构建记录](build/release/release_manifest.json)。

## 使用

1. 在 TD 中打开 [主工程](td_project/anlogic_edge_osd.al)，完成综合、布局布线和 bit 生成；
   在下载器中重新加载 `td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit` 后烧录。
2. **K1（D5）**切换彩色/Scharr 边缘；**K2（A9）**切换红色/帧差运动检测。
3. 固定摄像头，等待曝光稳定后持续移动物体。运动框连续 3 帧确认，
   停止后保持 2 帧，第 3 帧清除；位置平滑会带来少量跟随延迟。
4. 右上角显示同帧 `TOTAL`、`ISP`、`BUF` 延迟、累计 `MIN/MAX`
   和最近 64 个显示帧的曲线，单位为 ms。无有效记录时显示 `N/A`。
   该读数测量 RAW 输入到 HDMI 输出的板内数字通路，不含传感器曝光及显示器响应。

## 修改后生成新 Bit

日常继续在 TD 中编译，成功后使用 `best_result/anlogic_edge_osd.bit`。
外部修改工程文件后，需要重新打开工程，使 TD 加载最新源码列表。
新增延迟功能需要 `video_latency_timebase.v`、`video_latency_monitor.v` 和
`video_latency_osd.v` 三项都登记在工程中。

也可以双击根目录的 [build_firmware.cmd](build_firmware.cmd)，或在 PowerShell 执行：

```powershell
& '.\verification\run_image_quality_build.ps1' -GenerateBit
```

脚本在独立临时目录完成综合、布局布线和 bit 生成，
仅在最终建立/保持时序均通过后更新 `firmware/anlogic_edge_osd.bit`；
失败时保留上一份成功的 bit。
TD 界面编译更新 `best_result`，脚本编译更新 `firmware`，两个目录不会自动同步。
每次都重新加载本次实际生成的文件后再烧录。

## 目录

| 位置 | 内容 |
|---|---|
| [firmware/](firmware/) | 脚本生成的 bit 和说明；TD 界面编译不会更新这里 |
| [td_project/anlogic_edge_osd.al](td_project/anlogic_edge_osd.al) | 主 TD 工程，顶层 `design_top_wrapper` |
| [user_source/](user_source/) | HDL、IP、初始化数据和引脚约束 |
| [sim/README.md](sim/README.md) | 仿真入口与验证范围 |
| [verification/](verification/) | TD 构建、工程检查和修复脚本 |
| [docs/](docs/) | 使用、代码导航、诊断、参考资料及开题文档 |
| [build/release/](build/release/) | 当前构建报告、校验清单及压缩验证证据 |

`td_project` 包含两套工程的 `.al` 和 `.sdc` 文件；
TD 界面编译会在这里生成 `*_Runs` 和 `best_result`。
源码和工程路径保持原位；不要把整个源码目录重复加入 TD。

## 常用说明

- [K1/K2 使用与上板检查](docs/VIDEO_MODE_SWITCH.md)
- [代码与配置导航](docs/CODE_MAP.md)
- [运动检测规则和验证结果](docs/MOTION_DETECTION.md)
- [延迟读数、曲线和验证边界](docs/LATENCY_VISUALIZATION.md)
- [摄像头诊断](docs/SC520CS_TEST.md)、[RAW10 测量](docs/RAW_STATS_GUIDE.md)
- [参考资料导航](docs/参考资料导航.md)、[开题文档](docs/proposals/)、[Git 使用](docs/GITHUB_WORKFLOW.md)

旧版开发过程和实验数字集中到 [开发历史](docs/history/DEVELOPMENT.md)
与 [仿真历史](docs/history/SIMULATION.md)；其中的旧导出路径已停用。
