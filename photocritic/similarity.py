"""Perceptual-hash based duplicate/near-duplicate detection and similarity grouping."""

from dataclasses import dataclass

import imagehash
from PIL import Image

from . import config


def phash(image_path) -> imagehash.ImageHash:
    with Image.open(image_path) as img:
        return imagehash.phash(img)  # default 8x8 -> 64-bit hash, distance range 0-64


@dataclass
class SimilarityGroup:
    members: list  # list of (stem, phash) in insertion order


def group_by_similarity(
    hashes: dict, threshold: int = config.SIMILARITY_HASH_THRESHOLD
) -> list[list[str]]:
    """hashes: {stem: imagehash.ImageHash}. Union-find clustering on Hamming distance."""
    stems = list(hashes.keys())
    parent = {s: s for s in stems}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    for i in range(len(stems)):
        for j in range(i + 1, len(stems)):
            a, b = stems[i], stems[j]
            if hashes[a] - hashes[b] <= threshold:
                union(a, b)

    clusters: dict = {}
    for s in stems:
        clusters.setdefault(find(s), []).append(s)

    return [members for members in clusters.values() if len(members) > 1]
