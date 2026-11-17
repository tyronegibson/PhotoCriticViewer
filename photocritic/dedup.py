"""Shared identity rule for camera imports: the X2D resets its filename counter
across DCIM roll folders, so two genuinely different photos can share a name.
A same-name file is only a *candidate* duplicate; it's confirmed only if a
content check (partial_digest) agrees too, since two different frames can
plausibly share both a name and a byte size. A same-name file that isn't
confirmed gets a disambiguated name instead of being dropped. Used by every
Python entry point that imports from a card (import_folder.py today);
CameraImportService.swift implements the identical rule on the Swift side
since Swift/Python can't share this module directly."""

import hashlib
import os

_CHUNK = 1_048_576


def base_name(name: str) -> str:
    """'b0004520__crystal o_2.3fr' -> 'b0004520.3fr'"""
    name = name.lower()
    if "__" not in name:
        return name
    return name.split("__", 1)[0] + "." + name.rsplit(".", 1)[1]


def roll_component(roll: str) -> str:
    """Make a roll/folder name safe to embed in a single filename: no separators,
    and never '.' or '..', so the destination path can't escape its folder."""
    safe = roll.replace("/", "_").replace("\\", "_").replace(":", "_").strip()
    return "unknown" if safe in ("", ".", "..") else safe


def unique_name(name: str, roll: str, taken: set[str]) -> str:
    """'<stem>__<roll>.<ext>', falling back to a numeric suffix if that's taken too."""
    roll = roll_component(roll)
    stem, ext = os.path.splitext(name)
    candidate, n = f"{stem}__{roll}{ext}", 2
    while candidate.lower() in taken:
        candidate = f"{stem}__{roll}_{n}{ext}"
        n += 1
    return candidate


def partial_digest(path) -> str | None:
    """Hashes the first and last 1 MB of a file (the whole file if smaller) rather than
    every byte -- a cheap-but-strong-enough content check. A full-file hash would be
    stronger but too slow to run across an entire destination index on every import; this
    only ever runs on the handful of files that already collided on base name AND size.
    Returns None (never a digest) for an unreadable or empty file, so a caller can fail
    closed instead of silently treating an unverifiable file as a match either way."""
    try:
        size = path.stat().st_size
        if size <= 0:
            return None
        h = hashlib.sha256()
        with open(path, "rb") as f:
            h.update(f.read(min(_CHUNK, size)))
            if size > _CHUNK:
                f.seek(size - _CHUNK)
                h.update(f.read(_CHUNK))
        return h.hexdigest()
    except OSError:
        return None
