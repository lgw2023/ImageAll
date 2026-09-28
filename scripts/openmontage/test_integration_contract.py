import json
from pathlib import Path
import shutil
import tempfile
import unittest
from integration_contract import CONTRACT, SWIFT, ROOT, swift_source, validate
from mixed_story_executor_patch import apply

class IntegrationContractTests(unittest.TestCase):
    def test_generated_contract_is_current_and_manifest_drift_rejected(self):
        self.assertEqual(SWIFT.read_text(), swift_source())
        with tempfile.TemporaryDirectory() as tmp:
            engine=Path(tmp)
            source=ROOT/'Vendor/OpenMontage/Runtime/engine'
            shutil.copytree(source/'schemas',engine/'schemas')
            shutil.copytree(source/'lib',engine/'lib')
            shutil.copytree(source/'remotion-composer/src',engine/'remotion-composer/src')
            apply(engine)
            shutil.copy(ROOT/'scripts/openmontage/overrides/story_auto_creative.py',engine/'lib/story_auto_creative.py')
            validate(engine)
            path=engine/'schemas/integrations/story_executor_task_protocol_v1.lock.json'
            lock=json.loads(path.read_text());lock['sha256']='0'*64;path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(RuntimeError,'schema/lock mismatch'): validate(engine)

if __name__=='__main__': unittest.main()
