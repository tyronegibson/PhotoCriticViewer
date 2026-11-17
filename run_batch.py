"""CLI entry point: process a shoot folder end-to-end.

Usage: python3 run_batch.py "/path/to/shoot folder"
"""

import sys
from pathlib import Path

from photocritic.pipeline import run_full_pipeline

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 run_batch.py <shoot_folder>", file=sys.stderr)
        sys.exit(1)

    folder = Path(sys.argv[1])
    if not folder.is_dir():
        print(f"Not a directory: {folder}", file=sys.stderr)
        sys.exit(1)

    run_full_pipeline(folder)
    print("Done.")
