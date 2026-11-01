# 运动检测

SW2 OFF 时按 K2 切到 MOV。固定摄像头，等待曝光稳定后移动物体验证。检测与稳定逻辑位于 `user_source/hdl_source/isp/target_detect_switch_96.v`。

运动分支使用 8×8 灰度块的相邻帧差，结合邻域支持和变化密度拒绝孤立噪声。候选需连续确认；短时漏检保持旧框，边界有死区和缓动。全局亮度变化、坏帧或无效参考会清除候选，避免把曝光变化当成物体运动。

这些机制会增加跟随响应时间。低对比度、小目标和很慢的移动可能被过滤；输出仍是一个合并框，不包含摄像头运动补偿。运动确认时间与 [面板中的视频通路延迟](LATENCY_VISUALIZATION.md) 含义不同。

## 回归入口

在工程根目录运行：

```powershell
& './sim/run_motion_stability.ps1' -Pipeline Stable -Mode Both -CheckBehavior
& './sim/run_motion_result_stabilizer.ps1'
& './sim/run_isp_lighting_integration.ps1' -Motion
& './sim/run_isp_motion_camera.ps1' -LineBlanking 32 -MovePixels 4
```

当前源码的构建与上板状态见 [首页](../README.md)。本页不再将历史 bit 哈希、资源占用和时序结果列为当前工程验收结果。
