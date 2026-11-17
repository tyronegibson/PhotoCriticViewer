"""Finds photos whose AI evaluation was written while the old stem-keyed preview collision was
still in the database, and (with --requeue) clears just those evaluations so the normal
`evaluate.py --shoot <id>` re-scores them against the correct image.

Affected = an evaluation created before the preview repair AND the file's name is shared with a
different-size file (the signature of the old collision). Nothing else is touched.

Usage:
  python3 requeue_collided_evaluations.py                 # report only, writes a JSON report
  python3 requeue_collided_evaluations.py --requeue       # also clears those evaluations (backs up the DB first)
"""

import argparse
import json
import sqlite3
from collections import defaultdict
from datetime import datetime

from photocritic import config, db

# The preview-collision repair (repair_preview_collisions.py) finished at this instant;
# any evaluation created before it may have scored the wrong (colliding) preview image.
# Hardcoded rather than read from a backup file's mtime, since backups get pruned
# (database backup retention policy: keep only the 3 most recent).
REPAIR_CUTOFF_UTC = "2026-09-23T15:40:39.947615+00:00"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--requeue", action="store_true")
    args = ap.parse_args()

    cutoff = REPAIR_CUTOFF_UTC

    with db.connect() as conn:
        sizes_by_name = defaultdict(set)
        for r in conn.execute("SELECT filename, file_size FROM files"):
            sizes_by_name[r["filename"]].add(r["file_size"])
        collided_names = {n for n, s in sizes_by_name.items() if len(s) > 1}

        rows = conn.execute(
            "SELECT f.id AS file_id, f.shoot_id, f.filename, s.folder_path, ae.created_at "
            "FROM ai_evaluations ae JOIN files f ON f.id = ae.file_id JOIN shoots s ON s.id = f.shoot_id"
        ).fetchall()
        affected = [r for r in rows if r["filename"] in collided_names and r["created_at"] < cutoff]

        by_shoot = defaultdict(list)
        for r in affected:
            by_shoot[(r["shoot_id"], r["folder_path"])].append(r["file_id"])

        report = {
            "repair_cutoff_utc": cutoff,
            "affected_files": len(affected),
            "shoots": [{"shoot_id": sid, "folder_path": path, "file_ids": sorted(set(ids))}
                       for (sid, path), ids in sorted(by_shoot.items())],
        }
        out = config.WORKSPACE_ROOT / "reports"
        out.mkdir(exist_ok=True)
        report_path = out / f"collided-evaluations-{datetime.now():%Y%m%d-%H%M%S}.json"
        report_path.write_text(json.dumps(report, indent=2))
        print(f"{len(affected)} evaluated file(s) across {len(by_shoot)} shoot(s) may describe the wrong image.")
        print(f"Report: {report_path}")

        if not args.requeue:
            print("Report only — re-run with --requeue to clear those evaluations so evaluate.py re-scores them.")
            return

        backup = config.DATABASE_DIR / f"photocritic.db.bak-pre-requeue-{datetime.now():%Y%m%d-%H%M%S}"
        dst = sqlite3.connect(backup)
        conn.backup(dst)
        dst.close()
        print("backup written:", backup)
        ids = sorted({r["file_id"] for r in affected})
        for i in range(0, len(ids), 500):
            chunk = ids[i:i + 500]
            conn.execute(f"DELETE FROM ai_evaluations WHERE file_id IN ({','.join('?' * len(chunk))}) "
                         f"AND created_at < ?", (*chunk, cutoff))
        conn.commit()
        print(f"Cleared {len(ids)} evaluation(s). Now run: python3 evaluate.py --shoot "
              + " ".join(str(sid) for sid, _ in sorted(by_shoot)))


if __name__ == "__main__":
    main()
