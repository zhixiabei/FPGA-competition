# main/master 整合与 SW2 水果开关

日期：2026-10-26。本轮明确禁止编译和烧录；仅生成工程文件与静态核对，没有运行 HDL 编译器、仿真器、TD、布局布线、bit 生成、UART/USB 加载或 Programmer。

## Git 原因与处理

远端为 `https://github.com/Laurel1233/FPGA-competition.git`。本轮 fetch 后，main 为 `ebcbbadc91d4994afae3104ab19e8367612e3f7c`，原 master 为 `ca75457dc01cc8f54087b48265fd6013a3f353bb`。

原 master 是无父提交的整包导入，与 main 无共同祖先。普通 merge 和 GitHub PR 因此不能正常比较两条历史。整合先在 master 的工作树恢复 main 文件和功能，再接入 master 的 CNN 增量；本地以保留双方历史的合并提交连接 main，不改写原提交、不强制推送。

main 中的全部文件均保留，恢复它的 AE/P95、可信 AWB、RAW 直方图、十三种显示模式、颜色与形状多目标、运动检测、帧槽元数据、相应文档与测试源码。保留 master 的模型训练、量化、UART 加载、固定框 CNN 和独立手势相关文件。

整合提交包含 main 后，后续可将 master 作为源分支合入 main；远端尚未推送。若 main 后续新增提交，需再次 fetch 并正常整合这些增量。无需使用 `--force`，也无需在 GitHub 上重新导入文件。

## SW2 接线与行为

引脚依据用户提供目录下的 `9_康芯开发板使用手册及实验平台/HX1P35B开发板引脚分配汇总.docx`：SW1=A4，SW2=B4。SW2 端口为 `I_fruit_switch`，LVCMOS33、内部下拉，高电平启用。

- SW2 OFF：隐藏水果标签和固定框，显示 main 的颜色/形状/运动检测；后台继续准备完整空背景，供下次识别使用。
- SW2 ON：消抖后连续运行水果识别，显示水果标签与固定框，隐藏颜色/运动检测的标签和框；K4 不参与水果启停。
- 开机即 ON：在权重就绪且完成首次背景采集后自动进入识别，不需要先按 K4。首次采背景时应保持中央区域为空。
- OFF 时已经开始的捕获、预处理、推理和 DDR 请求继续完成，但旧推理结果被丢弃；再次 ON 也不能发布这批旧结果。SW2 不参与任何 DDR 或模型复位，权重无需因开关切换重新加载。
- SW2 经两级同步和约 20 ms 消抖进入识别域；显示可见性在 HDMI 域独立同步并于帧首锁存，避免同帧混合两种叠加。

SW1 仍控制延迟面板；K1 保留十三模式，K2 保留红/绿/蓝/运动循环。水果输入独立抽取自显示特效之前的彩色 AWB 流；两种模式共用相机、视频、DDR 仲裁及 HDMI。

## 新工程与冻结版本

根目录两份 `.al` 默认运行 main 图像链路（`ENABLE_HANDCNN=0`），不引用被 Git 忽略的模型 ROM。`prepare_handfixed_project.py` 在生成独立候选时启用 CNN，并加入模型配置/程序 ROM；水果生成器进一步启用 `FRUIT_SWITCH_CONTROL=1`、五分类解码、128×128 RGB 与 A12 缓存。

本次只生成新的 `build/fruit/td_main_sw2/handfixed_candidate.al`。以下命令只生成源码快照和工程，不编译：

```powershell
python -B verification/prepare_fruit128_project.py --model build/fruit/weights --output build/fruit/td_main_sw2
```

该目录已经存在时入口拒绝覆盖。若再次准备修改后的版本，选用另一个位于 `build/fruit/` 下的新目录，并在未来手动构建或加载时显式选择该目录。

旧 `build/fruit/td`、`build/gesture/td`、权重、历史验证记录和现有 bit 保持原内容。旧 bit 不具备这次新增的 SW2 行为；旧 bit 的资源和时序不能证明整合版满足约束。

## 静态核对

```powershell
python -B verification/check_merge_readiness.py --project build/fruit/td_main_sw2/handfixed_candidate.al
```

检查 main 文件保留、十三个核心算法文件与 main 一致、Python 源码语法解析、SW 引脚唯一性、两份主工程与新水果工程的文件路径和具名模块接口、源码快照哈希、模型哈希、视频/模型/快照内存边界。

视频的四个紧凑帧槽结束于字节地址 `0x00c00000`，水果权重从该地址开始；两块原彩色快照起始于 `0x00e00000` 和 `0x01100000`。保留独立 DDR 写地址/写数据握手及按顺序返回的所有者信息，避免视频读回数据被 CNN 接收。

检查器只读取和解析文本，不能验证综合结果、运行行为、资源上限、时序或板上识别效果。main 与水果逻辑同时保留后的 Slice、ERAM、DSP 用量尚未验证，可能需要进一步压缩。当前没有整合版可下载文件。
