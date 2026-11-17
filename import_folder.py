"""Command-line import: merge a folder of .3FR files (e.g. a staging folder rsynced from a
camera card) into a destination folder, then optionally run organize.py on it.

Same rules as the app's camera import (CameraImportService.swift):
  * a photo already in the destination is skipped only if its base name, size, AND a content
    check all agree -- two different frames from two different rolls can share both a name and
    a byte size, so name+size alone is a candidate match, not a confirmed one;
  * a candidate match that the content check disagrees with is copied as <stem>__<roll>[_N].<ext>
    and flagged as a possible duplicate, never silently dropped;
  * .xmp sidecars come along; hidden / AppleDouble (._*) files and _Marked_for_Deletion folders are ignored.
Copies only: the source is never modified. Each file is written to <name>.partial and
renamed once complete, so an interrupted run never leaves a truncated photo that looks
real. Dry run by default.

Usage:
  python3 import_folder.py SOURCE                    # dry run: shows what would happen
  python3 import_folder.py SOURCE --apply            # copy
  python3 import_folder.py SOURCE --apply --organize # copy, then run organize.py on the destination
  python3 import_folder.py SOURCE --dest "/other/folder" --apply
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from photocritic.curation import MARKER_DIRNAME
from photocritic.dedup import base_name, partial_digest, unique_name
from photocritic.pipeline import DUPLICATES_DIRNAME

# Folders whose photos don't count as "already imported": a photo marked for deletion (or in the
# Dupe holding pen) comes back when the card is re-plugged. Shared with organize's discovery.
SKIP_FOLDERS = {MARKER_DIRNAME, DUPLICATES_DIRNAME}

DEFAULT_DEST = Path("/Volumes/ProfessionallyUnorganized/Medium Format/Photo dump")
PROJECT_ROOT = Path(__file__).resolve().parent


def existing_files(dest: Path):
    """Destination's .3FR files: top level plus one level of subfolders (organize.py's depth),
    not counting the marker and dupe folders. Yields (name_lower, size, path); a 0-byte file is
    never a valid RAW frame and is skipped so it can't pass as a match for anything."""
    for entry in dest.iterdir():
        if entry.name.startswith(".") or (entry.is_dir() and entry.name in SKIP_FOLDERS):
            continue
        if entry.is_file() and entry.suffix.lower() == ".3fr":
            size = entry.stat().st_size
            if size > 0:
                yield entry.name.lower(), size, entry
        elif entry.is_dir():
            try:
                for f in entry.iterdir():
                    if f.is_file() and f.suffix.lower() == ".3fr" and not f.name.startswith("."):
                        size = f.stat().st_size
                        if size > 0:
                            yield f.name.lower(), size, f
            except PermissionError:
                continue


def discover(source: Path, warnings: list[str]):
    def onerror(err):
        warnings.append(str(err))

    found = []
    for root, dirs, files in os.walk(source, onerror=onerror):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != MARKER_DIRNAME]
        for f in files:
            if f.lower().endswith(".3fr") and not f.startswith("."):
                found.append(Path(root) / f)
    return sorted(found, key=lambda p: (p.name, str(p)))


def copy_verified(src: Path, target: Path):
    partial = target.with_name(target.name + ".partial")
    try:
        shutil.copy2(src, partial)
        src_size, partial_size = src.stat().st_size, partial.stat().st_size
        if src_size == 0 or partial_size == 0:
            raise OSError("source or copy is 0 bytes")
        if partial_size != src_size:
            raise OSError("size mismatch after copy")
        os.rename(partial, target)
    except BaseException:
        partial.unlink(missing_ok=True)
        raise
    xmp = src.with_suffix(".xmp")
    txmp = target.with_suffix(".xmp")
    if xmp.exists() and not txmp.exists():
        shutil.copy2(xmp, txmp)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=Path)
    ap.add_argument("--dest", type=Path, default=DEFAULT_DEST)
    ap.add_argument("--apply", action="store_true", help="actually copy (default is a dry run)")
    ap.add_argument("--organize", action="store_true", help="run organize.py on the destination afterwards (needs --apply)")
    args = ap.parse_args()

    if not args.source.is_dir():
        sys.exit(f"Source is not a folder: {args.source}")
    if not args.dest.is_dir():
        sys.exit(f"Destination is not a folder (is the drive mounted?): {args.dest}")
    if args.source.resolve() == args.dest.resolve() or args.dest.resolve() in args.source.resolve().parents:
        sys.exit("Source must not be the destination or inside it.")

    names: set[str] = set()
    # base name -> list of (size, path) already in the destination, so an actual name+size
    # collision can be resolved with a content check instead of trusting size alone.
    existing_by_base: dict[str, list[tuple[int, Path]]] = {}
    for name, size, path in existing_files(args.dest):
        names.add(name)
        existing_by_base.setdefault(base_name(name), []).append((size, path))

    scan_warnings: list[str] = []
    sources = discover(args.source, scan_warnings)
    for w in scan_warnings:
        print(f"  WARNING (could not read while scanning the card): {w}")

    copied = skipped = failed = 0
    renamed: list[tuple[str, str]] = []
    possible_duplicates: list[str] = []
    failed_stat: list[tuple[Path, str]] = []
    zero_byte: list[tuple[Path, str]] = []
    ambiguous: list[tuple[Path, str]] = []
    plan_copy: list[tuple[Path, str, int]] = []

    for src in sources:
        try:
            size = src.stat().st_size
        except OSError as e:
            failed_stat.append((src, str(e)))
            continue
        if size <= 0:
            zero_byte.append((src, "file is 0 bytes"))
            continue
        base = base_name(src.name)
        same_size = [p for s, p in existing_by_base.get(base, []) if s == size]
        is_duplicate = False
        if same_size:
            src_digest = partial_digest(src)
            if src_digest is None:
                ambiguous.append((src, "shares a name and size with an existing file; could not read it to confirm whether it's the same photo"))
                continue
            is_duplicate = any(partial_digest(p) == src_digest for p in same_size)
        if is_duplicate:
            skipped += 1
            continue
        target = src.name
        if base in existing_by_base:
            target = unique_name(src.name, src.parent.name, names)
            renamed.append((src.name, target))
            if same_size:
                possible_duplicates.append(src.name)
        names.add(target.lower())
        existing_by_base.setdefault(base, []).append((size, args.dest / target))
        plan_copy.append((src, target, size))

    for src, reason in failed_stat:
        print(f"  SKIPPED (could not stat, not treated as a duplicate): {src}: {reason}")
    for src, reason in zero_byte:
        print(f"  SKIPPED (0 bytes, not treated as a duplicate): {src}: {reason}")
    for src, reason in ambiguous:
        print(f"  SKIPPED (could not verify identity, not treated as a duplicate): {src}: {reason}")
    total_gb = sum(size for _, _, size in plan_copy) / 1e9
    print(f"{len(sources)} .3FR in {args.source}: {skipped} already in the destination, "
          f"{len(plan_copy)} to copy ({total_gb:.1f} GB), {len(renamed)} of those renamed for a name clash "
          f"({len(possible_duplicates)} of those also matched an existing file's size exactly).")
    for orig, new in renamed[:5]:
        print(f"  rename: {orig} -> {new}")
    if len(renamed) > 5:
        print(f"  ...and {len(renamed) - 5} more")

    if not args.apply:
        print("Dry run — nothing copied. Re-run with --apply.")
        return

    consecutive = 0
    for i, (src, target, _) in enumerate(plan_copy, start=1):
        try:
            copy_verified(src, args.dest / target)
            copied += 1
            consecutive = 0
        except Exception as e:
            failed += 1
            consecutive += 1
            print(f"  FAILED {src.name}: {e}", flush=True)
            if consecutive >= 3:
                print("ABORT: 3 failures in a row — is the drive or connection dropping? Re-run to resume.", flush=True)
                break
        print(f"PROGRESS import: {i}/{len(plan_copy)}", flush=True)

    failed += len(failed_stat) + len(zero_byte) + len(ambiguous) + len(scan_warnings)
    print(f"Done: copied {copied}, skipped {skipped}, failed {failed}.")
    if failed:
        sys.exit(1)
    if args.organize and copied:
        print("Running organize.py ...", flush=True)
        py = PROJECT_ROOT / ".venv/bin/python3"
        sys.exit(subprocess.call([str(py), str(PROJECT_ROOT / "organize.py"), str(args.dest)], cwd=PROJECT_ROOT))
    if copied:
        print("Next: python3 organize.py \"%s\"  (or re-run with --organize)" % args.dest)


if __name__ == "__main__":
    main()
