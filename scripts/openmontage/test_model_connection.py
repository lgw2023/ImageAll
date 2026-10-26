"""Synthetic loopback integration test: settings snapshot -> SDK -> photo tool."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import unittest

sys.path.insert(0, os.environ.get('IMAGEALL_TEST_ENGINE', str(Path(__file__).resolve().parents[2] / 'Vendor/OpenMontage/Runtime/engine')))
from PIL import Image
from lib.model_connection import normalize_url
from lib.private_photo_vision import review, validate_saved
from tools.analysis.private_photo_vision import PrivatePhotoVision

class ConnectionTests(unittest.TestCase):
    def test_configured_photo_review_and_failure_boundaries(self):
        calls = []
        result = {'items': [{'assetID': i, 'date': '2026-01-01', 'visibleEvidence': 'A synthetic square with a plain background.', 'subjectClarity': 'clear', 'narrativeRole': 'establish', 'identityUncertain': True, 'risk': 'none'} for i in ['one','two']], 'recommendedAssetIDs': ['one','two'], 'selectionReason': 'Synthetic fixture ordering only.'}
        class Handler(BaseHTTPRequestHandler):
            fail = False
            def log_message(self, *args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                calls.append((self.path, body, self.headers.get('Authorization') == 'Bearer synthetic-only'))
                self.send_response(500 if self.fail else 200)
                self.send_header('Content-Type','application/json'); self.end_headers()
                self.wfile.write(json.dumps({'id':'synthetic','object':'chat.completion','created':1,'model':'configured-model-versioned','choices':[{'index':0,'message':{'role':'assistant','content':json.dumps(result)},'finish_reason':'stop'}], 'usage':{'prompt_tokens':1,'completion_tokens':1,'total_tokens':2}}).encode())
        server = HTTPServer(('127.0.0.1',0), Handler)
        thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        previous = {k:os.environ.get(k) for k in ['OPENMONTAGE_CONFIG_PATH','OPENMONTAGE_MODEL_API_KEY']}
        try:
            with tempfile.TemporaryDirectory() as d:
                root=Path(d).resolve(); project=root/'project'; (project/'public').mkdir(parents=True); (project/'artifacts').mkdir()
                (project/'project.json').write_text('{}')
                assets=[]
                for ident in ['one','two']:
                    file=project/'public'/f'{ident}.jpg'; Image.new('RGB',(8,8),'blue').save(file)
                    assets.append({'assetID':ident,'captureDate':'2026-01-01','sourceContentVersion':'synthetic-v1','relativePath':f'public/{ident}.jpg','sha256':hashlib.sha256(file.read_bytes()).hexdigest()})
                scope='a'*64
                (project/'artifacts/source-assets.json').write_text(json.dumps({'version':'1.0','scopeDigestSHA256':scope,'assets':assets}))
                endpoint=f'http://127.0.0.1:{server.server_port}/custom/v1/chat/completions'
                config={'connection':{'baseURL':endpoint,'model':'configured-model','temperature':0.35,'timeoutSeconds':5,'maxTokens':123,'responseFormat':'json_object','tokenParameter':'max_completion_tokens','organization':'','project':'','extraBody':'{"enable_thinking":false}'}}
                file=root/'config.json';file.write_text(json.dumps(config))
                os.environ['OPENMONTAGE_CONFIG_PATH']=str(file);os.environ['OPENMONTAGE_MODEL_API_KEY']='synthetic-only'
                task={'operation':'review','project_dir':str(project),'expected_scope':scope,'phase':'initial','asset_ids':['one','two'],'acknowledged_external_send':True,'key_env':'obsolete_shell_variable'}
                answer=PrivatePhotoVision().execute(task)
                self.assertTrue(answer.success,answer.error)
                self.assertEqual(len(calls),1);self.assertEqual(calls[0][0],'/custom/v1/chat/completions');self.assertTrue(calls[0][2])
                sent=calls[0][1];self.assertEqual(sent['model'],'configured-model');self.assertEqual(sent['temperature'],0.35);self.assertEqual(sent['max_completion_tokens'],123);self.assertFalse(sent['enable_thinking'])
                output=Path(answer.artifacts[0]); recorded=json.loads(output.read_text());self.assertEqual(recorded['endpoint'],endpoint);self.assertEqual(recorded['returnedModel'],'configured-model-versioned')
                config['connection']['model']='another-model';file.write_text(json.dumps(config))
                self.assertEqual(validate_saved(project,str(output.relative_to(project)),scope)['observation']['model'],'configured-model')
                denied=dict(task,acknowledged_external_send=False);self.assertFalse(PrivatePhotoVision().execute(denied).success);self.assertEqual(len(calls),1)
                Handler.fail=True;self.assertFalse(PrivatePhotoVision().execute(task).success);self.assertEqual(len(calls),2)
                self.assertFalse(any(b'synthetic-only' in f.read_bytes() for f in project.rglob('*') if f.is_file()))
                file.write_text('{}');self.assertFalse(PrivatePhotoVision().execute(task).success);self.assertEqual(len(calls),2)
                for invalid in ['http://remote.example/v1','https://user:secret@example.com/v1','https://example.com/v1?api_key=secret']:
                    with self.assertRaises(ValueError): normalize_url(invalid)
        finally:
            server.shutdown();server.server_close()
            for k,v in previous.items():
                if v is None: os.environ.pop(k,None)
                else: os.environ[k]=v

if __name__=='__main__': unittest.main()
