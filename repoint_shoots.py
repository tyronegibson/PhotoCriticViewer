"""Repoints old named shoots at the date folders their files were sorted into.

organize.py, run on the parent 'Photo dump' folder, moved 'Ms.O' and 'Daniella dress'
into <date>/ folders and created new (unevaluated) twin shoots there, leaving the old
shoots — which hold all the evaluations, looks and groups — pointing at empty folders.

For each (old, twin) pair this keeps the OLD shoot and its work, drops the twin's
duplicate file rows, moves any files that exist only in the twin over to the old shoot,
then repoints the old shoot's files and folder to the date folder. Database rows only:
nothing on disk is touched.

Dry run by default. Usage: python3 repoint_shoots.py [--apply]
"""

import argparse
import sqlite3
from pathlib import Path

from photocritic import config, db

PAIRS = [(129, 143), (134, 144)]  # (old shoot with the work, twin shoot at the date folder)


def plan(conn, old, twin):
    old_rows = conn.execute("SELECT id, filename, file_size FROM files WHERE shoot_id = ?", (old,)).fetchall()
    twin_rows = conn.execute("SELECT id, filename, file_size, full_path FROM files WHERE shoot_id = ?", (twin,)).fetchall()
    twin_by_key = {(r["filename"], r["file_size"]): r for r in twin_rows}
    old_keys = {(r["filename"], r["file_size"]) for r in old_rows}
    matched = [(o, twin_by_key[(o["filename"], o["file_size"])]) for o in old_rows if (o["filename"], o["file_size"]) in twin_by_key]
    old_only = [o for o in old_rows if (o["filename"], o["file_size"]) not in twin_by_key]
    twin_only = [t for t in twin_rows if (t["filename"], t["file_size"]) not in old_keys]
    twin_folder = conn.execute("SELECT folder_path FROM shoots WHERE id = ?", (twin,)).fetchone()["folder_path"]
    return matched, old_only, twin_only, twin_folder


def counts(conn, shoot):
    q = lambda sql: conn.execute(sql, (shoot,)).fetchone()[0]
    return {
        "files": q("SELECT COUNT(*) FROM files WHERE shoot_id = ?"),
        "evaluations": q("SELECT COUNT(*) FROM ai_evaluations ae JOIN files f ON f.id = ae.file_id WHERE f.shoot_id = ?"),
        "looks": q("SELECT COUNT(*) FROM looks WHERE shoot_id = ?"),
        "groups": q("SELECT COUNT(*) FROM similarity_groups WHERE shoot_id = ?"),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="actually repoint (default is a dry run)")
    apply = ap.parse_args().apply

    with db.connect() as conn:
        # One pass per pair up front — plan()/counts() are read-only and nothing
        # here writes, so computing them again later would just repeat the same queries.
        plans = {}
        before = {}
        for old, twin in PAIRS:
            matched, old_only, twin_only, twin_folder = plan(conn, old, twin)
            plans[old] = (twin, matched, old_only, twin_only, twin_folder)
            before[old] = counts(conn, old)
            print(f"\nshoot {old} <- twin {twin} ({twin_folder})")
            print(f"  {len(matched)} matched | old-only (will be dropped, files missing): {[o['filename'] for o in old_only]}"
                  f" | twin-only (will move to shoot {old}): {[t['filename'] for t in twin_only]}")
            for o in old_only:
                assert conn.execute("SELECT COUNT(*) FROM ai_evaluations WHERE file_id = ?", (o["id"],)).fetchone()[0] == 0, "old-only file has evaluations"
            for _, t in matched:
                assert Path(t["full_path"]).exists(), f"missing on disk: {t['full_path']}"
            print("  before:", before[old])
        if not apply:
            print("\nDry run — re-run with --apply. A database backup is taken first.")
            return

        backup = config.DATABASE_DIR / "photocritic.db.bak-pre-repoint"
        dst = sqlite3.connect(backup)
        conn.backup(dst)
        dst.close()
        print("\nbackup written:", backup)

        for old, (twin, matched, old_only, twin_only, twin_folder) in plans.items():
            new_paths = {o["id"]: t["full_path"] for o, t in matched}
            for _, t in matched:                      # free the unique full_path values
                db.delete_file(conn, t["id"])
            for o in old_only:                        # stale rows for files that no longer exist
                db.delete_file(conn, o["id"])
            for t in twin_only:                       # files only the twin has: keep them, under the old shoot
                conn.execute("DELETE FROM similarity_group_members WHERE file_id = ?", (t["id"],))
                conn.execute("UPDATE files SET shoot_id = ? WHERE id = ?", (old, t["id"]))
            db.delete_shoot(conn, twin)               # now only its groups/looks/row remain
            for fid, path in new_paths.items():
                conn.execute("UPDATE files SET full_path = ? WHERE id = ?", (path, fid))
            conn.execute("UPDATE shoots SET folder_path = ? WHERE id = ?", (twin_folder, old))
        conn.commit()

        print("\nafter:")
        for old, twin in PAIRS:
            after = counts(conn, old)
            missing = [r[0] for r in conn.execute("SELECT full_path FROM files WHERE shoot_id = ?", (old,)) if not Path(r[0]).exists()]
            print(f"  shoot {old}: {after} (was {before[old]}) | files missing on disk: {len(missing)}")
        print("  integrity:", conn.execute("PRAGMA integrity_check").fetchone()[0])


if __name__ == "__main__":
    main()
