"""Exercise the actual adapter lifecycle on synthetic media in a writable engine."""
import argparse
import copy
import json
from pathlib import Path
import sys
import uuid

from mixed_story_engine_patch import apply
from test_mixed_story_assets import MixedStoryAssetTests

parser = argparse.ArgumentParser()
parser.add_argument('engine', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--render', action='store_true')
args = parser.parse_args()
engine = args.engine.resolve()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
apply(engine)
sys.path.insert(0, str(engine))
from lib.story_render_adapter import (validate_story_package, prepare_story_run, render_story_run,
                                      verify_prepared_story_run_consistency)

MixedStoryAssetTests.setUpClass()
results = []
try:
    for variant in ('mixed', 'muted', 'legacy-photo'):
        document = copy.deepcopy(MixedStoryAssetTests.document)
        document['export'].update(width=320, height=240)
        if variant == 'muted':
            document['chapters'][0]['shots'][1]['videoClip']['originalAudioGain'] = 0
        if variant == 'legacy-photo':
            document['schemaVersion'] = '0.1'
            document['assets'] = document['assets'][:1]
            document['chapters'][0]['shots'] = document['chapters'][0]['shots'][:1]
            document['export']['totalFrames'] = 30
        package = MixedStoryAssetTests.root/'story.json'
        package.write_text(json.dumps(document))
        prepared = prepare_story_run(validate_story_package(package), projects_root=output,
                                     run_suffix=variant+'-'+uuid.uuid4().hex[:8])
        consistency = verify_prepared_story_run_consistency(prepared.project_dir)
        assert consistency['status'] == 'pass', consistency
        edit_path = prepared.project_dir/'artifacts/edit_decisions.json'
        if variant == 'mixed':
            original = edit_path.read_bytes()
            edits = json.loads(original)
            edits['story_render']['shots'][1]['videoClip']['inFrame'] += 1
            edit_path.write_text(json.dumps(edits))
            assert verify_prepared_story_run_consistency(prepared.project_dir)['status'] == 'fail'
            edit_path.write_bytes(original)
            assert verify_prepared_story_run_consistency(prepared.project_dir)['status'] == 'pass'
        result = {'variant': variant, 'projectDir': str(prepared.project_dir), 'consistency': 'pass'}
        if args.render:
            rendered = render_story_run(prepared.project_dir)
            assert rendered['success'], rendered
            report = json.loads((prepared.project_dir/'reports/media_verification.json').read_text())
            assert report['status'] == 'pass' and all(c['passed'] for c in report['checks']), report
            audio = next(c for c in report['checks'] if c['name'] == 'audio_presence')
            assert audio['actual'] == (variant == 'mixed'), audio
            result.update(rendered=rendered, checks=report['checks'])
        results.append(result)
        print(json.dumps(result), flush=True)
finally:
    MixedStoryAssetTests.tearDownClass()
(output/'acceptance.json').write_text(json.dumps(results, indent=2))
