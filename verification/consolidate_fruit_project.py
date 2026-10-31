"""Install the verified fruit project at the user's single canonical TD entry."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
LATEST=ROOT/'build/fruit_main_retrained_20261101'
FROZEN=LATEST/'build/fruit/td_background_fix_20261101'
OUT=ROOT/'td_project/anlogic_edge_osd.al'
AUDIT=ROOT/'build/canonical_project_migration_20261101'

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def destination(path):
    relative=path.relative_to(FROZEN/'sources')
    if relative.parts[0]=='candidate':
        return ROOT/'user_source/hdl_source/fruit_merged'/relative.name
    assert relative.parts[0] in ('user_source','td_project'),relative
    return ROOT/relative

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    verification=json.loads((FROZEN/'verification.json').read_text(encoding='utf-8'))
    assert verification['status']=='passed'
    for row in json.loads((FROZEN/'sources.json').read_text()):
        assert sha(Path(row['snapshot']))==row['sha256'],row['snapshot']
    copies={destination(src):src for src in (FROZEN/'sources').rglob('*') if src.is_file()}
    copies[ROOT/'user_source/hdl_source/flash/fruit_flash_programmer.v']=LATEST/'user_source/hdl_source/flash/fruit_flash_programmer.v'
    # Model is not embedded in the .al: keep a matching canonical export for
    # future maintenance. Existing fixtures/logs stay archived with their model.
    weights=LATEST/'build/fruit/weights'
    model_files=['model.bin','model.hex','model.json','calibration.json','evaluation.json',
                 'handfixed_config.v','handfixed_program.v','handcnn_normalize.v',
                 'handcnn_confidence.v','fruitfixed_decode.v','fruitfixed_result_filter.v']
    for name in model_files:
        copies[ROOT/'build/fruit/weights'/name]=weights/name
    assert sha(weights/'model.bin')==verification['model_sha256']
    source_project=(FROZEN/'handfixed_candidate.al').read_text(encoding='utf-8')
    def rewrite_file(match):
        src=Path(match[1])
        if not src.is_absolute():src=(FROZEN/src).resolve()
        target=destination(src)
        return '<File Path="../'+target.relative_to(ROOT).as_posix()+'">'
    project=re.sub(r'<File Path="([^"]+)">',rewrite_file,source_project)
    project=re.sub(r'(<Project Version="3" Minor="2" Path=")[^"]*',
                   lambda m:m[1]+OUT.parent.as_posix(),project)
    project=project.replace('<Name>handfixed_candidate</Name>','<Name>anlogic_edge_osd</Name>')
    assert 'td_background_fix_20261101' not in project and 'fruit_main_retrained_20261101' not in project
    planned=[]
    for target,src in sorted(copies.items()):
        digest=sha(src)
        if not target.is_file() or sha(target)!=digest:
            planned.append(dict(source=str(src),target=str(target),sha256=digest,
                                previous_sha256=sha(target) if target.is_file() else None))
    print(json.dumps(dict(target_project=str(OUT),files_to_copy=len(copies),
        changed_or_new_files=len(planned)),indent=2))
    if not args.apply:return
    if AUDIT.exists():raise SystemExit('Migration audit already exists; refusing to overwrite backup')
    AUDIT.mkdir(parents=True)
    # Verify all moves stay inside the workspace and never replace an archive.
    moves=[(ROOT/'td_project/anlogic_edge_osd_Runs',AUDIT/'previous_runs'),
           (ROOT/'build/fruit/weights',AUDIT/'previous_weights')]
    for source,target in moves:
        assert source.resolve().is_relative_to(ROOT.resolve())
        assert target.resolve().is_relative_to(AUDIT.resolve())
        assert not target.exists()
    backups=AUDIT/'previous_files'
    for row in planned:
        path=Path(row['target'])
        if path.is_file() and not path.is_relative_to(ROOT/'build/fruit/weights'):
            backup=backups/path.relative_to(ROOT)
            backup.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(path,backup)
    backup=backups/OUT.relative_to(ROOT)
    backup.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(OUT,backup)
    for source,target in moves:
        if source.exists():shutil.move(str(source),str(target))
    for target,src in copies.items():
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(src,target)
        assert sha(target)==sha(src)
    OUT.write_text(project,encoding='utf-8')
    # Check every actual project entry resolves into canonical source paths.
    section=re.search(r'<Source_Files>.*?</Source_Files>',project,re.S)[0]
    xml=ET.fromstring(section.replace('P&R','P_R'))
    for entry in xml.iter('File'):
        path=(OUT.parent/entry.attrib['Path']).resolve()
        assert path.is_file() and path.is_relative_to(ROOT)
        assert path in copies,path
    manifest=dict(status='installed',canonical_project=str(OUT),
        verified_source_project=str(FROZEN/'handfixed_candidate.al'),
        model_sha256=verification['model_sha256'],project_sha256=sha(OUT),
        files=[dict(path=str(p.relative_to(ROOT)),sha256=sha(p)) for p in sorted(copies)],
        changed_or_new=planned,previous_runs=str(AUDIT/'previous_runs'),
        previous_weights=str(AUDIT/'previous_weights'),place_route_run=False,board_programmed=False)
    (AUDIT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    print('CANONICAL_PROJECT_INSTALLED',OUT)

if __name__=='__main__':main()
