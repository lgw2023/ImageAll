import copy
import hashlib
from pathlib import Path
import unittest
from unittest.mock import patch

import mixed_story_adapter as adapter
import test_mixed_story_assets as fixtures


class MixedStoryAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixtures.MixedStoryAssetTests.setUpClass()
        cls.fixture = fixtures.MixedStoryAssetTests

    @classmethod
    def tearDownClass(cls):
        fixtures.MixedStoryAssetTests.tearDownClass()

    def test_frozen_props_preserve_multiple_source_ranges_and_survive_source_change(self):
        document = copy.deepcopy(self.fixture.document)
        second = copy.deepcopy(document['chapters'][0]['shots'][1])
        second.update(shotID='v2', sequenceIndex=2, startFrame=60)
        second['videoClip'].update(inFrame=0, outFrame=30, originalAudioGain=0)
        document['chapters'][0]['shots'].append(second)
        document['export']['totalFrames'] = 90
        before = copy.deepcopy(document)
        source = self.fixture.root / 'assets/video.mp4'
        original = source.read_bytes()
        with adapter.prepared_story(document, self.fixture.root) as (root, props, facts):
            shots = props['story_render']['shots']
            self.assertEqual([s['id'] for s in shots], ['p', 'v', 'v2'])
            self.assertEqual([s['videoClip']['inFrame'] for s in shots[1:]], [15, 0])
            self.assertEqual([s['videoClip']['originalAudioGain'] for s in shots[1:]], [0.5, 0])
            self.assertEqual(shots[1]['src'], shots[2]['src'])
            self.assertNotEqual(Path(shots[1]['src']), source)
            self.assertEqual(facts['video']['sha256'], hashlib.sha256(original).hexdigest())
            try:
                source.write_bytes(b'changed after freeze')
                self.assertEqual(Path(shots[1]['src']).read_bytes(), original)
            finally:
                source.write_bytes(original)
        self.assertFalse(root.exists())
        self.assertEqual(document, before)

    def test_failed_copy_and_renderer_failure_clean_private_directory_only(self):
        parent = self.fixture.root / 'work'
        parent.mkdir(exist_ok=True)
        sentinel = parent / 'keep.txt'
        sentinel.write_text('unrelated')
        bad = copy.deepcopy(self.fixture.document)
        bad['assets'][1]['renderFileSHA256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'checksum'):
            with adapter.prepared_story(bad, self.fixture.root, work_parent=parent):
                self.fail('Invalid input reached renderer')
        with self.assertRaisesRegex(RuntimeError, 'render failed'):
            with adapter.prepared_story(self.fixture.document, self.fixture.root, work_parent=parent):
                raise RuntimeError('render failed')
        self.assertEqual(list(parent.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_text(), 'unrelated')

    def test_replacement_during_freeze_is_rejected(self):
        original_copy = adapter.copy_frozen
        source = self.fixture.root / 'assets/video.mp4'
        def replacing_copy(fd, destination, expected):
            before = original_copy(fd, destination, expected)
            if destination.suffix == '.mp4':
                replacement = source.with_suffix('.replacement')
                replacement.write_bytes(source.read_bytes())
                replacement.replace(source)
            return before
        with patch.object(adapter, 'copy_frozen', side_effect=replacing_copy):
            with self.assertRaisesRegex(ValueError, 'path changed'):
                with adapter.prepared_story(self.fixture.document, self.fixture.root):
                    self.fail('Replaced input reached renderer')


if __name__ == '__main__':
    unittest.main()
