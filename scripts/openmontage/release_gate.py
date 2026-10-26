#!/usr/bin/env python3
"""Verify the actual signed App with synthetic inputs, never a production Photos host.

No real model API is called. This creates its own task/runtime directories and leaves evidence.
The optional --previous-app exercises graceful upgrade during a real in-flight render.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
from integration_contract import validate


def read(path): return json.loads(path.read_text())
def wait_for(predicate, seconds=180):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        value=predicate()
        if value: return value
        time.sleep(.5)
    raise RuntimeError('Release gate timed out')

def main():
    p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--previous-app',type=Path);p.add_argument('--evidence',type=Path,required=True)
    a=p.parse_args();app=a.app.resolve();a.evidence.mkdir(parents=True,exist_ok=True)
    gate=a.evidence/('synthetic-'+uuid.uuid4().hex);gate.mkdir()
    root=gate/'tasks';root.mkdir();(root/'synthetic-release-gate.json').write_text('{"synthetic":true}')
    helper=app/'Contents/Helpers/OpenMontage Helper.app'
    resources=helper/'Contents/Resources';payload=resources/'payload'
    validate(payload/'engine')
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    summary={'app':str(app),'payloadVersion':(resources/'payload-version').read_text().strip(),'syntheticRoot':str(root)}
    python=payload/'python/bin/python3.12'
    script=payload/'engine/scripts/story_executor.py'
    env=os.environ.copy()
    # Do not inherit API credentials into the gate or worker. The helper localOnly path skips Keychain.
    for key in list(env):
        if any(word in key.upper() for word in ('API_KEY','TOKEN','SECRET')) or key.startswith('OPENMONTAGE_'): env.pop(key,None)
    env.update(PATH=str(payload/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin',PYTHONDONTWRITEBYTECODE='1',PYTHONNOUSERSITE='1',IMAGEALL_TEST_ENGINE=str(payload/'engine'))
    def command(args,log,**kwargs):
        with (gate/log).open('a') as output:
            return subprocess.run([str(x) for x in args],env=env,stdout=output,stderr=subprocess.STDOUT,check=True,**kwargs)
    def stop():
        command([python,script,'stop','--task-root',root,'--mode','finish-current','--wait','--wait-seconds','60'],'stop.log',timeout=70)
    def launch():
        nonce=str(uuid.uuid4());runtime=gate/'runtime'
        request={'token':nonce,'runtime':str(runtime),'servicesEnabled':'false','localOnly':'true'}
        (root/'launcher-request.json').write_text(json.dumps(request))
        command([helper/'Contents/MacOS/OpenMontageHelper','--launch-request',root,runtime,nonce],'helper.log',timeout=60)
        result=read(root/'launcher-result.json')
        assert result['token']==nonce
        return result
    def run_test(name):
        testenv=dict(env,IMAGEALL_RELEASE_GATE_ROOT=str(root),DYLD_INSERT_LIBRARIES=str(app/'Contents/MacOS/ImageAll.debug.dylib'))
        bundle=app/'Contents/PlugIns/ImageAllTests.xctest'
        with (gate/(name+'.log')).open('w') as log:
            subprocess.run(['/Applications/Xcode.app/Contents/Developer/usr/bin/xctest','-XCTest','ImageAllTests.TimeStoryFeatureTests/'+name,str(bundle)],env=testenv,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=200)
        if 'Executed 1 test' not in (gate/(name+'.log')).read_text(): raise RuntimeError('Gate test did not execute')
    def current_status():
        ref=read(root/'gate-task.json')
        path=root/'tasks'/ref['taskID']/'state/status.json'
        return read(path) if path.exists() else {}
    def finished():
        s=current_status()
        if s.get('terminal'):
            if s['state']!='succeeded': raise RuntimeError('Synthetic render failed: '+str(s.get('error',{}).get('code')))
            return s
    try:
        if a.previous_app:
            previous=a.previous_app.resolve()/'Contents/Helpers/OpenMontage Helper.app/Contents/Resources/payload'
            oldenv=dict(env,PATH=str(previous/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin')
            with (gate/'old-start.log').open('w') as log:
                subprocess.run([str(previous/'python/bin/python3.12'),str(previous/'engine/scripts/story_executor.py'),'start','--task-root',str(root),'--detach'],env=oldenv,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=30)
            wait_for(lambda:(root/'executor/heartbeat.json').exists())
            oldpid=read(root/'executor/heartbeat.json')['pid']
            run_test('testBundledReleasePublishSyntheticTask')
            wait_for(lambda:current_status().get('state')=='running')
            result=launch()
            # A long active render may exceed helper's bounded drain wait. Never cancel it.
            finished_state=wait_for(finished)
            if not result['success']:
                wait_for(lambda: read(root/'executor/heartbeat.json')['availability']=='stopped')
                result=launch()
            assert result['success'],result.get('message')
            newpid=wait_for(lambda: read(root/'executor/heartbeat.json')['pid'] if read(root/'executor/heartbeat.json')['pid']!=oldpid else None)
            summary['upgrade']={'oldPID':oldpid,'newPID':newpid,'activeRenderPreserved':finished_state['state']=='succeeded'}
        else:
            assert launch()['success']
            # The launcher acknowledges spawning before the detached worker publishes
            # its first heartbeat. A cold start must wait for that async handoff.
            wait_for(lambda: (root/'executor/heartbeat.json').exists())
        expected=gate/'runtime'/summary['payloadVersion']
        pid=read(root/'executor/heartbeat.json')['pid']
        executable=subprocess.check_output(['/bin/ps','-p',str(pid),'-o','comm='],text=True).strip()
        assert executable.startswith(str(expected)+'/'), 'Running worker is not the packaged release'
        summary['installedRuntimeVerified']=True
        run_test('testBundledReleasePublishSyntheticTask')
        wait_for(finished)
        run_test('testBundledReleaseTemplateRoundTrip')
        active_pid=read(root/'executor/heartbeat.json')['pid']
        assert launch()['success']
        assert read(root/'executor/heartbeat.json')['pid']==active_pid, 'Repeated startup must reuse the verified current worker'
        summary['idempotentStart']=True
        command([python,'-m','unittest','discover','-s',Path(__file__).parent,'-p','test_auto_creative.py'],'creative-loopback.log',timeout=60)
        stop()
        run_test('testBundledReleaseVerifiesResultWhileExecutorOffline')
        summary.update(passed=True,render=True,template=True,creativeLoopback=True,offlineResult=True)
        (gate/'acceptance.json').write_text(json.dumps(summary,indent=2)+'\n')
        print(json.dumps(summary,indent=2),flush=True)
    finally:
        stop()

if __name__=='__main__': main()
