# Proposal form template contract

Reference: C:\Users\1\Downloads\《数字系统综合实践》开题表-模版 (1).docx
SHA-256: 8b2c0db45f0709e5ecd94fb137fd1bd8a1fdc327b19328c501347768903809fb
Reference render: template-render/page-1.png (one page, inspected). One section.
Rendering: skill render_docx.py with task-local Word PDF engine adapter because LibreOffice is not installed. Installed Word performs repagination; source remains read-only.
Evidence: template-style-evidence.json, package-inventory.json.

## Page and typography
A4 portrait 11907 by 16840 twips. Margins top/right/left 1474, bottom 1402; gutter 284. Header/footer distances 851. Single column; different first-page footer; both footers contain PAGE fields. Preserve all section XML exactly. Title centered bold 16 pt, original text and direct formatting preserved. Body and labels Songti 12 pt. Black borders 0.5 pt. Body line grid 312 twips. Preserve title, empty header, both footers and all styles.

## Table and editable slots
One centered fixed-width table 9325 twips. Grid 1314,1233,1417,1355,4006. Cell side margins 108 twips. Rows have minimum, not exact, heights. Preserve grid, borders, merges, labels and original blank third-member row. Body continues across pages (reference explicitly permits 3-5 pages).
word/document.xml / body / tbl[1] / tr[3]/tc[5]: left member proposed responsibilities.
tr[4]/tc[5]: second member proposed responsibilities.
tr[6]/tc[2]: project title, retain the official real-time digital image processing topic; remove all sign-language content from the new proposal.
tr[7]/tc[2]: four narrative sections, replace all red instructional text; retain 12 pt Songti and source bold-heading pattern; add paragraphs, first-line indent and keep-next for readable flow.
tr[8]/tc[2]: budget, replace illustrative OLED/ASRPRO list with task-specific cost allowances. State reuse assumptions and outstanding merchant links instead of inventing quotes.
Group ID, student IDs and names must remain exact. No third member is inferred. Proposed responsibilities and authorship are a draft allocation.

## Package and fields
All parts preserve-only except document.xml and settings.xml. No drawings, text boxes, footnotes, comments or content controls in the body. Empty header; PAGE fields only in preserved footers. Set updateFields=true in settings so fields refresh on open; Word repaginates preview without resaving package.
Inventory contains all package parts and relationship hashes. No new relationships required.

## Fidelity gates
Source hash unchanged. Preserve-only members byte-for-byte equal. Section XML and table grid unchanged. Final 3-5 pages; every page inspected as PNG. No red instructions, clipping, blank trailing page, orphan heading or missing characters. Record output text and package verification. Page count may grow only from authorized filling of body and budget slots. Source and final image comparison is a scope check; no unrelated title or table-grid changes.

## Section evidence
<w:sectPr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas" xmlns:cx="http://schemas.microsoft.com/office/drawing/2014/chartex" xmlns:cx1="http://schemas.microsoft.com/office/drawing/2015/9/8/chartex" xmlns:cx2="http://schemas.microsoft.com/office/drawing/2015/10/21/chartex" xmlns:cx3="http://schemas.microsoft.com/office/drawing/2016/5/9/chartex" xmlns:cx4="http://schemas.microsoft.com/office/drawing/2016/5/10/chartex" xmlns:cx5="http://schemas.microsoft.com/office/drawing/2016/5/11/chartex" xmlns:cx6="http://schemas.microsoft.com/office/drawing/2016/5/12/chartex" xmlns:cx7="http://schemas.microsoft.com/office/drawing/2016/5/13/chartex" xmlns:cx8="http://schemas.microsoft.com/office/drawing/2016/5/14/chartex" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" xmlns:w10="urn:schemas-microsoft-com:office:word" xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml" xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup" xmlns:wpi="http://schemas.microsoft.com/office/word/2010/wordprocessingInk" xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" xmlns:wpsCustomData="http://www.wps.cn/officeDocument/2013/wpsCustomData"><w:footerReference r:id="rId5" w:type="first"/><w:headerReference r:id="rId3" w:type="default"/><w:footerReference r:id="rId4" w:type="default"/><w:pgSz w:w="11907" w:h="16840"/><w:pgMar w:top="1474" w:right="1474" w:bottom="1402" w:left="1474" w:header="851" w:footer="851" w:gutter="284"/><w:pgNumType w:start="1"/><w:cols w:space="425" w:num="1"/><w:titlePg/><w:docGrid w:type="lines" w:linePitch="312" w:charSpace="0"/></w:sectPr>

## Current requested variant
New standalone 3-5 page form based strictly on Anlogic topic two. Core: MIPI acquisition, FPGA processing, stable HDMI, Anlogic Logo and OSD. Main extensions: color target localization and multi-algorithm switching; exposure, white balance and frame difference optional. Use inherited template-render and package-inventory evidence in ../proposal. Proposed member roles and reuse-based budget are explicitly provisional. Preserve the prior deliverable.
