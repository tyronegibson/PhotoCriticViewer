"""Regression: a missing exiftool fails the batch; one unreadable file in a batch does not
drop the others.

Run: python3 -m unittest tests.test_metadata   (from the project root)
"""

import os
import tempfile
import unittest
from pathlib import Path

from photocritic import metadata


class ExifBatchTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="pc-exif-test-"))

    def test_missing_exiftool_fails_the_batch(self):
        f = self.dir / "a.3FR"
        f.write_bytes(b"x" * 10)
        old = os.environ.get("PATH")
        os.environ["PATH"] = ""
        try:
            with self.assertRaises(RuntimeError):
                metadata.read_exif_batch([f])
        finally:
            os.environ["PATH"] = old

    def test_one_unreadable_file_does_not_drop_the_rest(self):
        good = [self.dir / "b.3FR", self.dir / "c.3FR"]
        for p in good:
            p.write_bytes(b"x" * 10)
        missing = self.dir / "gone.3FR"  # exiftool exits 1 on this, but still reports the others
        result = metadata.read_exif_batch([good[0], missing, good[1]])
        self.assertIn(good[0], result)
        self.assertIn(good[1], result)
        self.assertNotIn(missing, result)


if __name__ == "__main__":
    unittest.main()
