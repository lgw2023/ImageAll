#!/usr/bin/env python3
"""Install a release.py accepted immutable artifact without repeating completed media tests."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
from payload_version import payload_version

p=argparse.ArgumentParser();p.add_argument('--release',type=Path,required=True);p.add_argument('--destination',type=Path,action='append',required=True)
a=p.parse_args();report=json.loads(a.release.read_text());app=Path(report['app'])
if report.get('gatePassed') is not True or payload_version(app)!=report['appContentIdentity']:
    raise SystemExit('Release identity changed or acceptance missing')
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
running=[line.strip() for line in subprocess.check_output(['/bin/ps','-axo','comm='],text=True).splitlines()]
for path in a.destination:
    if str(path.absolute()/'Contents/MacOS/ImageAll') in running: raise SystemExit('Quit the daily App before replacing it')
for path in a.destination:
    path=path.absolute();path.parent.mkdir(parents=True,exist_ok=True)
    work=Path(tempfile.mkdtemp(prefix='.imageall-install-',dir=path.parent));candidate=work/'ImageAll.app';old=work/'old.app'
    try:
        subprocess.run(['/bin/cp','-cR',str(app),str(candidate)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(candidate)],check=True)
        if path.exists(): path.rename(old)
        try: candidate.rename(path)
        except BaseException:
            if old.exists(): old.rename(path)
            raise
        if old.exists(): shutil.move(str(old),str(a.release.parent/('backup-'+uuid.uuid4().hex+'.app')))
        report['installed'].append(str(path))
        a.release.write_text(json.dumps(report,indent=2)+'\n')
    finally:
        if old.exists(): print('Recovery App retained at',old)
        elif work.exists(): shutil.rmtree(work)
print(json.dumps({'installed':report['installed'],'identityVerified':True},indent=2))
