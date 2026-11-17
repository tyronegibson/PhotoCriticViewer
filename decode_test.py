"""Phase 2 POC: decode .3FR files with rawpy/LibRaw and write analysis-quality previews."""

import sys
import time
from pathlib import Path

import rawpy
from PIL import Image

SOURCE_DIR = Path(
    "/path/to/raw/folder"
)
# POC output only. Live previews are {file_id}.jpg and must never be written by these scripts.
PREVIEW_DIR = Path("/Volumes/AI-/PhotoCritic/poc-previews")
PREVIEW_DIR.mkdir(parents=True, exist_ok=True)

FILES = ["B0001056", "B0001057", "B0001058", "B0001059", "B0001060"]
LONG_EDGE = 1568  # Qwen3-VL-friendly analysis resolution


def decode_one(stem: str) -> dict:
    src = SOURCE_DIR / f"{stem}.3FR"
    t0 = time.time()
    with rawpy.imread(str(src)) as raw:
        rgb = raw.postprocess(
            use_camera_wb=True,
            half_size=False,
            no_auto_bright=False,
            output_bps=8,
        )
    decode_s = time.time() - t0

    img = Image.fromarray(rgb)
    w, h = img.size
    scale = LONG_EDGE / max(w, h)
    resized = img.resize((round(w * scale), round(h * scale)), Image.LANCZOS)

    out_path = PREVIEW_DIR / f"{stem}.jpg"
    resized.save(out_path, "JPEG", quality=92)

    return {
        "file": src.name,
        "source_size_mb": round(src.stat().st_size / 1e6, 1),
        "decoded_px": f"{w}x{h}",
        "preview_px": f"{resized.width}x{resized.height}",
        "decode_seconds": round(decode_s, 2),
        "preview_path": str(out_path),
    }


if __name__ == "__main__":
    results = []
    for stem in FILES:
        try:
            r = decode_one(stem)
            results.append(r)
            print(f"OK  {r}")
        except Exception as e:
            print(f"FAIL {stem}: {e}", file=sys.stderr)
            raise
