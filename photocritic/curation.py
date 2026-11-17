"""Marks originals for deletion instead of removing them outright: moves the
RAW file (and its .xmp sidecar, if any) into a `_Marked_for_Deletion` folder
beside it, and drops the disposable preview JPEG cache. The RAW file is never
permanently erased by this tool — that decision is left to the photographer,
later, in Finder."""

import shutil
from pathlib import Path

MARKER_DIRNAME = "_Marked_for_Deletion"


def mark_for_deletion(full_path: str, preview_path: str | None) -> str | None:
    """Returns an error string on failure, None on success (including when the
    source file is already gone — nothing left to move)."""
    src = Path(full_path)
    try:
        if src.exists():
            marker_dir = src.parent / MARKER_DIRNAME
            marker_dir.mkdir(exist_ok=True)
            shutil.move(str(src), str(marker_dir / src.name))
            xmp = src.with_suffix(".xmp")
            if xmp.exists():
                shutil.move(str(xmp), str(marker_dir / xmp.name))
    except OSError as e:
        return str(e)

    if preview_path:
        preview = Path(preview_path)
        if preview.exists():
            try:
                preview.unlink()
            except OSError:
                pass  # cache cleanup is best-effort — not worth failing the delete over

    return None
