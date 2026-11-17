"""Computes overall_score/classification/recommendation from category scores IN CODE, using
configurable weights/thresholds (config.CATEGORY_WEIGHTS/GRADE_THRESHOLDS/RECOMMENDATION_THRESHOLDS)
-- as of evaluation_v4, the model only returns per-category scores + reasons; it no longer picks
its own grade. Also handles self-consistency combination (median across repeated samples) and
reading category scores out of either the v4 nested shape or the legacy (v1-v3) flat "scores"
dict, since old evaluation_json rows are never rewritten -- just read differently going forward.

Pure functions, no DB/model access -- see tests/test_scoring.py.
"""

from . import config


def extract_category_scores(parsed: dict) -> dict[str, float]:
    """v4+: parsed["category_evaluations"][cat]["score"]. v1-v3 (legacy rows, never rewritten):
    parsed["scores"][cat]. Values that aren't numbers are skipped rather than raising, so one
    malformed category can't take down the whole computation."""
    nested = parsed.get("category_evaluations")
    if isinstance(nested, dict):
        out = {}
        for cat, entry in nested.items():
            if isinstance(entry, dict) and isinstance(entry.get("score"), (int, float)):
                out[cat] = float(entry["score"])
        return out
    flat = parsed.get("scores")
    if isinstance(flat, dict):
        return {cat: float(v) for cat, v in flat.items() if isinstance(v, (int, float))}
    return {}


def extract_category_reasons(parsed: dict) -> dict[str, str]:
    """v4+ only -- the one-line reason written before each category's score. {} for legacy
    rows, which never had per-category reasons (just one shoot-level "reasoning" sentence)."""
    nested = parsed.get("category_evaluations")
    if not isinstance(nested, dict):
        return {}
    return {
        cat: entry["reason"]
        for cat, entry in nested.items()
        if isinstance(entry, dict) and isinstance(entry.get("reason"), str)
    }


def weighted_overall(
    category_scores: dict[str, float], weights: dict[str, float] | None = None,
    center: float | None = None, contrast: float | None = None,
) -> float | None:
    """0-100 overall score from 0-10 category scores: a weighted average, then a contrast
    stretch around `center` (0-10 scale) by `contrast` -- see config.py's OVERALL_SCORE_CENTER/
    OVERALL_SCORE_CONTRAST for why the stretch exists (a plain weighted average compresses
    spread) and how 1.5 was chosen. contrast=1.0 is a no-op (plain weighted average, scaled).
    Weights don't need to sum to 1 -- normalized by whichever categories are actually present,
    so a legacy row missing a category, or a future prompt version adding one, both degrade
    gracefully instead of erroring. None if no scoreable categories are present at all (never
    fabricate a 0 from nothing). Clamped to the valid 0-10 range before scaling to 0-100."""
    weights = weights if weights is not None else config.CATEGORY_WEIGHTS
    center = center if center is not None else config.OVERALL_SCORE_CENTER
    contrast = contrast if contrast is not None else config.OVERALL_SCORE_CONTRAST
    total_weight = 0.0
    total = 0.0
    for cat, score in category_scores.items():
        w = weights.get(cat, 1.0)
        total += score * w
        total_weight += w
    if total_weight <= 0:
        return None
    mean_0_10 = total / total_weight
    stretched = center + (mean_0_10 - center) * contrast
    stretched = max(0.0, min(10.0, stretched))
    return round(stretched * 10, 2)  # 0-10 scale -> 0-100


def grade_for(score: float, thresholds: list[tuple[float, str]] | None = None) -> str:
    thresholds = thresholds if thresholds is not None else config.GRADE_THRESHOLDS
    for cutoff, label in thresholds:
        if score >= cutoff:
            return label
    return thresholds[-1][1] if thresholds else "F"


def recommendation_for(score: float, thresholds: list[tuple[float, str]] | None = None) -> str:
    thresholds = thresholds if thresholds is not None else config.RECOMMENDATION_THRESHOLDS
    for cutoff, label in thresholds:
        if score >= cutoff:
            return label
    return thresholds[-1][1] if thresholds else "REJECT"


def score_in_code(parsed: dict) -> dict:
    """Takes the model's parsed JSON (category scores/reasons only, per evaluation_v4) and
    returns it with overall_score/classification/recommendation computed in code and injected --
    this is what actually gets passed to db.save_evaluation. Leaves `parsed` itself untouched
    (returns a new dict) and leaves every other key as the model wrote it."""
    category_scores = extract_category_scores(parsed)
    overall = weighted_overall(category_scores)
    result = dict(parsed)
    result["overall_score"] = overall
    result["classification"] = grade_for(overall) if overall is not None else None
    result["recommendation"] = recommendation_for(overall) if overall is not None else None
    return result


def median_combine(parsed_samples: list[dict]) -> dict:
    """Self-consistency combiner for config.EVALUATION_SELF_CONSISTENCY_N > 1 independent
    samples of the SAME image: takes the per-category MEDIAN score across samples (median, not
    mean, so one outlier sample doesn't drag a category's score), then uses whichever sample's
    own category scores are closest (smallest total absolute deviation) to those medians as the
    "representative" sample for text fields (reasons/strengths/weaknesses/etc. can't be
    averaged). A single sample (the common case) is returned as-is."""
    if len(parsed_samples) <= 1:
        return parsed_samples[0] if parsed_samples else {}

    per_sample_scores = [extract_category_scores(p) for p in parsed_samples]
    all_categories = sorted({cat for scores in per_sample_scores for cat in scores})

    medians: dict[str, float] = {}
    for cat in all_categories:
        values = sorted(scores[cat] for scores in per_sample_scores if cat in scores)
        if not values:
            continue
        n = len(values)
        medians[cat] = values[n // 2] if n % 2 else (values[n // 2 - 1] + values[n // 2]) / 2

    best_idx = 0
    best_distance = float("inf")
    for i, scores in enumerate(per_sample_scores):
        distance = sum(abs(scores.get(cat, medians[cat]) - medians[cat]) for cat in all_categories)
        if distance < best_distance:
            best_distance = distance
            best_idx = i

    combined = dict(parsed_samples[best_idx])
    combined_categories = dict(combined.get("category_evaluations") or {})
    for cat, median_score in medians.items():
        entry = dict(combined_categories.get(cat) or {})
        entry["score"] = round(median_score, 2)
        combined_categories[cat] = entry
    combined["category_evaluations"] = combined_categories
    combined["_self_consistency_sample_count"] = len(parsed_samples)
    return combined
