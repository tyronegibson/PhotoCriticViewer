"""Regression for travel-sync safety: apply must not stamp marks onto the wrong shoot or delete
the wrong photo when dates or name+size collide.

Run: python3 -m unittest tests.test_travel_sync   (from the project root)

Uses dates in 2031 so it never collides with real library data in a shared test database.
"""

import os
import tempfile
import unittest
from pathlib import Path

WORK = tempfile.mkdtemp(prefix="pc-sync-test-")
os.environ.setdefault("PHOTOCRITIC_WORKSPACE", str(Path(WORK) / "ws"))

from photocritic import db  # noqa: E402
import travel_sync  # noqa: E402


def make_shoot(conn, folder: str, date: str) -> int:
    sid = db.get_or_create_shoot(conn, folder)
    return sid


def add_file(conn, sid: int, folder: str, name: str, size: int, date: str) -> int:
    p = str(Path(folder) / name)
    fid = db.get_or_create_file(conn, sid, name, p, size, 1.0)
    db.save_metadata(conn, fid, {"capture_time": date.replace("-", ":") + " 10:00:00"})
    return fid


def marks(shoots=None, deleted=None):
    return {"version": travel_sync.MARKS_VERSION, "shoots": shoots or [], "deleted": deleted or []}


class TravelSyncSafetyTest(unittest.TestCase):
    def test_two_studio_shoots_on_one_date_are_not_guessed_at(self):
        with db.connect() as conn:
            db.init_schema(conn)
            a = make_shoot(conn, f"{WORK}/2031-01-01-a", "2031-01-01")
            b = make_shoot(conn, f"{WORK}/2031-01-01-b", "2031-01-01")
            add_file(conn, a, f"{WORK}/2031-01-01-a", "SYNC-P1.3FR", 11, "2031-01-01")
            add_file(conn, b, f"{WORK}/2031-01-01-b", "SYNC-P2.3FR", 12, "2031-01-01")
            conn.commit()

            data = marks(shoots=[{
                "date": "2031-01-01", "separate_people": False,
                "looks": [{"name": "Look X", "start_filename": "SYNC-P1.3FR"}],
                "people": [], "composite_groups": [],
            }])
            travel_sync.apply_marks(conn, data, apply=True)
            conn.commit()

            looks = conn.execute("SELECT COUNT(*) FROM looks WHERE name = 'Look X'").fetchone()[0]
            self.assertEqual(looks, 0, "a look was written to one of two same-date shoots")

    def test_delete_only_touches_the_matching_date(self):
        with db.connect() as conn:
            db.init_schema(conn)
            feb = make_shoot(conn, f"{WORK}/2031-02-01", "2031-02-01")
            mar = make_shoot(conn, f"{WORK}/2031-03-01", "2031-03-01")
            feb_file = add_file(conn, feb, f"{WORK}/2031-02-01", "SYNC-Q1.3FR", 700, "2031-02-01")
            mar_file = add_file(conn, mar, f"{WORK}/2031-03-01", "SYNC-Q1.3FR", 700, "2031-03-01")
            conn.commit()

            travel_sync.apply_marks(conn, marks(deleted=[
                {"date": "2031-02-01", "filename": "SYNC-Q1.3FR", "size": 700}]), apply=True)
            conn.commit()

            remaining = {r["id"] for r in conn.execute("SELECT id FROM files WHERE filename = 'SYNC-Q1.3FR'")}
            self.assertNotIn(feb_file, remaining, "the February photo should have been deleted")
            self.assertIn(mar_file, remaining, "the March photo with the same name+size was deleted by mistake")

    def test_ambiguous_delete_within_one_date_is_refused(self):
        with db.connect() as conn:
            db.init_schema(conn)
            apr = make_shoot(conn, f"{WORK}/2031-04-01", "2031-04-01")
            one = add_file(conn, apr, f"{WORK}/2031-04-01/one", "SYNC-Z.3FR", 800, "2031-04-01")
            two = add_file(conn, apr, f"{WORK}/2031-04-01/two", "SYNC-Z.3FR", 800, "2031-04-01")
            conn.commit()

            travel_sync.apply_marks(conn, marks(deleted=[
                {"date": "2031-04-01", "filename": "SYNC-Z.3FR", "size": 800}]), apply=True)
            conn.commit()

            remaining = {r["id"] for r in conn.execute("SELECT id FROM files WHERE filename = 'SYNC-Z.3FR'")}
            self.assertEqual(remaining, {one, two}, "refused delete still removed a file")

    def test_unknown_marks_version_is_rejected(self):
        import subprocess, sys
        bad = Path(WORK) / "bad-version.json"
        bad.write_text('{"version": 99, "shoots": [], "deleted": []}')
        result = subprocess.run([sys.executable, str(Path(__file__).resolve().parent.parent / "travel_sync.py"),
                                 "apply", str(bad), "--apply"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported marks version", result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
