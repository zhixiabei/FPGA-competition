from pathlib import Path
from zipfile import ZipFile
from lxml import etree
import hashlib,json

src=Path(r'C:\Users\1\Downloads\《数字系统综合实践》开题表-模版 (1).docx')
out=Path(r'D:\vivado_work\anlogic_edge_osd\tmp\proposal')
ns={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
with ZipFile(src) as z:
    inventory=[{'path':x.filename,'size':x.file_size,'sha256':hashlib.sha256(z.read(x.filename)).hexdigest(),'policy':'editable' if x.filename in ('word/document.xml','word/settings.xml') else 'preserve-only'} for x in z.infolist()]
    root=etree.fromstring(z.read('word/document.xml'))
    section=etree.tostring(root.find('.//w:sectPr',ns),encoding='unicode')
(out/'package-inventory.json').write_text(json.dumps(inventory,ensure_ascii=False,indent=2),encoding='utf-8')
(out/'artifact.md').write_text(f'''# Proposal form template contract

Reference: {src}
SHA-256: {hashlib.sha256(src.read_bytes()).hexdigest()}
Reference render: template-render/page-1.png (one page, inspected). One section.
Rendering: skill render_docx.py with task-local Word PDF engine adapter because LibreOffice is not installed. Installed Word performs repagination; source remains read-only.
Evidence: template-style-evidence.json, package-inventory.json.

## Page and typography
A4 portrait 11907 by 16840 twips. Margins top/right/left 1474, bottom 1402; gutter 284. Header/footer distances 851. Single column; different first-page footer; both footers contain PAGE fields. Preserve all section XML exactly. Title centered bold 16 pt, original text and direct formatting preserved. Body and labels Songti 12 pt. Black borders 0.5 pt. Body line grid 312 twips. Preserve title, empty header, both footers and all styles.

## Table and editable slots
One centered fixed-width table 9325 twips. Grid 1314,1233,1417,1355,4006. Cell side margins 108 twips. Rows have minimum, not exact, heights. Preserve grid, borders, merges, labels and original blank third-member row. Body continues across pages (reference explicitly permits 3-5 pages).
word/document.xml / body / tbl[1] / tr[3]/tc[5]: left member proposed responsibilities.
tr[4]/tc[5]: second member proposed responsibilities.
tr[6]/tc[2]: project title, replace generic topic with sign recognition proposal.
tr[7]/tc[2]: four narrative sections, replace all red instructional text; retain 12 pt Songti and source bold-heading pattern; add paragraphs, first-line indent and keep-next for readable flow.
tr[8]/tc[2]: budget, replace illustrative OLED/ASRPRO list with task-specific cost allowances. State reuse assumptions and outstanding merchant links instead of inventing quotes.
Group ID, student IDs and names must remain exact. No third member is inferred. Proposed responsibilities and authorship are a draft allocation.

## Package and fields
All parts preserve-only except document.xml and settings.xml. No drawings, text boxes, footnotes, comments or content controls in the body. Empty header; PAGE fields only in preserved footers. Set updateFields=true in settings so fields refresh on open; Word repaginates preview without resaving package.
Inventory contains all package parts and relationship hashes. No new relationships required.

## Fidelity gates
Source hash unchanged. Preserve-only members byte-for-byte equal. Section XML and table grid unchanged. Final 3-5 pages; every page inspected as PNG. No red instructions, clipping, blank trailing page, orphan heading or missing characters. Record output text and package verification. Page count may grow only from authorized filling of body and budget slots. Source and final image comparison is a scope check; no unrelated title or table-grid changes.

## Section evidence
{section}
''',encoding='utf-8')
print('Template contract and inventory recorded.')
