"""Export XMP sidecars (rating + color label + notes) for a processed shoot.

Dry-run by default — reports what would happen without touching anything.
Pass --apply to actually write. Sidecars are only ever created, never
modified: a RAW file that already has a .xmp is skipped and reported,
since that sidecar may hold real edits from another tool.

Usage:
    python3 export_xmp.py "<shoot_folder>"            # dry run
    python3 export_xmp.py "<shoot_folder>" --apply     # actually write
"""

import sys
from pathlib import Path

from photocritic import db, xmp_export

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    apply = "--apply" in sys.argv

    if len(args) != 1:
        print("Usage: python3 export_xmp.py <shoot_folder> [--apply]", file=sys.stderr)
        sys.exit(1)

    folder = str(Path(args[0]))

    with db.connect() as conn:
        shoot_id = db.get_shoot_by_folder(conn, folder)
        if shoot_id is None:
            print(f"No processed shoot found for folder: {folder}", file=sys.stderr)
            sys.exit(1)

        plans = xmp_export.plan_export(conn, shoot_id)
        to_create = [p for p in plans if p.action == "create"]
        skip_existing = [p for p in plans if p.action == "skip_existing_xmp"]
        skip_no_eval = [p for p in plans if p.action == "skip_no_evaluation"]

        print(f"Shoot: {folder}")
        print(f"  Would create: {len(to_create)} new .xmp sidecars")
        print(f"  Skip (already has .xmp — untouched): {len(skip_existing)}")
        print(f"  Skip (no evaluation yet): {len(skip_no_eval)}")

        if skip_existing:
            print("\n  Files with an existing .xmp (not touched):")
            for p in skip_existing[:10]:
                print(f"    {p.filename}")
            if len(skip_existing) > 10:
                print(f"    ... and {len(skip_existing) - 10} more")

        if not apply:
            print("\nDry run only — pass --apply to actually write sidecars.")
        else:
            written = xmp_export.apply_export(conn, plans)
            print(f"\nWrote {written} .xmp sidecar(s) next to their RAW files.")
