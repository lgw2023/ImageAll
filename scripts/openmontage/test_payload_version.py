import tempfile
import unittest
from pathlib import Path
from payload_version import payload_version

class PayloadVersionTests(unittest.TestCase):
    def test_code_change_invalidates_cache_even_with_unchanged_prepare_stamp(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root/'runtime-version').write_text('same-stamp')
            (root/'director.py').write_text("VERSION = '1.2.0'")
            old = payload_version(root)
            self.assertEqual(old, payload_version(root))
            (root/'director.py').write_text("VERSION = '1.2.1'")
            new = payload_version(root)
            self.assertNotEqual(old, new)
            (root/'__pycache__').mkdir()
            (root/'__pycache__/director.pyc').write_bytes(b'cache')
            self.assertEqual(new, payload_version(root))

if __name__ == '__main__': unittest.main()
