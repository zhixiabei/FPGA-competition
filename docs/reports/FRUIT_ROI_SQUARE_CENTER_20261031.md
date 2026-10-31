# 水果识别恢复正方形并在左侧画面居中

日期：2026-10-31。主工程：`td_project/anlogic_edge_osd.al`。

按用户要求撤回长方形取图和分类器补边改动，恢复原 480×480 正方形，仅将实际识别区域和显示框从原来的 x=400 平移到 x=240。右侧水果栏仍从 x=960 开始。

| 项目 | 当前值 |
|---|---|
| 画面 / 左侧相机区域 | 1280×720 / 960×720 |
| 识别区尺寸 | 480×480 |
| 左上角 | (240,120) |
| 取图区间 | x∈[240,720)，y∈[120,600) |
| 显示右下角，含端点 | (719,599) |
| 中心 | (480,360) |
| 距左侧相机区域边缘 | 左右各240，上下各120 |

## 实现

`fruit_merged/handfixed_preprocess.v` 恢复长方形改动前的原始正方形路径，与此前 `resource_phase2_20261030/final_reports/source_sha256.csv` 中的 SHA256 完全一致。移除分类器宽高参数、矩形填充判断和双轴尺寸寄存器，保留此前已经存在的缓存、分布式 RAM、插值流水及资源优化。

480×480 等比缩至 128×128，分类器输入不补边。每维步长恢复 3.75 源像素；第一输出采样中心为 (241.375,121.375)，最后为 (717.625,597.625)。仍使用半像素对齐、Q8 双线性插值和 Q9 归一化。

`fruitfixed_system.v` 的默认 `ROI_X=240`、`ROI_Y=120`、`ROI_SIDE=480` 同时驱动实际取图和四条框发布路径：初始引导、平坦或背景结果、CNN结果、停止事件。显示沿用包含右下端点的约定；坐标、类别和来源帧继续作为同一个结果传送。

CNN仍为24路并行，输入仍为三通道128×128、16位CHW，共6144次128位DDR写入。模型地址、大小、CRC、Flash内容及背景检测门槛没有变更。原模型配置中的 x=400 仅作为历史元数据保留，生产取图和显示由系统默认ROI参数决定。

此前诊断串口默认关闭的资源优化继续保留。侧栏、中英文字体、kg、价格、左下模式显示和右下独立延迟显示未改。

## 已完成验证

- 正方形预处理三例：新位置(240,120)、旧位置(400,120)、越界位置(-160,-80)，尺寸均为480×480。每例独立核验49152个归一化值、16384个绿样本、6144次CHW写入、196608次采样坐标、1024个背景参考样本，覆盖即时/延迟DDR响应、随机背压及全部16个字节偏移。越界例另检查87468次越界样本。编译和运行0错误、0警告；7项执行快照哈希与当前源码一致。见 `build/fruit_roi_square_20261031/preprocess/`。
- 生产系统126项检查通过：四条发布路径、复位和错误失效、实际默认ROI与采样步长、首个源像素及DDR读地址、停止后的读响应排空和四拍快照写排空。23项执行快照哈希与当前源码一致。见 `build/fruit_roi_square_20261031/system/`。本项仅注入CNN完成事件，不运行完整推理。
- 显示逐像素回归通过：4477198项检查、3172630次像素核验，包含两张1280×720整屏、六类结果、13种算法、4种检测模式、帧边界锁存和帧内切换、识别框开关、kg和价格。8项执行快照哈希与当前源码一致；9张PNG均已生成，并人工核对整屏及识别框局部预览。见 `build/fruit_roi_square_20261031/display_final/`。编译0错误、0警告，运行0错误；唯一运行警告为ModelSim Starter推荐容量提示，不是HDL或时序违例。
- Flash诊断开关回归通过：默认UART保持空闲，可选诊断协议及CRC、备用UART权重加载、Flash启动DDR行为一致。见 `build/fruit_roi_square_20261031/flash_diagnostic/`。
- `verification/check_merge_readiness.py` 通过主工程110个源文件、126个实例的路径和命名接口检查，以及相关项目、引脚和语音模块检查。

显示回归首轮暴露的是测试预期遗漏：CNN关闭时，正方形右边经过已有的检测跟随标签区域，应显示标签而非相机底图。已为既有标签补充独立字符串及字库预期，保留全部像素断言，未因此修改生产显示逻辑。首轮记录保存在 `build/fruit_roi_square_20261031/display_oracle_initial/`。

## 复现

```powershell
& ./sim/run_fruit_roi_preprocess.ps1 -OutputDir build/fruit_roi_square_check/preprocess
& ./sim/run_fruit_roi_system.ps1 -OutputDir build/fruit_roi_square_check/system
& ./sim/run_fruit_font_pixels.ps1 -OutputDir build/fruit_roi_square_check/display
& ./sim/run_fruit_flash_diagnostic_gate.ps1
& D:/python/python.exe -B verification/check_merge_readiness.py
```

生产源指纹：

- `fruitfixed_system.v`：`22167B898B66AD7BEB739C0AE2C164EC18A896C16DDBCB796C3550D98FB5FF6E`。
- `handfixed_preprocess.v`：`AAFF840984DB2ECB474B2307996532B75FE9EF80F554A4CE08BED6F626944D5A`。

本轮不运行综合、布局布线、bit生成、板卡下载或Flash操作。恢复正方形是缩小电路差异的回退，不代表物理实现已通过；最终资源、拥塞、Setup/Hold和上板识别表现仍须以重新综合布局布线和板上验证为准。

后续必须先重新综合，再运行布局布线。已有 `syn_1` 和 `phy_1` 中间数据库仍属于之前版本；只从旧数据库重跑布线不会包含这次源码修改。模型内容没有变更，无需因这次ROI平移重新写入权重。
