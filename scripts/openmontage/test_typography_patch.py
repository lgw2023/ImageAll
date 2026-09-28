import hashlib
import json
from pathlib import Path
import re
import tempfile
import unittest
from integration_contract import CONTRACT

from typography_patch import STORY_SCHEMA_SHA256, UPSTREAM_SCHEMA_SHA256, synchronize_story_schema_lock

ROOT = Path(__file__).resolve().parents[2]


class StorySchemaLockTests(unittest.TestCase):
    def test_reviewed_schema_and_swift_exporter_share_identity_and_lock_is_idempotent(self):
        schema = ROOT / 'Vendor/OpenMontage/Runtime/engine/schemas/integrations/story_render_package_v0_1.schema.json'
        data = schema.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), STORY_SCHEMA_SHA256)
        swift = (ROOT / 'ImageAll/Application/Story/OpenMontageContract.swift').read_text()
        self.assertEqual(CONTRACT['legacyStorySchemaSHA256'], STORY_SCHEMA_SHA256)
        with tempfile.TemporaryDirectory() as temporary:
            engine = Path(temporary)
            directory = engine / 'schemas/integrations'
            directory.mkdir(parents=True)
            target = directory / schema.name
            target.write_bytes(data)
            lock_path = directory / 'story_render_package_v0_1.lock.json'
            lock_path.write_text(json.dumps({'sha256': UPSTREAM_SCHEMA_SHA256, 'schemaVersion': '0.1', 'introducedInCommit': 'upstream'}))
            synchronize_story_schema_lock(engine)
            first = lock_path.read_bytes()
            lock = json.loads(first)
            self.assertEqual(lock['sha256'], hashlib.sha256(target.read_bytes()).hexdigest())
            self.assertEqual(lock['byteLength'], len(data))
            self.assertEqual(lock['upstreamLock']['sha256'], UPSTREAM_SCHEMA_SHA256)
            synchronize_story_schema_lock(engine)
            self.assertEqual(lock_path.read_bytes(), first)
            target.write_bytes(data + b' ')
            with self.assertRaisesRegex(RuntimeError, 'schema changed'):
                synchronize_story_schema_lock(engine)
            self.assertEqual(lock_path.read_bytes(), first)


if __name__ == '__main__':
    unittest.main()
