"""Unit tests for export_photo.py's export_one(): the RAW-decode + EXIF-handling step only
(the crop/resize/color-space/watermark logic moved to Swift -- LocalAPIExportProcessor.swift,
tested there -- since subject-aware cropping needs Apple's Vision framework, which has no
equivalent on this side). Uses a fake (non-RAW) source file, so decode always fails here by
design; that's exactly the path this covers -- a bad file must report a per-file error, not
raise, so a batch of many files isn't taken down by one bad one. The success path (a real RAW
decoding cleanly) is covered by tests/test_local_api.py's end-to-end /export call instead.

Run: python3 -m unittest tests.test_export_photo   (from the project root, using .venv)
"""

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT))

os.environ.setdefault("PHOTOCRITIC_WORKSPACE", str(Path(tempfile.mkdtemp(prefix="pc-export-photo-test-")) / "ws"))

from photocritic import db  # noqa: E402
from export_photo import export_one  # noqa: E402


class ExportOneTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pc-export-photo-shoot-"))
        self.out_dir = Path(tempfile.mkdtemp(prefix="pc-export-photo-out-"))

    def make_file(self, conn, name: str, write_bytes: bytes | None = b"x" * 100) -> int:
        shoot_id = db.get_or_create_shoot(conn, str(self.tmp))
        full_path = self.tmp / name
        if write_bytes is not None:
            full_path.write_bytes(write_bytes)
        return db.get_or_create_file(conn, shoot_id, name, str(full_path), len(write_bytes or b""), time.time())

    def test_unknown_file_id_is_an_error_not_an_exception(self):
        with db.connect() as conn:
            db.init_schema(conn)
            result = export_one(conn, 999999999, self.out_dir, keep_gps=False)
        self.assertIn("error", result)
        self.assertIn("no file with id", result["error"])

    def test_missing_source_raw_is_an_error(self):
        with db.connect() as conn:
            db.init_schema(conn)
            file_id = self.make_file(conn, "gone.3fr", write_bytes=None)
            result = export_one(conn, file_id, self.out_dir, keep_gps=False)
        self.assertIn("error", result)
        self.assertIn("not found", result["error"])

    def test_undecodable_source_reports_decode_failed_not_a_crash(self):
        with db.connect() as conn:
            db.init_schema(conn)
            file_id = self.make_file(conn, "fake.3fr")
            result = export_one(conn, file_id, self.out_dir, keep_gps=False)
        self.assertIn("error", result)
        self.assertIn("decode failed", result["error"])
        self.assertEqual(list(self.out_dir.iterdir()), [])  # nothing half-written


if __name__ == "__main__":
    unittest.main()
