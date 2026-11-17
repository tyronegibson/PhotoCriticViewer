"""CLI: decode photos to full-resolution JPEG intermediates for PhotoCriticViewer's local API
(POST /export) to finish. This script does ONLY what only Python/rawpy can do -- decode the RAW
and copy/strip EXIF; it does NOT crop, resize to a final size, pick a color space, or watermark.
That work moved to Swift (LocalAPIExportProcessor.swift) specifically because subject-aware
cropping needs Apple's Vision framework (face/person detection), which has no Python-side
equivalent in this project -- there was no clean way to do that part here.

EXIF is copied from the original RAW via exiftool, then GPS tags are stripped unless
--keep-gps is passed. (The X2D has no GPS hardware, but metadata can still carry a
synced/injected location from other tooling, so stripping is the safe default.)

Usage:
  python3 export_photo.py --file <id> [<id> ...] --out-dir /abs/folder/for/intermediates

Prints exactly one JSON line to stdout:
  {"results": [{"file_id": N, "intermediate_path": "..."} | {"file_id": N, "error": "..."}],
   "succeeded": N, "failed": M}
Exits non-zero if any file failed.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

from photocritic import db
from photocritic.raw_decoder import default_decoder


def export_one(conn, file_id: int, out_dir: Path, keep_gps: bool) -> dict:
    row = conn.execute("SELECT filename, full_path FROM files WHERE id = ?", (file_id,)).fetchone()
    if row is None:
        return {"file_id": file_id, "error": f"no file with id {file_id}"}
    src = Path(row["full_path"])
    if not src.exists():
        return {"file_id": file_id, "error": f"source RAW not found: {src}"}

    try:
        decoded = default_decoder().decode(src)
    except Exception as e:
        return {"file_id": file_id, "error": f"decode failed: {e}"}

    img = Image.fromarray(decoded.rgb)
    out_path = out_dir / f"{file_id}.jpg"
    try:
        # Quality 95, not the pipeline's usual 92 -- this is an intermediate Swift re-encodes
        # from, so it shouldn't be the thing that caps the final output's quality.
        img.save(out_path, "JPEG", quality=95)
    except Exception as e:
        return {"file_id": file_id, "error": f"could not write {out_path}: {e}"}

    copy = subprocess.run(
        ["exiftool", "-TagsFromFile", str(src), "-all:all", "-overwrite_original", str(out_path)],
        capture_output=True, text=True,
    )
    if copy.returncode != 0:
        return {"file_id": file_id, "intermediate_path": str(out_path), "warning": f"EXIF copy failed: {copy.stderr.strip()}"}
    if not keep_gps:
        strip = subprocess.run(
            ["exiftool", "-gps:all=", "-overwrite_original", str(out_path)],
            capture_output=True, text=True,
        )
        if strip.returncode != 0:
            return {"file_id": file_id, "intermediate_path": str(out_path), "warning": f"GPS strip failed: {strip.stderr.strip()}"}

    return {"file_id": file_id, "intermediate_path": str(out_path)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", type=int, nargs="+", required=True, dest="file_ids")
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("--keep-gps", action="store_true")
    args = ap.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)

    results = []
    with db.connect() as conn:
        db.init_schema(conn)
        for file_id in args.file_ids:
            results.append(export_one(conn, file_id, args.out_dir, args.keep_gps))

    failed = sum(1 for r in results if "error" in r)
    print(json.dumps({"results": results, "succeeded": len(results) - failed, "failed": failed}))
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
