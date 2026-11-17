"""Regression for import identity: card originals and already-renamed destination copies
must be recognized as the same photo in both directions, a same-name/same-size match must
be confirmed by content (not assumed), a stat failure must never count as a duplicate, and
roll names must not be able to escape the destination folder.

Run: python3 -m unittest tests.test_import_identity   (from the project root)
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT))

from photocritic.dedup import base_name, unique_name  # noqa: E402


def run_import(src: Path, dest: Path, expect_returncode: int = 0) -> str:
    result = subprocess.run(
        [sys.executable, str(PROJECT / "import_folder.py"), str(src), "--dest", str(dest), "--apply"],
        capture_output=True, text=True, cwd=PROJECT,
    )
    assert result.returncode == expect_returncode, result.stdout + result.stderr
    return result.stdout


class ImportIdentityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pc-import-test-"))
        self.src = self.tmp / "card" / "DCIM" / "100MSDCF"
        self.dest = self.tmp / "dest"
        self.src.mkdir(parents=True)
        self.dest.mkdir()

    def copies_in(self, folder: Path) -> set[str]:
        return {p.name for p in folder.iterdir() if p.is_file()}

    def test_card_original_matches_already_renamed_destination(self):
        # Destination already holds the renamed copy from an earlier import.
        (self.dest / "b0004520__100MSDCF.3FR").write_bytes(b"x" * 300)
        (self.src / "B0004520.3FR").write_bytes(b"x" * 300)

        run_import(self.src, self.dest)

        self.assertEqual(self.copies_in(self.dest), {"b0004520__100MSDCF.3FR"})

    def test_source_already_named_with_roll_suffix_is_not_copied_again(self):
        # Re-importing a tree whose files already carry the roll suffix must not duplicate them.
        (self.dest / "b0004520.3FR").write_bytes(b"x" * 300)
        (self.src / "b0004520__100MSDCF.3FR").write_bytes(b"x" * 300)

        run_import(self.src, self.dest)

        self.assertEqual(self.copies_in(self.dest), {"b0004520.3FR"})

    def test_same_base_different_size_is_kept_not_dropped(self):
        (self.dest / "b0004520__100MSDCF.3FR").write_bytes(b"x" * 300)
        (self.src / "B0004520.3FR").write_bytes(b"x" * 999)

        run_import(self.src, self.dest)

        names = {n.lower() for n in self.copies_in(self.dest)}
        self.assertEqual(names, {"b0004520__100msdcf.3fr", "b0004520__100msdcf_2.3fr"})

    def test_unstatable_source_is_skipped_not_treated_as_duplicate(self):
        # A dangling symlink lists as a .3FR but can't be stat'd: it must not be reported
        # as "already in the destination", and must not be copied. A stat failure is now a
        # real failure (non-zero exit), not a quietly-ignored one.
        (self.dest / "B0005000.3FR").write_bytes(b"x" * 300)
        os.symlink(self.tmp / "does-not-exist.3FR", self.src / "B0005000.3FR")

        out = run_import(self.src, self.dest, expect_returncode=1)

        self.assertIn("SKIPPED (could not stat", out)
        self.assertEqual(self.copies_in(self.dest), {"B0005000.3FR"})

    def test_same_name_and_size_but_different_content_is_not_silently_dropped(self):
        # Two different rolls can produce a frame with the identical filename AND the
        # identical byte size (a plausible coincidence for similar RAW content) -- that
        # combination must not be trusted as "the same photo" without checking content.
        (self.dest / "b0004520__100MSDCF.3FR").write_bytes(b"a" * 300)
        (self.src / "B0004520.3FR").write_bytes(b"b" * 300)  # same size, different bytes

        out = run_import(self.src, self.dest)

        names = {n.lower() for n in self.copies_in(self.dest)}
        self.assertEqual(names, {"b0004520__100msdcf.3fr", "b0004520__100msdcf_2.3fr"})
        self.assertIn("also matched an existing file's size exactly", out)

    def test_zero_byte_source_is_skipped_not_treated_as_duplicate(self):
        (self.dest / "B0006000.3FR").write_bytes(b"x" * 300)
        (self.src / "B0006000.3FR").write_bytes(b"")

        out = run_import(self.src, self.dest, expect_returncode=1)

        self.assertIn("SKIPPED (0 bytes", out)
        self.assertEqual(self.copies_in(self.dest), {"B0006000.3FR"})

    def test_roll_name_cannot_escape_destination(self):
        self.assertEqual(unique_name("B1.3FR", "..", set()), "B1__unknown.3FR")
        self.assertEqual(unique_name("B1.3FR", ".", set()), "B1__unknown.3FR")
        self.assertNotIn("/", unique_name("B1.3FR", "a/b", set()))
        self.assertEqual(unique_name("B1.3FR", "a/b", set()), "B1__a_b.3FR")

    def test_photos_in_marker_or_dupe_folders_are_restored_on_replug(self):
        for folder in ("_Marked_for_Deletion", "Dupe"):
            (self.dest / folder).mkdir(exist_ok=True)
            (self.dest / folder / "C1.3FR").write_bytes(b"x" * 300)
        (self.src / "C1.3FR").write_bytes(b"x" * 300)

        run_import(self.src, self.dest)

        self.assertIn("C1.3FR", self.copies_in(self.dest))

    def test_base_name_is_symmetric(self):
        self.assertEqual(base_name("B0004520.3FR"), base_name("b0004520__100MSDCF.3FR"))


if __name__ == "__main__":
    unittest.main()
