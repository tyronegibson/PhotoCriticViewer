"""One-off repair: previews used to be named by filename stem alone, so different
photos sharing a stem (the camera restarts its counter across rolls) overwrote
each other's JPEG. This re-decodes every photo whose preview is shared by files
of differing size, writes it a unique preview, and refreshes its technical
analysis + phash from the correct image.

Dry-run by default; pass --apply to write. Does not touch similarity groups,
rankings or AI evaluations — it prints which shoots are affected instead.

Usage: python3 repair_preview_collisions.py [--apply]
"""

import argparse
import concurrent.futures
from collections import defaultdict
from pathlib import Path

from tqdm import tqdm

from photocritic import config, db
from photocritic.pipeline import _decode_and_cull
from photocritic.raw_decoder import default_decoder


def find_affected(conn):
    rows = conn.execute(
        "SELECT f.id, f.shoot_id, f.full_path, f.file_size, ta.preview_path "
        "FROM files f JOIN technical_analysis ta ON ta.file_id = f.id"
    ).fetchall()
    by_preview = defaultdict(list)
    for r in rows:
        by_preview[r["preview_path"]].append(r)
    affected = []
    for members in by_preview.values():
        if len({m["file_size"] for m in members}) > 1:
            affected.extend(members)
    return affected


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="actually regenerate (default is a dry run)")
    apply = ap.parse_args().apply

    with db.connect() as conn:
        affected = find_affected(conn)
        present = [r for r in affected if Path(r["full_path"]).exists()]
        missing = [r for r in affected if not Path(r["full_path"]).exists()]
        shoots = sorted({r["shoot_id"] for r in affected})
        print(f"{len(affected)} files share a preview with a different photo "
              f"({len(present)} RAW present, {len(missing)} RAW missing) across {len(shoots)} shoot(s).")
        for r in missing[:10]:
            print(f"  RAW missing, skipped: {r['full_path']}")
        if not apply:
            print("Dry run — re-run with --apply to regenerate.")
            return

        decoder = default_decoder()
        old_previews = {r["preview_path"] for r in present}
        done = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=config.INGEST_WORKERS) as ex:
            futures = {ex.submit(_decode_and_cull, r["id"], Path(r["full_path"]), decoder): r for r in present}
            for i, fut in enumerate(tqdm(concurrent.futures.as_completed(futures), total=len(futures)), start=1):
                r = futures[fut]
                try:
                    ta, ph, preview_path = fut.result()
                except Exception as e:
                    tqdm.write(f"  FAILED {r['full_path']}: {e}")
                    continue
                db.save_technical_analysis(conn, r["id"], ta, ph, preview_path)
                conn.commit()
                done += 1
                print(f"PROGRESS repair: {i}/{len(futures)}", flush=True)

        still_used = {row[0] for row in conn.execute("SELECT preview_path FROM technical_analysis")}
        removed = 0
        for p in old_previews - still_used:
            Path(p).unlink(missing_ok=True)
            removed += 1
        print(f"Regenerated {done}/{len(present)}; removed {removed} orphaned shared preview(s).")

        print("\nShoots whose similarity groups / AI scores may have come from wrong images:")
        for sid in shoots:
            row = conn.execute("SELECT folder_path FROM shoots WHERE id = ?", (sid,)).fetchone()
            n = sum(1 for r in affected if r["shoot_id"] == sid)
            ev = conn.execute(
                "SELECT COUNT(*) FROM ai_evaluations ae JOIN files f ON f.id = ae.file_id WHERE f.shoot_id = ?", (sid,)
            ).fetchone()[0]
            print(f"  [{sid}] {row['folder_path'] if row else '?'} — {n} affected file(s), {ev} evaluated")


if __name__ == "__main__":
    main()
