#!/usr/bin/env python3
"""Build, exercise the signed bundled engine, then optionally install with rollback.

No production App test host is launched. Quit the daily App before --install-to.
Keep evidence outside the repository. Default operation stages a verified release only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid
from integration_contract import ROOT
from payload_version import payload_version


def run(args, log, env=None):
    with log.open('a') as output:
        subprocess.run([str(x) for x in args],cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,check=True)


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--evidence',type=Path,required=True)
    p.add_argument('--packages',type=Path)
    p.add_argument('--built-app',type=Path,help='Use a completed build-for-testing artifact instead of building')
    p.add_argument('--previous-app',type=Path,required=True,help='Previous daily App for live upgrade acceptance')
    p.add_argument('--install-to',type=Path,action='append',default=[])
    a=p.parse_args();e=a.evidence.resolve();e.mkdir(parents=True,exist_ok=True)
    if a.built_app: app=a.built_app.resolve()
    else:
        products=e/'products';app=products/'ImageAll.app'
        command=['xcodebuild','-project','ImageAll.xcodeproj','-scheme','ImageAll','-configuration','Debug','-derivedDataPath',e/'DerivedData',f'CONFIGURATION_BUILD_DIR={products}',f'OBJROOT={e}/Intermediates','build-for-testing']
        if a.packages: command+=['-clonedSourcePackagesDirPath',a.packages,'-disableAutomaticPackageResolution']
        run(command,e/'build.log')
    # Freeze the build before testing: Xcode and other sessions may rebuild a shared output path.
    snapshot=e/'tested-build.app'
    if snapshot.exists(): raise RuntimeError('Use a fresh evidence directory')
    subprocess.run(['/bin/cp','-cR',str(app),str(snapshot)],check=True)
    app=snapshot
    env=os.environ.copy();env['DYLD_INSERT_LIBRARIES']=str(app/'Contents/MacOS/ImageAll.debug.dylib')
    tests=['testWorkspaceRecoversOfflineTasksAndMarksProgressUnconfirmed','testFrozenRetryPreservesOriginalRejectsChangedAssetsAndRedactsDiagnostics','testOpenMontageIntakeRejectionIsVisibleButZeroDigestCannotReportSuccess','testOpenMontageLifecycleCancelRecoveryAndRevisionIsolation','testCreativeProgressLocksMutationsAndCancellationRestoresEditing']
    run(['/Applications/Xcode.app/Contents/Developer/usr/bin/xctest','-XCTest',','.join('ImageAllTests.TimeStoryFeatureTests/'+t for t in tests),app/'Contents/PlugIns/ImageAllTests.xctest'],e/'swift-tests.log',env)
    text=(e/'swift-tests.log').read_text()
    if f'Executed {len(tests)} tests, with 0 failures' not in text: raise RuntimeError('Required regression tests did not all execute')
    run(['python3','-B',ROOT/'scripts/openmontage/release_gate.py','--app',app,'--previous-app',a.previous_app,'--evidence',e/'gate'],e/'release-gate.log')
    release=e/'verified-release.app'
    if release.exists(): raise RuntimeError('Use a fresh evidence directory; release already exists')
    subprocess.run(['/bin/cp','-cR',str(app),str(release)],check=True)
    # Test bundle stays in the build artifact, never in the daily product.
    plugins=release/'Contents/PlugIns'
    if plugins.exists(): shutil.rmtree(plugins)
    signature=subprocess.run(['codesign','-dv','--verbose=2',str(app)],capture_output=True,text=True,check=True).stderr
    authority=next((line.split('=',1)[1] for line in signature.splitlines() if line.startswith('Authority=')),None)
    if not authority: raise RuntimeError('A signed daily App requires its original signing identity')
    entitlements=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True).stdout
    plistlib.loads(entitlements)
    ent=e/'release.entitlements';ent.write_bytes(entitlements)
    subprocess.run(['codesign','--force','--sign',authority,'--entitlements',str(ent),str(release)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(release)],check=True)
    # Re-signing/removing tests cannot change the tested executable or helper payload.
    for name in ['Contents/MacOS/ImageAll.debug.dylib','Contents/Helpers/OpenMontage Helper.app/Contents/Resources/payload-version']:
        if (release/name).read_bytes()!=(app/name).read_bytes(): raise RuntimeError('Staged release differs from tested bytes')
    report={'app':str(release),'dylibSHA256':hashlib.sha256((release/'Contents/MacOS/ImageAll.debug.dylib').read_bytes()).hexdigest(),'gatePassed':True,'appContentIdentity':payload_version(release),'installed':[]}
    receipt=e/'release.json'
    receipt.write_text(json.dumps(report,indent=2)+'\n')
    if a.install_to:
        install=['python3','-B',ROOT/'scripts/openmontage/install_verified.py','--release',receipt]
        for destination in a.install_to: install += ['--destination',destination]
        subprocess.run([str(x) for x in install],check=True)
        report=json.loads(receipt.read_text())
    print(json.dumps(report,indent=2))

if __name__=='__main__': main()
