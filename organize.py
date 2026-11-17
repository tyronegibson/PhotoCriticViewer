"""CLI: Phase 1 of processing a folder — fast, CPU-only, safe to run over an
entire unsorted archive. Sorts a multi-date folder into per-date subfolders,
decodes + technical-culls + extracts EXIF for every file, and clusters
near-duplicate bursts. Does NOT run the GPU-heavy AI evaluation — use
evaluate.py afterward on whichever shoot_ids are actually worth it.

Usage: python3 organize.py "/path/to/folder"
"""

import sys
from pathlib import Path

from photocritic import db
from photocritic.pipeline import run_organize

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 organize.py <folder>", file=sys.stderr)
        sys.exit(1)

    folder = Path(sys.argv[1])
    if not folder.is_dir():
        print(f"Not a directory: {folder}", file=sys.stderr)
        sys.exit(1)

    shoot_ids = run_organize(folder)

    if shoot_ids:
        print(f"\nOrganized into {len(shoot_ids)} shoot(s):")
        with db.connect() as conn:
            for sid in shoot_ids:
                row = conn.execute("SELECT folder_path FROM shoots WHERE id = ?", (sid,)).fetchone()
                if row is None:
                    # Deleted (e.g. via the app) between finishing and this
                    # summary printing — nothing to report, not an error.
                    continue
                count = conn.execute("SELECT COUNT(*) FROM files WHERE shoot_id = ?", (sid,)).fetchone()[0]
                evaluated = conn.execute(
                    "SELECT COUNT(*) FROM ai_evaluations ae JOIN files f ON f.id = ae.file_id WHERE f.shoot_id = ?",
                    (sid,),
                ).fetchone()[0]
                status = "evaluated" if evaluated == count and count > 0 else f"{evaluated}/{count} evaluated"
                print(f"  [{sid}] {row['folder_path']} — {count} file(s), {status}")
        print("\nRun `python3 evaluate.py --shoot <id> [<id> ...]` on whichever ones you want scored.")
    print("Done.")
