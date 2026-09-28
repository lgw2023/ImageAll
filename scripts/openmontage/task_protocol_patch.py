"""Keep the pinned task envelope consistent with the reviewed story extension."""
import hashlib
import json
from typography_patch import STORY_SCHEMA_SHA256, UPSTREAM_SCHEMA_SHA256

from integration_contract import CONTRACT
UPSTREAM_PROTOCOL_SHA256 = CONTRACT['upstreamTaskProtocolSHA256']
PROTOCOL_SHA256 = CONTRACT['legacyTaskProtocolSHA256']

def apply(engine):
    directory = engine / 'schemas/integrations'
    schema = directory / 'story_executor_task_protocol_v1.schema.json'
    data = schema.read_bytes()
    if hashlib.sha256(data).hexdigest() == CONTRACT['taskProtocolSHA256']:
        lock = json.loads((directory / 'story_executor_task_protocol_v1.lock.json').read_text())
        if lock['sha256'] != CONTRACT['taskProtocolSHA256']:
            raise RuntimeError('Active mixed protocol lock mismatch')
        return
    if hashlib.sha256(data).hexdigest() not in (UPSTREAM_PROTOCOL_SHA256, PROTOCOL_SHA256):
        raise RuntimeError('Unreviewed task protocol schema')
    data = data.replace(UPSTREAM_SCHEMA_SHA256.encode(), STORY_SCHEMA_SHA256.encode())
    if hashlib.sha256(data).hexdigest() != PROTOCOL_SHA256:
        raise RuntimeError('Task protocol extension digest mismatch')
    lock_path = directory / 'story_executor_task_protocol_v1.lock.json'
    lock = json.loads(lock_path.read_text())
    if lock['sha256'] not in (UPSTREAM_PROTOCOL_SHA256, PROTOCOL_SHA256):
        raise RuntimeError('Unreviewed task protocol lock')
    lock.update(sha256=PROTOCOL_SHA256, byteLength=len(data), lineCount=data.count(b'\n'))
    schema.write_bytes(data)
    lock_path.write_text(json.dumps(lock, indent=2) + '\n')
