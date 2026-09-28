import copy
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import mixed_story_assets as assets
from test_mixed_story_contract import fixture


class MixedStoryAssetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='ImageAllMixedAssets-')
        cls.root = Path(cls.temp.name)
        (cls.root / 'assets').mkdir()
        Image.new('RGB', (32, 32), 'blue').save(cls.root / 'assets/photo.jpg')
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x64:rate=30:duration=2',
                        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
                        '-c:a', 'aac', '-shortest', str(cls.root / 'assets/video.mp4')], check=True)
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=220:duration=1',
                        str(cls.root / 'assets/music.wav')], check=True)
        cls.document = fixture()
        for asset in cls.document['assets']:
            asset['renderFileSHA256'] = hashlib.sha256((cls.root / asset['relativePath']).read_bytes()).hexdigest()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_actual_mixed_media_and_music(self):
        document = copy.deepcopy(self.document)
        music = self.root / 'assets/music.wav'
        document['assets'].append({'assetID': 'music', 'relativePath': 'assets/music.wav', 'mediaType': 'audio/wav',
                                  'sourceContentVersion': 'synthetic', 'renderFileSHA256': hashlib.sha256(music.read_bytes()).hexdigest()})
        facts = assets.validate_assets(document, self.root)
        self.assertEqual(facts['video']['durationMs'], 2000)
        self.assertTrue(facts['video']['hasAudio'])
        self.assertTrue(facts['music']['hasAudio'])
        self.assertGreater(facts['photo']['byteCount'], 0)

    def test_silent_video_is_valid_without_inventing_audio(self):
        silent = self.root / 'assets/silent.mp4'
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(self.root / 'assets/video.mp4'),
                        '-c:v', 'copy', '-an', str(silent)], check=True)
        document = copy.deepcopy(self.document)
        document['assets'][1].update(relativePath='assets/silent.mp4',
                                    renderFileSHA256=hashlib.sha256(silent.read_bytes()).hexdigest())
        document['assets'][1]['video']['hasAudio'] = False
        self.assertFalse(assets.validate_assets(document, self.root)['video']['hasAudio'])

    def test_false_metadata_hash_and_undecodable_media(self):
        for key, value in [('durationMs', 2500), ('hasAudio', False)]:
            with self.subTest(key=key):
                document = copy.deepcopy(self.document)
                document['assets'][1]['video'][key] = value
                with self.assertRaisesRegex(ValueError, 'metadata'):
                    assets.validate_assets(document, self.root)
        document = copy.deepcopy(self.document)
        document['assets'][1]['renderFileSHA256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'checksum'):
            assets.validate_assets(document, self.root)
        bad = self.root / 'assets/bad.mp4'
        bad.write_bytes(b'not video')
        document['assets'][1].update(relativePath='assets/bad.mp4', renderFileSHA256=hashlib.sha256(bad.read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, 'probe or decode'):
            assets.validate_assets(document, self.root)

    def test_symlink_directory_leaf_and_nonregular_are_rejected(self):
        (self.root / 'linked').symlink_to(self.root / 'assets', target_is_directory=True)
        (self.root / 'assets/linked.mp4').symlink_to(self.root / 'assets/video.mp4')
        os.mkfifo(self.root / 'assets/pipe.mp4')
        for relative in ['linked/video.mp4', 'assets/linked.mp4', 'assets/pipe.mp4']:
            with self.subTest(relative=relative):
                document = copy.deepcopy(self.document)
                document['assets'][1]['relativePath'] = relative
                with self.assertRaises((ValueError, OSError)):
                    assets.validate_assets(document, self.root)

    def test_file_replacement_during_probe_is_rejected(self):
        original = assets.probe_media
        video = self.root / 'assets/video.mp4'
        saved = video.read_bytes()
        def replace(*args, **kwargs):
            facts = original(*args, **kwargs)
            alternate = video.with_suffix('.replacement')
            alternate.write_bytes(saved)
            alternate.replace(video)
            return facts
        with patch.object(assets, 'probe_media', side_effect=replace):
            with self.assertRaisesRegex(ValueError, 'changed during verification'):
                assets.validate_assets(self.document, self.root)


if __name__ == '__main__':
    unittest.main()
