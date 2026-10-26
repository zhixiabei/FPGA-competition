# 固定识别框、KEY4 与背景拒识

当前板上模型为七层 hand7 CNN，156,675 个参数。摄像头 1280×720，识别框固定为 x=400、y=120、480×480，不自动框手。输入缩放为 96×96 RGB，W8A16 定点运算，24 路 MAC，40 位累加器。分类为 PEACE、PUNCH、STOP；规则拒识输出 NOTHING。

## 使用

1. 下载 `td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit`。
2. 运行 `verification/load_handfixed_uart.ps1 -WinUsb` 加载 `build/gesture/weights/model.bin`。
3. 保持空框以采集背景，再按 KEY4 开始持续识别。再次按 KEY4 停止并继续刷新背景。

背景比较采用 32×32 个绿色采样点：像素差达到 24，至少 64 个点发生变化进入前景，少于 32 个变化点退出。停止时双缓冲刷新完整参考，启动时冻结最近的完整参考；静止手仍与启动前背景比较。背景相同直接输出 NOTHING 并跳过 CNN，不运行分类。另有纹理门限、0.65 置信阈值及连续结果确认。改变照明、移动摄像头或放入其他物体仍可能触发前景。

KEY4 不清除权重。断电、复位或重新配置后权重丢失，需要重新加载并采集背景。状态读取：`verification/read_handfixed_status.ps1 -WinUsb`。暂停或跳过 CNN 时 logits 可能是上次值，应结合运行状态及显示类别解读。

## 固件与资源

固件 SHA256：`e0a302c6e0b4aa23b8908b6359f0ca417c0a1a76417dc12dff798aade08cd850`；权重 SHA256：`6726721746dcfb2745471c48d73ef25963007bd52da23ea28686d3185e026440`。

原始全系统物理结果：Slice 18,868/21,216，ERAM 107/108，DSP 37/40；setup WNS +0.149ns，hold WNS +0.020ns。报告和路由数据库在 `build/gesture/td/handfixed_candidate_Runs/phy_1/`。清理只移除旧网络源码和未使用分支，没有重新生成 bit；原始构建清单保存在清理记录中，当前清单描述清理后的工程。

## 验证与构建

```powershell
E:/Python314/python.exe verification/check_handfixed_project.py --physical
E:/Python314/python.exe verification/generate_handfixed_background_tests.py --output build/gesture/tests_new
E:/Python314/python.exe verification/prepare_handfixed_project.py --output build/gesture/project_new
```

在新测试目录内运行 ModelSim：

```powershell
E:/modelsim/modelsim_ase/win32aloem/vsim.exe -c -l key_simulation.log -do key_test.tcl
E:/modelsim/modelsim_ase/win32aloem/vsim.exe -c -l background_simulation.log -do background_test.tcl
E:/modelsim/modelsim_ase/win32aloem/vsim.exe -c -l refresh_simulation.log -do "set TEST_KIND refresh; do ../../../verification/run_handfixed_tests.tcl"
E:/modelsim/modelsim_ase/win32aloem/vsim.exe -c -l system_simulation.log -do "set TEST_KIND system; do ../../../verification/run_handfixed_tests.tcl"
```

完整系统测试覆盖真实预处理、完整 CNN、DDR 随机背压、空背景、静止拳头、移除手、停止后刷新背景及旧结果丢弃。这些是实现验证，不是现场识别率测量。

未来重新布局布线可运行 `build_firmware.cmd`，使用保留的最终工程；bit 输出到 td_project/anlogic_edge_osd_Runs/best_result。仅综合：在准备好的工程目录运行 `synthesis_only.tcl`。
