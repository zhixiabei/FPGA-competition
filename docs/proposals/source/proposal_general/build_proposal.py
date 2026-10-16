from pathlib import Path
from zipfile import ZipFile
import hashlib
import importlib.util
import json
from lxml import etree

ROOT = Path(__file__).resolve().parents[4]
TMP = Path(__file__).resolve().parent
SOURCE = Path(r'C:\Users\1\Downloads\《数字系统综合实践》开题表-模版 (1).docx')
OUTPUT = ROOT / 'docs' / 'proposals' / '《数字系统综合实践》开题表_安路2_实时数字图像处理系统.docx'
SPEC = importlib.util.spec_from_file_location('form_helpers', TMP.parent / 'proposal' / 'build_proposal.py')
helpers = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helpers)
replace_cell = helpers.replace_cell
q = helpers.q
NS = helpers.NS

CONTENT = [
('h', '1. 意义（撰写人：左晓博）'),
('p', '实时数字图像处理是智能视觉、工业检测和嵌入式系统的重要技术基础。视频系统不仅需要完成图像采集与显示，还需要在连续数据输入的条件下进行算法计算、数据缓存和结果标注，因此对处理速度、接口协同与运行稳定性有较高要求。本项目围绕安路赛题二，构建从摄像头输入到高清显示输出的完整图像处理系统。'),
('p', '项目拟利用安路 PH1P35 FPGA 的并行处理能力，将灰度变换、二值化、边缘提取及颜色目标检测设计为硬件模块，通过按键切换处理模式，在同一画面中展示处理效果和状态信息，为简单目标定位及视觉算法教学提供可演示、可调整的平台。'),
('p', '实施过程中将综合运用数字逻辑、Verilog、视频接口和图像处理知识，重点解决流水线同步、跨时钟传输、缓存调度及资源约束等问题。通过功能仿真、上板调试和量化测试，形成完整的系统设计与验证能力，并为后续视觉增强和运动检测功能预留扩展接口。'),
('h', '2. 主要内容（撰写人：左晓博、尚一卓）'),
('p', '以 HX1P35A 开发板和安路 PH1P35MDG324 芯片为核心，按照赛题要求完成 MIPI 摄像头采集、FPGA 图像处理、DDR 视频缓存、HDMI 实时显示及 OSD 信息叠加。系统面向桌面彩色物体观察与定位演示，在基础功能完成后增加目标检测、多算法切换及参数调节。'),
('b', '系统组成与数据流'),
('flow', 'MIPI 摄像头 → 视频接收与像素转换 → 图像处理'),
('flow', '处理后视频 → DDR 帧缓存 → OSD 合成 → HDMI 显示'),
('flow', '目标统计与帧状态 → 结果寄存器 → OSD 标注'),
('flow', '板载按键与开关 → 模式选择、阈值调节和状态控制'),
('b', '（1）视频采集与显示（撰写人：左晓博）'),
('p', '完成摄像头初始化、MIPI 数据接收、像素格式转换、DDR 读写和 HDMI 输出时序，建立连续视频通路。目标输出格式为 1280×720、60 Hz。根据实物摄像头及配套例程配置采集模式，处理帧同步、行同步和有效像素信号，保证图像完整、颜色顺序正确且无持续错位。'),
('b', '（2）基础图像处理与视觉增强（撰写人：左晓博）'),
('p', '在 FPGA 内实现灰度变换、阈值二值化及 Scharr 边缘提取，提供原图与处理图的对比显示模式。边缘检测采用邻域窗口和流水线结构，可调节二值化及边缘阈值。结合噪声情况增加小窗口滤波或二值噪点去除，自主完成算法模块和接口适配，并与参考例程进行效果及资源比较。'),
('b', '（3）颜色目标检测与标注（撰写人：尚一卓）'),
('p', '以室内场景中的单个红色物体为主要检测对象，结合颜色比例、亮度下限和区域面积门限提取目标，统计包围框与中心坐标，在原始画面上显示检测框和坐标。设置目标丢失与重新进入的状态处理，支持物体缓慢移动时连续更新标注；演示条件限定为背景中无明显同色干扰物。'),
('b', '（4）OSD 与多模式交互（撰写人：尚一卓）'),
('p', '在视频输出中叠加“安路”Logo、当前模式、算法阈值、目标坐标及运行状态。利用按键或拨码开关切换原图、灰度、二值、边缘和目标检测等模式，并对按键进行消抖。显示参数在帧边界更新，避免一帧内出现不同模式混合或标注跳变。'),
('b', '（5）性能优化与进阶功能（共同完成）'),
('p', '通过流水线划分、行缓存复用和运算位宽优化，提高处理实时性并控制逻辑、片内存储及 DSP 占用。完成主要功能后，择优实现自动曝光、白平衡或帧差运动检测，增加延迟和帧状态可视化。进阶功能按资源与进度逐项验证，不作为基础功能完成的前提。'),
('h', '3. 技术路线（撰写人：左晓博、尚一卓）'),
('b', '（1）建立平台并打通视频通路'),
('p', '阅读选题指南、开发板手册、原理图及配套接口例程，核对摄像头、MIPI、HDMI、按键和 DDR 的连接关系。使用安路 TD 完成工程配置、综合、布局布线与配置文件生成，结合 HDL 仿真工具开展功能验证。先用彩条验证 HDMI，再接入摄像头检查原图，逐级定位采集、缓存和显示问题。'),
('b', '（2）将图像算法转化为流式硬件'),
('p', '灰度处理采用定点加权与移位运算，二值化采用阈值比较；Scharr 边缘提取通过行缓存生成 3×3 邻域，计算水平、垂直梯度，再以绝对值和近似梯度幅值完成边缘判定。先建立软件定点参考模型，明确位宽、舍入、饱和及图像边界处理规则，再用 Verilog 实现并逐像素比对。'),
('p', '各模块统一像素与同步信号接口，按照处理延迟同步传递帧首、行尾和有效标记。输入为多像素并行数据时，保持像素顺序及跨组邻域连续性；通过流水线分级缩短关键路径。算法模块持续接收输入视频，不通过暂停摄像头规避吞吐量不足。'),
('b', '（3）实现颜色分割与目标定位'),
('p', '先使用亮度下限抑制暗噪声，再以红、绿、蓝通道的比例和差值筛选红色像素，减小仅采用固定单通道阈值带来的误检。根据需要对二值掩膜进行小窗口滤波，并在指定识别区域内累计有效像素数及坐标极值，得到目标面积与包围框，以包围框中心作为定位坐标。'),
('p', '帧末根据面积和尺寸门限判定目标是否有效，对框坐标进行适度平滑，连续丢失后清除标注。该方案主要针对单个颜色目标；存在多个同色物体时可能合并为一个区域，需记录这一边界条件，并在后续扩展中评估连通域筛选。阈值通过独立调试样本确定，验收样本不参与调参。'),
('b', '（4）完成缓存、跨时钟与叠加同步'),
('p', '使用异步 FIFO 连接采集、存储及显示时钟域，利用帧缓存管理读写地址和完整帧状态，防止同一帧被覆盖造成画面撕裂。按实际像素格式、并行度及 DDR 效率核算带宽，并预留消隐、突发访问和时钟偏差余量。检查复位释放顺序、FIFO 水位和异常恢复逻辑。'),
('p', '将检测结果与视频帧号关联，在输出对应帧时读取包围框并叠加，避免使用错帧坐标。Logo 与字符采用 ROM 字模，通过像素坐标选择背景、文字和边框；按键更新的模式与阈值在帧边界统一生效。跨时钟控制信息采用同步或握手机制，不能直接采样多位变化总线。'),
('b', '（5）分层验证与性能测量'),
('p', '模块仿真覆盖全黑、全白、渐变、棋盘格和已知边界图案，检查输出结果、有效像素数量、首末行及边界补齐。整机仿真验证模式切换、缓存读写和同步信号对齐；上板后使用 ChipWatcher 辅助观察初始化、帧状态及 FIFO 状态，检查时序报告和资源利用率。'),
('p', '目标测试覆盖不同位置、大小、移动速度和适度光照变化，记录检出率、误报率及框位置误差。延迟测试采用可见光变化或计时画面作输入，比较真实事件与显示输出；内部帧号和时间计数用于辅助定位等待环节，不能仅凭帧计数直接认定端到端延迟。'),
('b', '（6）实施安排与问题处理'),
('p', '第 1～2 周：完成需求分析、接口核对和原图显示；第 3～4 周：完成灰度、二值、边缘处理及软件比对；第 5～6 周：完成目标定位、OSD、多模式切换及系统联调；第 7～8 周：开展性能测试与优化，择优实现进阶功能，整理报告和演示视频。具体起止日期依据课程安排确定。'),
('p', '出现花屏或错位时，优先检查接口时序、帧标记和缓存完整性；颜色检测不稳定时，分析光照、曝光及背景干扰并调整阈值；时序或资源不足时，采用流水线和运算复用，优先保证基础视频通路。对进阶算法设置旁路，保留可复现的稳定版本。'),
('h', '4. 预期成果（撰写人：尚一卓）'),
('p', '完成一套基于安路 PH1P35 的实时数字图像处理演示系统，实现摄像头输入、FPGA 算法处理和 HDMI 输出，能够现场切换图像模式、观察目标检测结果并调节参数。以下量化指标为本项目设计目标，区别于赛题的最低要求，最终以仿真和上板测试结果为准。'),
('p', '① 基础功能：实现 MIPI 采集和连续 HDMI 显示，目标输出 1280×720、60 Hz；完成至少一种 FPGA 图像处理算法，并叠加包含“安路”Logo 的图形或文字信息。分别记录摄像头有效帧率与显示刷新率。'),
('p', '② 算法与交互：计划实现灰度、二值和边缘提取三种处理算法，提供原图及目标检测显示，形成不少于 5 种可切换模式。按键响应目标不超过 200 ms，模式在完整帧边界生效，切换过程无持续花屏或画面失步。'),
('p', '③ 目标检测：在均匀室内照明、单个红色物体且无明显同色干扰的条件下，目标更新频率不低于 20 次/s。使用不少于 200 幅独立测试图像，其中有目标与无目标图像各不少于 100 幅；检出率目标不低于 90%，无目标图像误报率目标不高于 5%。'),
('p', '④ 检测判据：测试目标的宽、高均不小于画面对应边长的 5%；人工标注包围框，预测框与标注框的交并比达到 0.5 时计为正确检出，并报告平均中心位置误差。测试光照、背景和运动条件同时列入记录，避免将限定场景结果泛化为任意场景能力。'),
('p', '⑤ 稳定性与实时性：连续运行不少于 30 min，无明显花屏、缓存溢出或死机；端到端视频延迟目标不超过 100 ms，并记录显示器及测试方式。给出逻辑、ERAM、DSP 占用与时序分析结果，主要时钟域满足设计约束。'),
('p', '⑥ 交付成果：完整 RTL、工程与时序约束、配置文件、软件参考模型、仿真测试文件、硬件连接说明、测试报告和演示视频。自动曝光、白平衡、帧差运动检测及延迟可视化按实际完成情况分别展示，不以计划代替测试结果。'),
('p', '设计依据：所附《FPGA 赛道参赛选题指南》安路选题二第 2.1～2.7 节，以及 HX1P35A 开发板手册和配套摄像头采集、图像处理、OSD 接口例程。'),
]

BUDGET = [
('b', '成本预算（撰写人：左晓博、尚一卓）'),
('p', '按开发板、配套 MIPI 摄像头、电源、下载线、显示器及开发电脑可复用测算，以下金额为新增材料预算额度，采购时按实际报价核定。若主设备尚未具备，须另行计入购置费用。'),
('p', '1. HX1P35A 开发板、配套摄像头、电源及下载线：复用 1 套，新增预算 0 元。'),
('p', '2. HDMI 显示器与开发电脑：各复用 1 台，新增预算 0 元。'),
('p', '3. HDMI 连接线：1 根，HDMI 1.4 或以上、长度不超过 2 m，预算 20 元。'),
('p', '4. 摄像头固定支架：1 套，尺寸适配现有模组，预算 40 元。'),
('p', '5. USB 漫射补光灯：1 套，预算 40 元。'),
('p', '6. 彩色测试物与背景材料：1 套，预算 20 元。'),
('p', '7. 杜邦线与固定件等耗材：1 批，预算 20 元。'),
('b', '预计新增材料合计 140 元。'),
('p', '拟通过校内耗材采购或正规电商平台购置。具体商品型号和购买链接在核对现有配件、接口尺寸及商家报价后补充；已有材料直接复用，并相应核减新增预算。'),
]

def main():
    contract=TMP/'artifact.md'
    assert contract.exists(), 'Template contract missing'
    expected_hash='8b2c0db45f0709e5ecd94fb137fd1bd8a1fdc327b19328c501347768903809fb'
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest()==expected_hash
    with ZipFile(SOURCE) as z:
        infos=z.infolist()
        parts={i.filename:z.read(i.filename) for i in infos}
    root=etree.fromstring(parts['word/document.xml'])
    baseline_section=etree.tostring(root.find('.//w:sectPr',NS))
    table=root.find('w:body/w:tbl',NS)
    baseline_grid=etree.tostring(table.find('w:tblGrid',NS))
    rows=table.findall('w:tr',NS)
    replace_cell(rows[2].findall('w:tc',NS)[4],[('p','视频采集与缓存、图像算法、HDMI 通路及 FPGA 硬件调试')])
    replace_cell(rows[3].findall('w:tc',NS)[4],[('p','目标检测与 OSD、按键交互、性能测试及资料整理')])
    replace_cell(rows[5].findall('w:tc',NS)[1],[('b','安路2：基于安路 PH1P35 的实时数字图像处理系统')])
    replace_cell(rows[6].findall('w:tc',NS)[1],CONTENT)
    replace_cell(rows[7].findall('w:tc',NS)[1],BUDGET)
    parts['word/document.xml']=etree.tostring(root,encoding='UTF-8',xml_declaration=True,standalone=True)
    settings=etree.fromstring(parts['word/settings.xml'])
    update=settings.find('w:updateFields',NS)
    if update is None: update=etree.SubElement(settings,q('updateFields'))
    update.set(q('val'),'true')
    parts['word/settings.xml']=etree.tostring(settings,encoding='UTF-8',xml_declaration=True,standalone=True)
    OUTPUT.parent.mkdir(parents=True,exist_ok=True)
    with ZipFile(OUTPUT,'w') as z:
        for info in infos:z.writestr(info,parts[info.filename])
    with ZipFile(SOURCE) as a, ZipFile(OUTPUT) as b:
        changed=[n for n in a.namelist() if a.read(n)!=b.read(n)]
    assert set(changed)=={'word/document.xml','word/settings.xml'}
    assert baseline_section==etree.tostring(root.find('.//w:sectPr',NS))
    assert baseline_grid==etree.tostring(table.find('w:tblGrid',NS))
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest()==expected_hash
    body=''.join(root.itertext())
    for phrase in ['手语','充分调研','300字左右','ASRPRO','一页不够']:
        assert phrase not in body,phrase
    for phrase in ['2416040221','2416040114','左晓博','尚一卓','MIPI','HDMI','OSD','Logo']:
        assert phrase in body,phrase
    text='\n'.join(t for _,t in CONTENT+BUDGET)
    (TMP/'content.txt').write_text(text,encoding='utf-8')
    (TMP/'validation.json').write_text(json.dumps({'output':str(OUTPUT),'source_sha256':expected_hash,'changed_parts':changed,'characters':len(text),'budget_total':140,'topic_removed':'手语'},ensure_ascii=False,indent=2),encoding='utf-8')
    print(OUTPUT)
    print('Characters:',len(text),'Changed parts:',changed)

if __name__=='__main__': main()
