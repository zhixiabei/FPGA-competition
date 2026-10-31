# CNN 权重尾缓存 ERAM 优化

本轮在用户选定的 F7 采样选择器版本上，只修改 CNN 权重尾缓存的存储实现。
64×192 位分布式 RAM 改为 5 组 PDPW ERAM；每组供应相邻的 5 个 W8 通道，最后一组供应 4 个通道。
保留 512 条主缓存、64 条尾缓存、一拍同步读、24 路并行 MAC 和原有 DDR 协议。
ERAM 的 NOREG 模式已有一拍同步读，不能改成 OUTREG，否则会增加读延迟。
存储本体不复位；控制状态与有效位仍复位，每次启动都先重新加载权重再计算。

## 已完成的验证

使用同一工程配置的隔离综合快照，源码清单对比只有 `fruitcnn128_core.v` 不同。

| 综合统计 | 修改前 | 修改后 | 变化 |
|---|---:|---:|---:|
| LUT | 29,795 | 29,542 | −253 |
| 寄存器 | 19,778 | 19,586 | −192 |
| Slice 估算值（报告带星号） | 23,143 | 22,919 | −224 |
| 分布式 RAM LUT | 856 | 664 | −192 |
| ERAM | 95 | 100 | +5，剩余8 |
| DSP | 39 | 39 | 0 |
| F7 MUX | 115 | 115 | 0 |

综合估算 Slice 不能与上轮物理报告的 20,236 直接相减。
本轮没有运行 place、route 或 bitgen；新的实际 Slice、拥塞和最终时序尚未测量。

普通模型与 TD 厂商 RAM/DSP 模型均通过29组数值及周期等价回归。
两种模型分别比较修改前后的输出写入轨迹、周期数、MAC次数、DDR读写及等待统计，全部一致。
每个版本完成18,247次连续3×3吞吐检查与65,536组行偏移检查。
补充场景覆盖512/64缓存边界、576项卷积、多输出组重载、尾缓存加载中复位、尾部MAC执行中复位及不同数据重启。

证据位于 `build/cnn_eram_relief_20261031/`：

- `synthesis/before/system_gate.area`、`synthesis/after/system_gate.area`
- `numeric_tail_reset/validation_manifest.json`
- `vendor_tail_reset/validation_manifest.json`
- `validation_summary.json`

## 下一次用户运行布局布线

在原 TD 工程重新执行综合，再执行完整布局布线，使用新的综合数据库。
旧布局中CNN附近没有5个闲置ERAM槽位；新增ERAM需要工具重新分配现有RAM的位置。
本轮没有锁定ERAM、DSP、旧布局坐标或更换种子。分布式RAM减少不等于已证明布线更快。
保留8块ERAM，DDR owners队列优化仍作为后备，本轮未合入。

验收条件：最终实际Slice不超过20,236；ERAM不超过100；DSP不超过39；全部检查角的setup和hold均通过。
同一机器、同一设置下比较布线时间和拥塞报告；基准布局有11个利用率超过100%的tile，主窗口为(8,5)～(13,18)。
完成布线后在TD控制台读取当前设计，可使用：

```tcl
update_timing -mode final
report_timing_summary
report_area
report_route_status -drc
report_congestion -step route -th 90 -line 30
```

## 视频FIFO hold违例的局部修复流程

上轮剩余违例为同一 MIPI_RX_BYTE_CLK 域内：
`u_isp_top/u_data_96bit_to_128bit/O_128b_data_reg[89]_syn_2`
到`u_video_in/U_w128_d512_fifo/.../ramread0_syn_105.dia_extra[1]`，hold为−0.015ns。
TD已执行fix_hold，最后这条网的延迟修复因DRC冲突被撤回。

先检查新布线结果。新网表名称、时钟分支和位置可能变化，不能把旧坐标直接写进新工程。
如果同类hold违例仍存在，按以下顺序处理：

1. 在独立目录复制新布线数据库，使用副本打开设计，保留原bit和工程输出。
2. 从新的最终时序报告提取精确起点、终点、发送/接收时钟分支；检查源寄存器相邻位置的占用和拥塞。
3. 优先移动现有源寄存器及必要相邻逻辑，减少不利时钟偏斜，并允许数据网使用足够延迟的合法走线。
   目标位置由新布局决定；不能仅按距离越短越好选择位置。
4. TD支持 `move_cells -inst ... -location ... -mode nonforce -step route`；随后以 `route -eco`
   修复未布通的网络。具体实例和位置必须使用第2步取得的值。本轮没有执行这些命令。
5. 再检查路由DRC、所有角的setup/hold和实际Slice。局部hold通过而CNN等其他路径变为违例的结果不接受。
   未达到验收条件就保留原副本，继续基于报告定位，不生成或发布bit。

本轮没有改SDC、降低时钟不确定性、加入false path或新增视频流水拍。
之前的−0.015ns hold不能标记为已修复，必须由新物理报告确认。
bit输出路径、已有bit文件与工程配置均未修改。
