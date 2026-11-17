"""EXIF metadata extraction via the exiftool CLI."""

import json
import sys
import subprocess
import tempfile
from pathlib import Path


EXIF_ARGS = ["-Model", "-LensModel", "-ISO", "-FNumber", "-ExposureTime",
             "-FocalLength", "-DateTimeOriginal"]


def _fields_from_exiftool_row(data: dict) -> dict:
    return {
        "camera_model": data.get("Model"),
        "lens": data.get("LensModel"),
        "iso": data.get("ISO"),
        "aperture": str(data.get("FNumber")) if data.get("FNumber") is not None else None,
        "shutter_speed": data.get("ExposureTime"),
        "focal_length": data.get("FocalLength"),
        "capture_time": data.get("DateTimeOriginal"),
        "raw": data,
    }


def read_exif(path: Path) -> dict:
    out = subprocess.run(
        ["exiftool", "-j", *EXIF_ARGS, str(path)],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(out.stdout)[0]
    return _fields_from_exiftool_row(data)


def read_exif_batch(paths: list[Path]) -> dict[Path, dict]:
    """One exiftool call for many files — used to date-group a folder's RAWs
    into shoots before any file/shoot rows exist. Ingest still calls read_exif
    per file for the metadata row itself, so a failed batch here just falls
    back to per-file mtime-based grouping rather than blocking ingest.

    File paths go through exiftool's -@ argfile mechanism (a temp file, one
    path per line) rather than as literal command-line arguments — an archive
    of several thousand files blows past macOS's ARG_MAX as a plain argv
    list, raising "OSError: [Errno 7] Argument list too long" before
    exiftool even runs."""
    if not paths:
        return {}

    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        f.write("\n".join(str(p) for p in paths))
        argfile_path = f.name

    try:
        out = subprocess.run(
            ["exiftool", "-j", *EXIF_ARGS, "-@", argfile_path],
            capture_output=True, text=True,
        )
    except FileNotFoundError as e:
        raise RuntimeError("exiftool is not installed or not on PATH (brew install exiftool); "
                           "refusing to ingest these photos with no capture dates") from e
    finally:
        Path(argfile_path).unlink(missing_ok=True)

    # exiftool exits 1 if any single file in the batch errors (vanished mid-scan, mid-copy,
    # unreadable) while still printing a JSON row for every other file. Keep those rows.
    # What must fail closed: no parseable output at all, or nothing usable back — that
    # would ingest every photo in the batch with no capture date.
    try:
        rows = json.loads(out.stdout) if out.stdout.strip() else None
    except json.JSONDecodeError:
        rows = None
    if not rows:
        raise RuntimeError(f"exiftool produced no usable output (exit {out.returncode}): "
                           f"{out.stderr.strip()[:500] or 'no stderr'}")

    rows_by_source = {row.get("SourceFile"): row for row in rows}
    result = {}
    missing = []
    for path in paths:
        row = rows_by_source.get(str(path))
        if row is not None:
            result[path] = _fields_from_exiftool_row(row)
        else:
            missing.append(path)
    if missing:
        print(f"WARNING: exiftool returned no row for {len(missing)} of {len(paths)} file(s) "
              f"(exit {out.returncode}); those fall back to file-date grouping:", file=sys.stderr, flush=True)
        for path in missing[:20]:
            print(f"  {path}", file=sys.stderr, flush=True)
    return result
