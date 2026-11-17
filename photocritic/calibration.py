"""Relative calibration: percentile-within-shoot, percentile-within-library, a library-wide
z-score, and a calibrated_score built to spread out by construction (it's a direct function of
percentile rank, so it can't cluster the way a raw rubric score legitimately might). Run as a
post-pass after any evaluation write -- see pipeline.run_evaluate and rescore.py -- over the
WHOLE library's current latest-evaluation rows, since adding or changing any one score shifts
everyone else's percentile/z slightly.

Pure-ish: compute_calibration takes the raw rows (as returned by db.latest_evaluated_files) and
returns the values to write, with no DB access itself -- see tests/test_calibration.py.
recompute_all does the DB read + write.
"""


def _percentile_rank(value: float, sorted_values: list[float]) -> float:
    """0-100: the percentage of values in `sorted_values` strictly less than `value`, plus half
    of those equal to it (the standard "mean rank" treatment for ties) -- so the single file in
    a one-file population lands at 50 (the middle), not 0 or 100, and a genuine tie for the top
    score doesn't claim the full 100th percentile for every tied file."""
    n = len(sorted_values)
    if n <= 1:
        return 50.0
    import bisect
    less = bisect.bisect_left(sorted_values, value)
    less_or_equal = bisect.bisect_right(sorted_values, value)
    equal = less_or_equal - less
    return ((less + equal / 2) / n) * 100


def _zscore(value: float, values: list[float]) -> float:
    n = len(values)
    if n <= 1:
        return 0.0
    mean = sum(values) / n
    variance = sum((v - mean) ** 2 for v in values) / n
    sd = variance ** 0.5
    return 0.0 if sd == 0 else (value - mean) / sd


def compute_calibration(rows: list[dict]) -> list[dict]:
    """rows: [{"evaluation_id", "file_id", "shoot_id", "overall_score"}, ...] (one per file, its
    latest evaluation -- see db.latest_evaluated_files). Returns one dict per row with
    percentile_shoot/percentile_library/z_score_library/calibrated_score added."""
    library_scores = sorted(r["overall_score"] for r in rows)
    by_shoot: dict[int, list[float]] = {}
    for r in rows:
        by_shoot.setdefault(r["shoot_id"], []).append(r["overall_score"])
    for shoot_id in by_shoot:
        by_shoot[shoot_id].sort()

    out = []
    for r in rows:
        score = r["overall_score"]
        percentile_shoot = _percentile_rank(score, by_shoot[r["shoot_id"]])
        percentile_library = _percentile_rank(score, library_scores)
        z_library = _zscore(score, library_scores)
        out.append({
            **r,
            "percentile_shoot": round(percentile_shoot, 1),
            "percentile_library": round(percentile_library, 1),
            "z_score_library": round(z_library, 2),
            # By construction spans close to the full 0-100 range given enough files (it IS a
            # percentile), so it's usable for ranking/filtering even on a raw-score
            # distribution that's still clustered -- a safety net independent of how well the
            # rubric/temperature changes spread out the raw scores themselves.
            "calibrated_score": round(percentile_library, 1),
        })
    return out


def recompute_all(conn) -> int:
    """Recomputes and writes calibration for every file's latest evaluation. Returns how many
    rows were updated. Cheap even at a few thousand files -- one SELECT, pure-Python stats, one
    UPDATE per row within the same transaction the caller commits."""
    from . import db

    rows = db.latest_evaluated_files(conn)
    if not rows:
        return 0
    calibrated = compute_calibration(rows)
    for r in calibrated:
        db.update_calibration(
            conn, r["evaluation_id"], r["percentile_shoot"], r["percentile_library"],
            r["z_score_library"], r["calibrated_score"],
        )
    return len(calibrated)
