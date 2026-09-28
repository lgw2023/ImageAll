"""Submit a synthetic mixed story to the real detached worker and verify publication."""
import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import sys
import time
import uuid

from mixed_story_executor_patch import apply
from test_mixed_story_assets import MixedStoryAssetTests

parser = argparse.ArgumentParser()
parser.add_argument('engine', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--legacy', action='store_true', help='Render a 0.1 photo package for offline Mac recovery')
args = parser.parse_args()
engine = args.engine.resolve()
identity = apply(engine)
root = args.output.resolve()/('executor-'+uuid.uuid4().hex[:8])
root.mkdir(parents=True)
sys.path.insert(0, str(engine))
from lib.story_task_executor import StoryTaskExecutor, verify_submission, ProtocolError, _validate_protocol_document


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def submit(document, task_id, *, wrong_hash=False):
    submission = root/'tasks'/task_id/'submission'
    submission.mkdir(parents=True)
    shutil.copytree(MixedStoryAssetTests.root/'assets', submission/'package/assets')
    # Register only the assets belonging to this document.
    used = {a['relativePath'] for a in document['assets']}
    for path in (submission/'package/assets').iterdir():
        if str(path.relative_to(submission/'package')) not in used:
            path.unlink()
    (submission/'package/story.json').write_text(json.dumps(document))
    now = datetime.now(timezone.utc).isoformat()
    producer = {'application': 'ImageAllSyntheticAcceptance', 'applicationVersion': '1', 'installationID': 'synthetic'}
    story = {'entrypoint': 'package/story.json', 'schemaVersion': document['schemaVersion'],
             'schemaSHA256': identity['storyPackageSchemas'][('0.2' if document['schemaVersion'] == '0.1' else '0.1') if wrong_hash else document['schemaVersion']]}
    task = {'documentType': 'story-task', 'protocolVersion': '1.1', 'taskType': 'story-render',
            'taskID': task_id, 'projectID': document['projectID'], 'projectRevision': document['projectRevision'],
            'submittedBy': producer, 'submittedAt': now, 'storyPackage': story}
    (submission/'task.json').write_text(json.dumps(task))
    entries = [{'path': str(p.relative_to(submission)), 'sha256': sha(p), 'sizeBytes': p.stat().st_size}
               for p in sorted(submission.rglob('*')) if p.is_file()]
    manifest = ''.join(f"{e['sha256']}  {e['sizeBytes']}  {e['path']}\n" for e in sorted(entries,key=lambda e:e['path']))
    completion = {'documentType': 'story-task-completion', 'protocolVersion': '1.1', 'producer': producer,
                  'deliveryID': task_id, 'taskID': task_id, 'projectID': document['projectID'],
                  'projectRevision': document['projectRevision'], 'status': 'complete', 'storyPackage': story,
                  'completedAt': now, 'hashAlgorithm': 'sha256', 'files': entries,
                  'manifestSHA256': hashlib.sha256(manifest.encode()).hexdigest()}
    (submission/'complete.json').write_text(json.dumps(completion))
    return submission.parent


MixedStoryAssetTests.setUpClass()
try:
    document = copy.deepcopy(MixedStoryAssetTests.document)
    document['export'].update(width=320,height=240)
    # Legacy package remains acceptable; do not queue another render for this regression.
    legacy = copy.deepcopy(document)
    legacy['schemaVersion'] = '0.1'
    legacy['assets'] = legacy['assets'][:1]
    legacy['chapters'][0]['shots'] = legacy['chapters'][0]['shots'][:1]
    legacy['export']['totalFrames'] = 30
    if args.legacy:
        document = copy.deepcopy(legacy)
        document['export'].update(width=1920, height=1080)
    legacy_dir = submit(legacy, 'legacy-validation')
    assert verify_submission(legacy_dir) is not None
    # The validated legacy fixture is evidence, not a queued task.
    legacy_dir.rename(root/'legacy-validation')
    rejected = submit(document, 'wrong-version-hash', wrong_hash=True)
    try:
        verify_submission(rejected)
        raise AssertionError('Version/hash mismatch was accepted')
    except ProtocolError:
        pass
    rejected.rename(root/'rejected-version-hash')
    task = submit(document, 'mixed-render')
    executor = StoryTaskExecutor(root)
    assert executor.readiness['ready'], executor.readiness
    executor.ensure_layout()
    caps = json.loads((root/'executor/capabilities.json').read_text())
    assert {item['version'] for item in caps['storyPackageSchemas']} == {'0.1', '0.2'}
    started = time.monotonic()
    last_state = None
    while True:
        executor.process_once()
        status = executor.current_status(task)
        if status and status['state'] != last_state:
            print(json.dumps({'taskRoot': str(root), 'state': status['state']}), flush=True)
            last_state = status['state']
        if status and status['state'] in ('succeeded', 'failed', 'cancelled', 'interrupted', 'rejected'):
            break
        if time.monotonic()-started > 240:
            executor.process_once(accept_new=False, cancel_active=True)
            raise RuntimeError('Acceptance deadline exceeded; cancellation requested; inspect worker state')
        time.sleep(0.25)
    assert status['state'] == 'succeeded', status
    result = json.loads((task/'state/result.json').read_text())
    _validate_protocol_document(result, 'story-task-result')
    assert sha(root/result['output']['path']) == result['output']['sha256']
    for report in result['reports'].values():
        assert sha(root/report['path']) == report['sha256']
    assert result['media']['frames'] == document['export']['totalFrames'], result
    assert result['media']['audioCodec'] == (None if args.legacy else 'aac'), result
    assert result['storyPackageSHA256'] == sha(task/'submission/package/story.json')
    evidence = {'taskRoot': str(root), 'identities': identity, 'legacyAccepted': True, 'wrongPairRejected': True,
                'result': result, 'elapsedSeconds': time.monotonic()-started}
    (root/'acceptance.json').write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence), flush=True)
finally:
    MixedStoryAssetTests.tearDownClass()
