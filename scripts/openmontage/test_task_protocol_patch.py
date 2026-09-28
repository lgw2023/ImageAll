import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile
import unittest
from jsonschema import Draft202012Validator
import task_protocol_patch
from integration_contract import CONTRACT
from typography_patch import STORY_SCHEMA_SHA256, UPSTREAM_SCHEMA_SHA256

ROOT = Path(__file__).resolve().parents[2]

class TaskProtocolPatchTests(unittest.TestCase):
    def test_envelopes_accept_reviewed_story_and_reject_other_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            engine = Path(temporary)
            directory = engine / 'schemas/integrations'
            shutil.copytree(ROOT/'Vendor/OpenMontage/Runtime/engine/schemas/integrations', directory)
            schema_path = directory/'story_executor_task_protocol_v1.schema.json'
            # Reconstruct pinned upstream, then exercise the build patch twice.
            schema_path.write_bytes(schema_path.read_bytes().replace(STORY_SCHEMA_SHA256.encode(), UPSTREAM_SCHEMA_SHA256.encode()))
            task_protocol_patch.apply(engine)
            first = schema_path.read_bytes()
            task_protocol_patch.apply(engine)
            self.assertEqual(first, schema_path.read_bytes())
            schema = json.loads(first)
            for name in ('task', 'completion'):
                story = schema['$defs'][name]['properties']['storyPackage']
                validator = Draft202012Validator(dict(story, **{"$defs": schema["$defs"]}))
                value = {'entrypoint':'package/story.json', 'schemaVersion':'0.1', 'schemaSHA256':STORY_SCHEMA_SHA256}
                self.assertFalse(list(validator.iter_errors(value)))
                value['schemaSHA256'] = UPSTREAM_SCHEMA_SHA256
                self.assertTrue(list(validator.iter_errors(value)))
            lock = json.loads((directory/'story_executor_task_protocol_v1.lock.json').read_text())
            self.assertEqual(lock['sha256'], hashlib.sha256(first).hexdigest())
            swift = (ROOT/'ImageAll/Application/Story/OpenMontageContract.swift').read_text()
            self.assertEqual(CONTRACT['legacyTaskProtocolSHA256'], lock['sha256'])
            schema_path.write_bytes(first+b' ')
            with self.assertRaisesRegex(RuntimeError, 'Unreviewed'):
                task_protocol_patch.apply(engine)

if __name__ == '__main__': unittest.main()
