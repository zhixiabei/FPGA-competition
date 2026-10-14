from pathlib import Path
from zipfile import ZipFile
from copy import deepcopy
import hashlib
import json
from lxml import etree

ROOT = Path(r'D:\vivado_work\anlogic_edge_osd')
TMP = ROOT / 'tmp' / 'proposal'
SOURCE = Path(r'C:\Users\1\Downloads\《数字系统综合实践》开题表-模版 (1).docx')
OUTPUT = ROOT / 'output' / 'docs' / '《数字系统综合实践》开题表_安路2_手语识别.docx'
W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
NS = {'w': W}
def q(name): return '{' + W + '}' + name

content = [
('h', '1. 意义（撰写人：左晓博）'),
('p', '手语识别能够将视觉动作转换为可读文字，为手语学习、简单信息表达和无障碍交互提供技术支持。本项目拟面向课堂演示与手语入门训练，识别一组含义明确、手形差异较大的手语词项，在摄像头画面中实时显示识别结果，使观察者能够直观地理解动作与文字之间的对应关系。'),
('p', '项目以安路 PH1P35 FPGA 为核心，将图像采集、手部区域分割、特征提取、分类判断与字幕叠加构成完整系统，探索在有限逻辑、存储及运算资源下实现本地视觉识别的方法，减少演示时对网络和外部计算设备的依赖。'),
('p', '通过本项目，可以综合运用数字逻辑、Verilog 硬件描述、视频接口、图像处理及系统调试知识，并以准确率、响应时间和资源占用评价方案。本阶段聚焦小词表静态手语，简单动态手语作为扩展，不将识别单个手形等同于完整手语语句翻译。'),
('h', '2. 主要内容（撰写人：左晓博、尚一卓）'),
('p', '围绕安路赛道选题二“基于安路 PH1P35 的实时数字图像处理系统”，采用 HX1P35A 开发板构建手语识别演示装置。在实现 MIPI 采集、FPGA 图像处理、HDMI 显示和“安路”Logo 叠加的基础上，增加手部区域识别、文字标注与按键交互。'),
('b', '系统组成与数据流'),
('flow', 'MIPI 摄像头 → 视频解码与图像预处理'),
('flow', '显示通路：DDR 帧缓存 → OSD 叠加 → HDMI 显示器'),
('flow', '识别通路：手部分割 → 特征提取 → 分类与稳定判决'),
('flow', '识别结果送入 OSD；板载按键控制模式和参数'),
('b', '（1）视频采集与显示模块（撰写人：左晓博）'),
('p', '完成摄像头配置、MIPI 数据接收、像素格式转换、DDR 帧缓存及 HDMI 时序控制，建立连续视频通路。以 1280×720 输出为目标，保持帧、行和有效像素信号对齐，并通过彩条、原图和帧计数检查采集及显示状态。摄像头配置以实物型号和对应例程为准。'),
('b', '（2）手部区域分割模块（撰写人：左晓博）'),
('p', '在画面中设置单手识别引导框，结合颜色阈值、背景标定与二值形态学运算提取手部前景，抑制背景干扰和孤立噪点。输出二值掩膜、前景面积、包围框及位置统计，并提供原图与分割结果切换功能，便于调参与演示。'),
('b', '（3）手语特征与分类模块（撰写人：尚一卓）'),
('p', '拟选取 6 类适合单手静态演示的手语词项，优先从数字类词项中筛选；采样前核对规范动作与词义并固定类别表。对手部图像提取网格占用率、行列投影及几何特征，在电脑端训练线性支持向量机，随后将分类参数定点化，在 FPGA 上完成特征计算和分类。'),
('b', '（4）字幕显示与交互模块（撰写人：尚一卓）'),
('p', '使用屏幕信息叠加（OSD）显示手语文字、识别状态、引导框、处理模式和“安路”Logo。通过连续判决与空手检测降低字幕抖动；无有效手部或判别依据不足时显示“未识别”。按键用于切换原图、二值图、识别显示模式，以及背景标定和结果清除。'),
('b', '（5）系统验证与功能扩展（共同完成）'),
('p', '先完成静态词表的采集、识别和显示闭环，再尝试增加 1～2 类具有明确起止动作的动态手语，利用位置轨迹或手形状态序列进行判断。同步记录识别准确率、帧率、延迟和资源占用；动态功能独立验收，不影响基础视频通路与静态识别功能。'),
('h', '3. 技术路线（撰写人：左晓博、尚一卓）'),
('b', '（1）明确场景并建立样本集'),
('p', '首先限定室内均匀照明、固定摄像头、较简洁背景和单手进入引导框的工作条件，目标距离约 0.4～0.8 m。采集不少于 5 名参与者的数据，每类每人不少于 30 次独立动作，6 类合计不少于 900 次，并另采集空手和非目标动作作为负样本。记录类别、人员、场景与采集批次。'),
('p', '按参与者划分训练集、验证集和测试集，拟采用 3 人训练、1 人调参、1 人独立测试，避免同一段视频的相邻帧同时进入训练与测试。测试集不参与阈值选择或模型训练；扩展采样时增加手部尺寸、位置和适度光照变化。'),
('b', '（2）先做软件原型再确定硬件参数'),
('p', '在电脑端使用 Python/OpenCV 建立分割、形态学处理、特征提取和线性分类原型，分析各类混淆情况。优先试验 8×8 网格占用率、水平与垂直投影等低维特征，比较软件浮点与定点结果，据此确定特征位宽、权重缩放和拒识阈值。电脑仅用于离线训练、参数导出和测试分析。'),
('b', '（3）实现适合 FPGA 的流式图像处理'),
('p', '使用 Verilog 实现颜色空间转换、阈值分割及 3×3 二值形态学运算，通过行缓存生成邻域窗口，控制完整帧缓存数量。识别引导区降采样至约 160×120，将手部二值图保存在片内小缓存中，帧末依据包围框重新统计归一化网格及投影特征，缓解手部位置和大小变化的影响。'),
('p', '显示通路保持连续运行，识别通路按帧调度；双缓冲或分时访问用于避免特征读取与下一帧写入冲突。模块接口明确有效信号、帧号和流水线延迟，识别通路不得反压摄像头输入。利用现有视频工程作为接口基础，自主实现分割与分类模块。'),
('b', '（4）部署定点分类并稳定输出结果'),
('p', '采用一对其余类别的线性分类方式，将各类权重与偏置存入 ROM，以乘加单元分时完成各类别打分。按仿真结果确定累加位宽和饱和策略，比较最高分与次高分差值并设置拒识条件。使用最近若干次结果的多数判决抑制跳变，加入空手复位，避免旧字幕长时间残留。'),
('p', '分类间隔仅用于判决，不直接解释为概率。识别结果附带对应帧号，在显示帧边界更新字幕；手部框与原始画面沿同一缓存路径对齐，防止框与图像错位。小词表字幕采用预制字模 ROM，减少字库存储开销。'),
('b', '（5）分层仿真与板级调试'),
('p', '先用已知像素图案验证分割和形态学模块，再比较同一输入下软件定点模型与 RTL 特征、分类分数及类别输出。完成综合、布局布线和时序检查后上板，检查帧缓存、跨时钟传输、模式切换与异常恢复；必要时使用 ChipWatcher 观察内部信号。'),
('p', '视频链路延迟采用外部计时画面或光学事件对照测量，帧号用于辅助检查丢帧与错位；识别响应时间从动作进入有效识别条件起算，到字幕稳定显示为止，两项分别记录。对暗光、强光、肤色接近背景和手部出框进行专项测试，记录失效条件并改进阈值及引导提示。'),
('b', '（6）实施安排与风险应对'),
('p', '第 1～2 周：确定词表与测试条件，完成视频基础通路及数据采集；第 3～4 周：完成软件原型、数据划分及算法选择；第 5～6 周：实现 FPGA 特征、分类与 OSD 联调；第 7～8 周：开展独立测试、资源及时序优化，整理报告并完成演示。具体起止日期按课程安排调整。'),
('p', '若分割不稳定，优先采用背景标定、漫射补光和位置引导；若相似手形混淆，依据验证集调整特征并补充样本。若资源或时序不足，减少识别分辨率、复用乘加器并降低识别更新频率，优先保证视频连续输出。动态识别在基础指标完成后开展。'),
('h', '4. 预期成果（撰写人：尚一卓）'),
('p', '完成一套可独立演示的手语识别与字幕显示原型：摄像头采集手部动作，FPGA 完成图像处理与分类，HDMI 显示原始画面、手部标注、识别字幕及“安路”Logo。以下指标为设计与验收目标，最终以独立测试和上板实测结果为准。'),
('p', '① 视频显示：目标分辨率 1280×720、HDMI 刷新率 60 Hz；分别记录有效摄像头帧率和识别更新频率，识别更新目标不低于 15 次/s。'),
('p', '② 静态识别：完成不少于 6 类固定词表，在规定场景的独立测试集中总体准确率目标不低于 90%。每类至少测试 30 次独立动作，同时报告混淆矩阵与各类召回率；有效词表样本被拒识仍计入错误。'),
('p', '③ 响应与误触发：静态动作进入有效识别条件后，字幕稳定显示的响应时间目标不超过 500 ms；至少测试 100 次空手或非目标动作，误接受率目标不高于 5%，并记录超时与识别失败情况。'),
('p', '④ 稳定性与交互：连续运行不少于 30 min，无明显花屏、持续画面错位或死机；完成不少于 3 种显示模式切换。报告逻辑、ERAM、DSP 占用和时序结果，识别区域失效时能够提示并恢复。'),
('p', '⑤ 交付资料：完整 RTL 与工程约束、可下载配置文件、软件训练与参数导出脚本、样本与测试记录、仿真文件、系统说明及演示视频。扩展成果为 1～2 类简单动态手语及相应独立测试结果。'),
('p', '设计依据：所附《FPGA 赛道参赛选题指南》安路选题二第 2.3～2.7 节、HX1P35A 开发板资料及摄像头接口例程。手语词项在样本采集前核对规范动作和词义，形成统一的标签与演示说明。'),
]

budget = [
('b', '成本预算（撰写人：左晓博、尚一卓）'),
('p', '按开发板、配套 MIPI 摄像头、显示器、下载线和电源可复用测算，以下为新增材料预算额度，不作为商家实时报价。实际缺少的主设备须另行核价。'),
('p', '1. HX1P35A 开发板、配套摄像头及电源：各 1 套，复用，新增预算 0 元。'),
('p', '2. HDMI 显示器及开发电脑：各 1 台，复用，新增预算 0 元。'),
('p', '3. HDMI 连接线：1 根，支持 720p60、长度不超过 2 m，预算 20 元。'),
('p', '4. 摄像头固定支架：1 套，适配现有模组，预算 40 元。'),
('p', '5. USB 漫射补光灯：1 套，预算 40 元。'),
('p', '6. 纯色背景板：1 张，预算 20 元。'),
('p', '7. 固定件与连接耗材：1 批，预算 20 元。'),
('b', '预计新增材料合计 140 元。'),
('p', '采购渠道拟采用校内耗材采购或正规电商平台；具体商品型号和链接在确认实物尺寸、现有配件及报价后补齐。已有同类材料可直接复用并相应核减预算。'),
]

def paragraph(text, role='p'):
    p=etree.Element(q('p'))
    pr=etree.SubElement(p,q('pPr'))
    etree.SubElement(pr,q('widowControl'),{q('val'):'1'})
    if role in ('h','b'):
        etree.SubElement(pr,q('keepNext'))
    spacing = {q('before'):'70' if role=='h' else '35' if role=='b' else '0', q('after'):'40', q('line'):'240',q('lineRule'):'auto'}
    etree.SubElement(pr,q('spacing'),spacing)
    if role=='p': etree.SubElement(pr,q('ind'),{q('firstLine'):'480'})
    etree.SubElement(pr,q('jc'),{q('val'):'center' if role=='flow' else 'left'})
    r=etree.SubElement(p,q('r'))
    rp=etree.SubElement(r,q('rPr'))
    etree.SubElement(rp,q('rFonts'),{q('ascii'):'宋体',q('hAnsi'):'宋体',q('eastAsia'):'宋体'})
    if role in ('h','b'): etree.SubElement(rp,q('b'))
    etree.SubElement(rp,q('color'),{q('val'):'000000'})
    etree.SubElement(rp,q('sz'),{q('val'):'24'})
    etree.SubElement(rp,q('szCs'),{q('val'):'24'})
    etree.SubElement(r,q('t')).text=text
    return p

def replace_cell(cell, entries):
    for child in list(cell):
        if child.tag != q('tcPr'): cell.remove(child)
    for role, text in entries: cell.append(paragraph(text,role))

def main():
    with ZipFile(SOURCE) as z:
        parts={i.filename:z.read(i.filename) for i in z.infolist()}
        infos=z.infolist()
    source_hash=hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    root=etree.fromstring(parts['word/document.xml'])
    original_sections=[etree.tostring(x) for x in root.findall('.//w:sectPr',NS)]
    rows=root.find('w:body/w:tbl',NS).findall('w:tr',NS)
    replace_cell(rows[2].findall('w:tc',NS)[4],[('p','视频采集与显示、图像预处理、FPGA 系统集成及硬件调试')])
    replace_cell(rows[3].findall('w:tc',NS)[4],[('p','样本采集与分类算法、字幕交互、性能测试及资料整理')])
    replace_cell(rows[5].findall('w:tc',NS)[1],[('b','安路2：基于安路 PH1P35 的实时手语识别与字幕显示系统')])
    replace_cell(rows[6].findall('w:tc',NS)[1],content)
    replace_cell(rows[7].findall('w:tc',NS)[1],budget)
    # Existing paragraphs in the form labels remain untouched. Body cells can
    # span pages, as explicitly allowed by the retained reference template.
    parts['word/document.xml']=etree.tostring(root,encoding='UTF-8',xml_declaration=True,standalone=True)
    settings=etree.fromstring(parts['word/settings.xml'])
    update=settings.find('w:updateFields',NS)
    if update is None: update=etree.SubElement(settings,q('updateFields'))
    update.set(q('val'),'true')
    parts['word/settings.xml']=etree.tostring(settings,encoding='UTF-8',xml_declaration=True,standalone=True)
    OUTPUT.parent.mkdir(parents=True,exist_ok=True)
    with ZipFile(OUTPUT,'w') as zout:
        for info in infos: zout.writestr(info,parts[info.filename])
    with ZipFile(SOURCE) as a,ZipFile(OUTPUT) as b:
        changed=[n for n in a.namelist() if a.read(n)!=b.read(n)]
    assert set(changed)=={'word/document.xml','word/settings.xml'},changed
    assert original_sections==[etree.tostring(x) for x in root.findall('.//w:sectPr',NS)]
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest()==source_hash
    all_text='\n'.join(t for _,t in content+budget)
    assert all(x not in all_text for x in ['充分调研','300字左右','ASRPRO','0.96寸','一页不够'])
    assert '2416040221' in ''.join(root.itertext()) and '2416040114' in ''.join(root.itertext())
    (TMP/'content.txt').write_text(all_text,encoding='utf-8')
    (TMP/'validation.json').write_text(json.dumps({'source_sha256':source_hash,'changed_parts':changed,'content_characters':len(all_text),'output':str(OUTPUT)},ensure_ascii=False,indent=2),encoding='utf-8')
    print(OUTPUT)
    print('Characters:',len(all_text),'Changed parts:',changed)

if __name__=='__main__': main()
