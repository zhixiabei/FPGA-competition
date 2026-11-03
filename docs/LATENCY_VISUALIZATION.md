# 处理延迟可视化

HDMI 右上角的紧凑面板显示同一帧的 `TOTAL`、`ISP` 和 `BUF` 延迟，单位为 ms。
`TOTAL = ISP + BUF`；分辨率为 1 us，跨时钟采样存在微秒级量化误差。
该读数覆盖 RAW 输入到 HDMI 输出的板内数字通路，不包括传感器曝光、显示器响应，
也不等同于运动检测连续确认的响应时间。

| 字段 | 含义 |
|---|---|
| `TOTAL` | 同一帧从 RAW 首个有效像素到 HDMI 首个输出像素 |
| `ISP` | RAW 首个有效像素到 ISP 打包输出的首个有效数据 |
| `BUF` | ISP 首个有效数据到 HDMI 首个输出像素，包含缓存与输出等待 |

无有效同帧记录、帧未完整排入 DDR 命令队列或时间超过 1 s 时显示 `N/A`。
总延迟超过 128 ms 或字段超出六位十进制显示范围时高亮；显示值按 999.999 ms 封顶。
上电后先积累有效摄像头帧，此时短暂出现 `N/A` 正常。

当前面板为 280x64 像素，仅显示三个延迟字段，不显示 FPS。

## 实现边界

- 独立的 50 MHz 系统时钟生成 32 位微秒时间，摄像头停流时计时继续。
  寄存的单步 Gray 时间分别经两级同步器到摄像头和 HDMI 域，再解码寄存。
- RAW 首像素时间以 10 位帧号索引保存。帧号经过 LSC 的三拍延迟，
  在 Bayer 行缓存接受新帧时冻结，随真实生成的 ISP 帧首交接。
  没有产生 ISP 输出的短 RAW 帧不会使后续时间戳错位。
- ISP 的 SOF 早于有效像素。SOF 仅建立帧上下文，`ISP` 结束时刻取随后首个有效输出。
  元数据在收到确认前保持不变，DDR 按帧号与 RAW 时间同时匹配。
- DDR 实际分配写地址的同一拍，使复用槽位的旧记录失效。
  一帧 1280x720 RGB888 对应 172800 个 128 位写数据；
  全部进入原有 DDR 命令队列后才标记完成。该标志不声称 DDR 物理写入已经结束。
- DDR 选择读基地址时冻结整份时间记录；HDMI 首像素使用该快照，
  不重新查询可能已经复用的写槽。监测逻辑不参与 DDR 仲裁或视频流控。
- 超时样本无效，槽位记录还有独立的粗时间过期状态，
  防止旧记录在微秒计数回绕后重新有效。

主工程 SDC 为 Gray 总线和保持到确认的载荷设置传输时间上限。
相关时钟对使用宽松的异步数据路径上限，再对这些 CDC 路径收紧；
不能用覆盖整个时钟对的 `set_clock_groups` 把新增约束屏蔽掉。

## 源码

- `user_source/hdl_source/video_latency_timebase.v`
- `user_source/hdl_source/video_latency_monitor.v`
- `user_source/hdl_source/video_latency_osd.v`

## 验证

在工程根目录运行：

```powershell
& './sim/run_video_latency.ps1'
& './sim/run_video_latency_frame_tag.ps1'
& './sim/run_video_latency_osd.ps1'
& './sim/run_latency_display_toggle.ps1'
& './sim/run_target_frame_alignment.ps1'
& './sim/run_video_fifo_frame_integrity.ps1' -RawSource
& './sim/run_isp_motion_camera.ps1' -LineBlanking 32 -MovePixels 4
```
