"""Synthetic SDK round trip; model output is a fixture, not a real creativity claim."""
import copy,json,os,sys,tempfile,threading,unittest,uuid
from pathlib import Path
from http.server import BaseHTTPRequestHandler,HTTPServer
sys.path.insert(0,os.environ.get('IMAGEALL_TEST_ENGINE',str(Path(__file__).resolve().parents[2]/'Vendor/OpenMontage/Runtime/engine')))
from PIL import Image
from lib import story_auto_creative as auto
from lib import story_creative_plugin as legacy

class AutoTests(unittest.TestCase):
    def test_returned_plan_and_fail_closed(self):
        calls=[]
        class Handler(BaseHTTPRequestHandler):
            fail=False
            unsupported_fact=False
            def log_message(self,*args): pass
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));calls.append(body)
                plan=json.loads(body['messages'][0]['content'][0]['text'].split('\nPLAN SHAPE\n')[1])
                plan['shots'][1]['caption']='合成蓝色画面的停留';plan['shots'][1]['durationFrames']=90
                plan['observations']=['两张合成色块'];plan['shots'][0]['rationale']='保留锁定';plan['shots'][1]['rationale']='放慢节奏'
                if self.unsupported_fact: plan['shots'][1]['factRefs']=['asset-1.placeName']
                self.send_response(500 if self.fail else 200);self.send_header('Content-Type','application/json');self.end_headers()
                self.wfile.write(json.dumps(dict(id='synthetic',object='chat.completion',created=1,model='fixture',choices=[dict(index=0,message=dict(role='assistant',content=json.dumps(plan)),finish_reason='stop')])).encode())
        server=HTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
        previous={k:os.environ.get(k) for k in ('OPENMONTAGE_CONFIG_PATH','OPENMONTAGE_MODEL_API_KEY')}
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp).resolve();directory=root/('creative-'+str(uuid.uuid4()));(directory/'package/assets').mkdir(parents=True)
                endpoint=f'http://127.0.0.1:{server.server_port}/v1/chat/completions'
                config=dict(connection=dict(baseURL=endpoint,model='fixture',temperature=.2,maxTokens=4096,timeoutSeconds=5,responseFormat='json_object',tokenParameter='max_tokens',extraBody='{}'))
                (root/'config.json').write_text(json.dumps(config));os.environ['OPENMONTAGE_CONFIG_PATH']=str(root/'config.json');os.environ['OPENMONTAGE_MODEL_API_KEY']='synthetic-key'
                assets=[];facts=[];shots=[];chapter=str(uuid.uuid4())
                for i,color in enumerate(('red','blue')):
                    aid='asset-'+str(i);p=directory/f'package/assets/{aid}.jpg';Image.new('RGB',(32,32),color).save(p);digest=legacy.digest(p.read_bytes())
                    assets.append(dict(assetID=aid,mediaType='image/jpeg',relativePath=f'assets/{aid}.jpg',renderFileSHA256=digest,sourceContentVersion='v1'))
                    facts.append(dict(assetID=aid,contentVersion='v1',sha256=digest,captureTimeMs=None,captureTimeSource=None,placeName=None))
                    shots.append(dict(shotID=str(uuid.uuid4()),assetID=aid,chapterID=chapter,caption='锁定' if i==0 else '',durationFrames=60,locked=i==0,userEdited=False,captionProtected=False,durationProtected=False))
                legacy.write(directory/'package/story.json',dict(schemaVersion='0.1',projectID='synthetic',assets=assets))
                req=dict(protocolVersion='1.2',profile='editable-story-v1',requestID=directory.name,projectID='synthetic',baseFingerprint='a'*64,intent='动态色彩',subject='合成',targetFrames=150,aspect='landscape',externalSendAllowed=True,modelAuthorization=dict(endpoint=endpoint,model='fixture'),storySHA256=legacy.digest((directory/'package/story.json').read_bytes()),facts=facts,shots=shots,chapters=[dict(chapterID=chapter,title='合成')],title='合成故事')
                def publish():
                    legacy.write(directory/'request.json',req);legacy.write(directory/'complete.json',dict(requestSHA256=legacy.digest((directory/'request.json').read_bytes())))
                publish();auto.run(directory)
                self.assertTrue((directory/'ready.json').exists(),legacy.read(directory/'auto-status.json'))
                plan=legacy.read(directory/'plan.json');self.assertEqual(plan['shots'][1]['durationFrames'],90);self.assertEqual(len(calls),1)
                self.assertEqual(sum(x['type']=='image_url' for x in calls[0]['messages'][0]['content']),2)
                prompt=calls[0]['messages'][0]['content'][0]['text']
                scoped=json.loads(prompt.split('\nREQUEST\n')[1].split('\nPLAN SHAPE\n')[0])
                self.assertEqual([s['allowedFactRefs'] for s in scoped['allowedFactRefsByShot']],[[],[]])
                known=copy.deepcopy(req);known['facts'][0]['captureTimeMs']=1234
                self.assertEqual(auto.allowed_fact_refs(known)[0]['allowedFactRefs'],['asset-0.captureTimeMs'])
                digest=legacy.digest((directory/'request.json').read_bytes())
                bad=copy.deepcopy(plan);bad['shots'][0]['caption']='changed'
                with self.assertRaises(ValueError):auto.validate_plan(req,digest,bad)
                bad=copy.deepcopy(plan);bad['shots'].reverse()
                with self.assertRaises(ValueError):auto.validate_plan(req,digest,bad)
                # A selection/edit marker alone does not freeze timing when field flags are present.
                scoped=copy.deepcopy(req)
                scoped['shots'][1].update(userEdited=True,captionProtected=False,durationProtected=False)
                auto.validate_plan(scoped,digest,plan)
                scoped['shots'][1]['captionProtected']=True
                with self.assertRaises(ValueError):auto.validate_plan(scoped,digest,plan)
                scoped['shots'][1].update(captionProtected=False,durationProtected=True)
                with self.assertRaises(ValueError):auto.validate_plan(scoped,digest,plan)
                (directory/'ready.json').unlink()
                req['externalSendAllowed']=False;publish();auto.run(directory);self.assertEqual(len(calls),1)
                req['externalSendAllowed']=True;req['modelAuthorization']['model']='wrong';publish();auto.run(directory);self.assertEqual(len(calls),1)
                req['modelAuthorization']['model']='fixture';publish();Handler.fail=True;auto.run(directory);self.assertEqual(len(calls),2);self.assertFalse((directory/'ready.json').exists())
                Handler.fail=False;Handler.unsupported_fact=True;auto.run(directory)
                self.assertEqual(len(calls),3)
                rejected=legacy.read(directory/'auto-status.json')
                self.assertEqual(rejected['errorCode'],'UNSUPPORTED_FACT')
                self.assertEqual(rejected['validationDetails'],dict(affectedShotCount=1,invalidReferenceCount=1))
                self.assertNotIn('检查设置',rejected['message'])
                self.assertFalse((directory/'ready.json').exists())
                self.assertEqual(legacy.read(directory/'model-audit.json')['calls'],1)
                self.assertFalse(any(b'synthetic-key' in f.read_bytes() for f in directory.rglob('*') if f.is_file()))
        finally:
            server.shutdown();server.server_close()
            for key,value in previous.items():
                if value is None:os.environ.pop(key,None)
                else:os.environ[key]=value
if __name__=='__main__':unittest.main()
