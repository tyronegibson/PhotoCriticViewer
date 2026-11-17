"""CLI: re-score photos under the current evaluation settings (config.EVALUATION_PROMPT_VERSION
-- prompt, temperature, self-consistency N, category weights), and print a before/after score
distribution so you can see whether a rubric/temperature change actually produced more spread.
Old evaluation rows are NEVER touched or deleted -- a re-score writes a NEW ai_evaluations row
(a different prompt_version means no UNIQUE collision with the old one), and the "latest
evaluation" views everywhere else just pick it up as the current one.

A sample re-score (--sample N, default 50) picks N files spread across as many shoots as
possible, prints the BEFORE histogram, re-evaluates them, then prints the AFTER histogram plus
summary stats (mean, SD, range, KEEP/MAYBE/REJECT share).

A full-library re-score (--all) does the same over EVERY currently-evaluated file. It backs up
the database first and requires typing "yes" to confirm (or --yes for scripting) -- this
re-scores real client-delivery decisions for the whole library, not something to trigger by
accident.

Usage:
  python3 rescore.py --sample 50
  python3 rescore.py --all
  python3 rescore.py --all --yes
"""

import argparse
import shutil
import sys
from datetime import datetime, timezone

from photocritic import config, db, pipeline


def _latest_overall_scores(conn, file_ids: list[int]) -> list[float]:
    rows = conn.execute(
        f"SELECT MAX(id), overall_score FROM ai_evaluations WHERE file_id IN "
        f"({','.join('?' * len(file_ids))}) GROUP BY file_id",
        file_ids,
    ).fetchall()
    return [r["overall_score"] for r in rows if r["overall_score"] is not None]


def _recommendation_share(conn, file_ids: list[int]) -> dict:
    rows = conn.execute(
        f"SELECT MAX(id), recommendation FROM ai_evaluations WHERE file_id IN "
        f"({','.join('?' * len(file_ids))}) GROUP BY file_id",
        file_ids,
    ).fetchall()
    share = {"KEEP": 0, "MAYBE": 0, "REJECT": 0, "NONE": 0}
    for r in rows:
        share[r["recommendation"] if r["recommendation"] in share else "NONE"] += 1
    return share


def _histogram(scores: list[float], label: str, bucket_size: int = 10) -> None:
    print(f"\n{label} (n={len(scores)}):")
    if not scores:
        print("  (no scores)")
        return
    buckets: dict[int, int] = {}
    for s in scores:
        b = min(int(s // bucket_size) * bucket_size, 90)
        buckets[b] = buckets.get(b, 0) + 1
    for b in range(0, 100, bucket_size):
        count = buckets.get(b, 0)
        print(f"  {b:3d}-{b + bucket_size - 1:<3d} | {'#' * count} {count}")
    mean = sum(scores) / len(scores)
    sd = (sum((s - mean) ** 2 for s in scores) / len(scores)) ** 0.5
    print(f"  mean={mean:.1f}  sd={sd:.1f}  range={max(scores) - min(scores):.1f}  "
          f"min={min(scores):.1f}  max={max(scores):.1f}")


def _sample_file_ids(conn, n: int) -> list[int]:
    """Round-robins across shoots so the sample isn't accidentally dominated by one or two
    large shoots -- "a sample across shoots", not just the first N rows."""
    rows = conn.execute("""
        SELECT f.id, f.shoot_id FROM files f
        JOIN ai_evaluations ae ON ae.file_id = f.id
        GROUP BY f.id ORDER BY f.shoot_id, f.id
    """).fetchall()
    by_shoot: dict[int, list[int]] = {}
    for r in rows:
        by_shoot.setdefault(r["shoot_id"], []).append(r["id"])

    picked: list[int] = []
    shoot_iters = {sid: iter(ids) for sid, ids in by_shoot.items()}
    while len(picked) < n and shoot_iters:
        for sid in list(shoot_iters):
            if len(picked) >= n:
                break
            try:
                picked.append(next(shoot_iters[sid]))
            except StopIteration:
                del shoot_iters[sid]
    return picked


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--sample", type=int, metavar="N", help="re-score N files spread across shoots")
    group.add_argument("--all", action="store_true", help="re-score the ENTIRE library (asks to confirm first)")
    group.add_argument(
        "--recompute-scores-only", action="store_true",
        help="no model call -- just re-derive overall_score/classification/recommendation for "
             "every existing evaluation_v4-family row from its already-stored category scores "
             "(use after tuning CATEGORY_WEIGHTS/OVERALL_SCORE_CONTRAST in config.py)",
    )
    ap.add_argument("--yes", action="store_true", help="skip the --all confirmation prompt (for scripting)")
    args = ap.parse_args()

    if args.recompute_scores_only:
        with db.connect() as conn:
            db.init_schema(conn)
            file_ids = [r["file_id"] for r in conn.execute(
                "SELECT file_id FROM ai_evaluations WHERE prompt_version LIKE 'evaluation_v4%'"
            ).fetchall()]
            _histogram(_latest_overall_scores(conn, file_ids), "BEFORE (existing v4 rows)")
            updated = pipeline.recompute_overall_scores(conn)
            _histogram(_latest_overall_scores(conn, file_ids), "AFTER recompute")
            print(f"\nRecomputed {updated} row(s). No model call made.")
        return

    with db.connect() as conn:
        db.init_schema(conn)

        if args.all:
            file_ids = [r["file_id"] for r in db.latest_evaluated_files(conn)]
            if not file_ids:
                sys.exit("No evaluated files to re-score.")
            if not args.yes:
                answer = input(
                    f"This will re-score ALL {len(file_ids)} currently-evaluated file(s) under "
                    f"{config.EVALUATION_PROMPT_VERSION}. Old evaluations are kept, not deleted. "
                    f"Type 'yes' to continue: "
                )
                if answer.strip().lower() != "yes":
                    print("Cancelled — nothing was re-scored.")
                    return
            backup = config.DATABASE_DIR / f"photocritic.db.bak-pre-rescore-all-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}"
            shutil.copy2(config.DATABASE_PATH, backup)
            print(f"Backed up database to {backup}")
        else:
            file_ids = _sample_file_ids(conn, args.sample)
            if not file_ids:
                sys.exit("No evaluated files found to sample from.")

        _histogram(_latest_overall_scores(conn, file_ids), "BEFORE")
        before_share = _recommendation_share(conn, file_ids)
        print(f"  KEEP={before_share['KEEP']} MAYBE={before_share['MAYBE']} REJECT={before_share['REJECT']}")

    print(f"\nRe-scoring {len(file_ids)} file(s) under {config.EVALUATION_PROMPT_VERSION} "
          f"(temperature={config.EVALUATION_TEMPERATURE}, "
          f"self_consistency_n={config.EVALUATION_SELF_CONSISTENCY_N}) ...")
    pipeline.evaluate_specific_files(file_ids)

    with db.connect() as conn:
        after_scores = _latest_overall_scores(conn, file_ids)
        _histogram(after_scores, "AFTER")
        after_share = _recommendation_share(conn, file_ids)
        print(f"  KEEP={after_share['KEEP']} MAYBE={after_share['MAYBE']} REJECT={after_share['REJECT']}")

    if len(after_scores) > 1:
        mean = sum(after_scores) / len(after_scores)
        sd = (sum((s - mean) ** 2 for s in after_scores) / len(after_scores)) ** 0.5
        score_range = max(after_scores) - min(after_scores)
        verdict = "PASS" if sd >= 8 and score_range >= 50 else "below target"
        print(f"\nAFTER: sd={sd:.1f} range={score_range:.1f} ({verdict} -- target sd>=8, range>=50)")


if __name__ == "__main__":
    main()
