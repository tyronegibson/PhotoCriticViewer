"""Regression: organizing a parent folder that already contains an indexed shoot
subfolder must reuse that shoot (repointed to the date folder), not mint a twin.

Run: python3 -m unittest tests.test_organize_twin   (from the project root)
"""

import os
import tempfile
import time
import unittest
from pathlib import Path

WORK = tempfile.mkdtemp(prefix="pc-twin-test-")
os.environ["PHOTOCRITIC_WORKSPACE"] = str(Path(WORK) / "ws")

from photocritic import db, pipeline  # noqa: E402

DAY1 = time.mktime((2026, 6, 19, 12, 0, 0, 0, 0, -1))
DAY2 = time.mktime((2026, 6, 20, 12, 0, 0, 0, 0, -1))


def make_raw(path: Path, mtime: float, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)
    os.utime(path, (mtime, mtime))


class OrganizeTwinTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="pc-parent-", dir=WORK))
        self.parent = self.root / "Photo dump"
        make_raw(self.parent / "Ms.O" / "A1.3FR", DAY1, 101)
        make_raw(self.parent / "Ms.O" / "A2.3FR", DAY1, 102)
        make_raw(self.parent / "X.3FR", DAY2, 103)  # second date forces the date-folder move

        # Step 1: index the named subfolder on its own, as the user did originally.
        pipeline.run_organize(self.parent / "Ms.O")
        with db.connect() as conn:
            db.init_schema(conn)
            self.old_shoot = conn.execute("SELECT id FROM shoots WHERE folder_path = ?",
                                          (str(self.parent / "Ms.O"),)).fetchone()["id"]
            a1 = conn.execute("SELECT id FROM files WHERE full_path = ?",
                              (str(self.parent / "Ms.O" / "A1.3FR"),)).fetchone()["id"]
            db.save_evaluation(conn, a1, "test-model", "test-prompt",
                               {"overall_score": 7.5, "classification": "keep",
                                "recommendation": "KEEP", "evaluation_json": {}})
            conn.commit()

    def test_repoints_existing_shoot_instead_of_creating_twin(self):
        pipeline.run_organize(self.parent)

        with db.connect() as conn:
            shoots = {r["folder_path"]: r["id"] for r in conn.execute(
                "SELECT id, folder_path FROM shoots WHERE folder_path LIKE ?", (str(self.root) + "%",))}
            # One shoot per date, and the named shoot is the one that survived.
            self.assertEqual(shoots[str(self.parent / "2026-06-19")], self.old_shoot)
            self.assertNotIn(str(self.parent / "Ms.O"), shoots)
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM shoots WHERE folder_path LIKE ?",
                             (str(self.parent / "2026-06-19") + "%",)).fetchone()[0], 1)

            # Files now point at the date folder, under the original shoot.
            paths = {r["filename"]: (r["shoot_id"], r["full_path"]) for r in
                     conn.execute("SELECT filename, shoot_id, full_path FROM files WHERE full_path LIKE ?",
                                  (str(self.root) + "%",))}
            for name in ("A1.3FR", "A2.3FR"):
                shoot_id, full_path = paths[name]
                self.assertEqual(shoot_id, self.old_shoot)
                self.assertEqual(full_path, str(self.parent / "2026-06-19" / name))
                self.assertTrue(Path(full_path).exists())

            # Evaluations on the surviving shoot are untouched.
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM ai_evaluations ae JOIN files f ON f.id = ae.file_id "
                             "WHERE f.shoot_id = ? AND f.full_path LIKE ?",
                             (self.old_shoot, str(self.root) + "%")).fetchone()[0], 1)

            # No duplicate file rows for the same photo.
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM files WHERE full_path LIKE ? AND filename IN ('A1.3FR','A2.3FR')",
                                          (str(self.root) + "%",)).fetchone()[0], 2)

    def test_refuses_when_group_spans_two_existing_shoots(self):
        # A second, separately indexed shoot holds a photo from the same date as the named
        # shoot. The date group then spans two existing shoots, so the reconciler must refuse
        # rather than guess which one should survive.
        other = self.parent / "Other"
        make_raw(other / "B9.3FR", DAY1, 109)
        pipeline.run_organize(other)
        with db.connect() as conn:
            other_shoot = conn.execute("SELECT id FROM shoots WHERE folder_path = ?", (str(other),)).fetchone()["id"]
        self.assertNotEqual(other_shoot, self.old_shoot)

        with self.assertRaises(RuntimeError):
            pipeline.run_organize(self.parent)

        # Refusal happens before anything is moved on disk.
        self.assertTrue((self.parent / "Ms.O" / "A1.3FR").exists())
        self.assertFalse((self.parent / "2026-06-19").exists())


if __name__ == "__main__":
    unittest.main()
