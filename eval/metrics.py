"""Pure metric functions for the model comparison (no I/O, no model) -- see tests/test_eval_metrics.py.

Labels are ordinal: 1 = user's pick (keeper), 0 = unflagged, -1 = user's explicit reject.
"Keeper" for precision/recall means label == 1.
"""

from __future__ import annotations


def _ranks(values: list[float]) -> list[float]:
    """Average ranks (1-based), ties share the mean rank."""
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        avg = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def spearman(x: list[float], y: list[float]) -> float | None:
    if len(x) != len(y) or len(x) < 3:
        return None
    rx, ry = _ranks(x), _ranks(y)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    cov = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    vx = sum((a - mx) ** 2 for a in rx)
    vy = sum((b - my) ** 2 for b in ry)
    if vx == 0 or vy == 0:
        return None
    return cov / (vx * vy) ** 0.5


def roc_auc(scores: list[float], positive: list[bool]) -> float | None:
    """P(random keeper scores higher than random non-keeper); ties count half."""
    pos = [s for s, p in zip(scores, positive) if p]
    neg = [s for s, p in zip(scores, positive) if not p]
    if not pos or not neg:
        return None
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def precision_recall(predicted: list[bool], actual: list[bool]) -> dict:
    tp = sum(p and a for p, a in zip(predicted, actual))
    fp = sum(p and not a for p, a in zip(predicted, actual))
    fn = sum(a and not p for p, a in zip(predicted, actual))
    precision = tp / (tp + fp) if tp + fp else None
    recall = tp / (tp + fn) if tp + fn else None
    f1 = (2 * precision * recall / (precision + recall)) if precision and recall else None
    return {"tp": tp, "fp": fp, "fn": fn, "precision": precision, "recall": recall, "f1": f1}


def top_k_mask(scores: list[float], k: int) -> list[bool]:
    """True for the k highest scores (stable by index on ties)."""
    order = sorted(range(len(scores)), key=lambda i: (-scores[i], i))
    chosen = set(order[:k])
    return [i in chosen for i in range(len(scores))]


def percentiles(scores: list[float]) -> list[float]:
    """0..1 percentile rank within this model's own scores (1 = best in shoot)."""
    if len(scores) == 1:
        return [1.0]
    r = _ranks(scores)
    return [(x - 1) / (len(scores) - 1) for x in r]


def biggest_disagreements(file_ids: list[int], scores: list[float], labels: list[int], n: int = 10) -> list[dict]:
    """Frames where the model most strongly contradicts the user, judged on the model's own
    percentile so models with different score scales compare fairly:
      - user keeper (1) the model ranks low      -> severity = 1 - percentile
      - user reject (-1) the model ranks high    -> severity = percentile + 0.25 (explicit
        rejects outrank merely-unflagged frames at equal percentile)
      - unflagged (0) the model ranks very high  -> severity = percentile - 0.25
    """
    pct = percentiles(scores)
    rows = []
    for fid, s, lab, p in zip(file_ids, scores, labels, pct):
        if lab == 1:
            sev, kind = 1 - p, "you kept, model ranked low"
        elif lab == -1:
            sev, kind = p + 0.25, "you rejected, model ranked high"
        else:
            sev, kind = p - 0.25, "you skipped, model ranked high"
        rows.append({"file_id": fid, "score": s, "label": lab, "percentile": p, "severity": sev, "kind": kind})
    rows.sort(key=lambda r: -r["severity"])
    return rows[:n]


def summarize(file_ids: list[int], scores: list[float], recommendations: list[str], labels: list[int]) -> dict:
    """All per-model agreement metrics against the user's labels (frames the model failed to
    parse are excluded by the caller and reported separately)."""
    keeper = [lab == 1 for lab in labels]
    k = sum(keeper)
    at_threshold = precision_recall([r == "KEEP" for r in recommendations], keeper)
    at_top_k = precision_recall(top_k_mask(scores, k), keeper) if k else None
    user_rejects = [lab == -1 for lab in labels]
    model_rejects = [r == "REJECT" for r in recommendations]
    return {
        "n": len(scores),
        "user_keepers": k,
        "model_keeps": sum(r == "KEEP" for r in recommendations),
        "at_production_thresholds": at_threshold,
        "at_top_k": at_top_k,
        "roc_auc": roc_auc(scores, keeper),
        "spearman_vs_labels": spearman(scores, [float(x) for x in labels]),
        # Pre-filter safety: a pre-filter must almost never throw away a keeper.
        "keepers_model_rejects": sum(m and a for m, a in zip(model_rejects, keeper)),
        "user_rejects_caught": (sum(m and u for m, u in zip(model_rejects, user_rejects)), sum(user_rejects)),
    }
