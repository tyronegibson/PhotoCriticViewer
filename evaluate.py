"""CLI: Phase 2 of processing a folder — the slow, GPU-heavy stage. Scores every photo in the
given shoot(s) with the vision model and ranks each similarity group's bursts. Run organize.py
first; use its printed shoot_ids here, selectively, rather than evaluating an entire unsorted
archive at once.

--files evaluates ONLY the given file ids (used by the local API's POST /critique with "ids")
rather than their whole shoot(s) -- it skips look detection (a whole-shoot derived feature) but
still re-ranks any similarity group one of those files belongs to. --shoot and --files are
mutually exclusive.

Usage:
  python3 evaluate.py --shoot <id> [<id> ...]
  python3 evaluate.py --files <id> [<id> ...]
"""

import argparse
import json

from photocritic.pipeline import evaluate_specific_files, run_evaluate

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--shoot", type=int, nargs="+", help="shoot_id(s) to evaluate in full")
    group.add_argument("--files", type=int, nargs="+", help="file_id(s) to evaluate -- not their whole shoot")
    args = parser.parse_args()

    if args.shoot:
        for shoot_id in args.shoot:
            print(f"\n=== Evaluating shoot {shoot_id} ===")
            run_evaluate(shoot_id)
    else:
        print(f"\n=== Evaluating {len(args.files)} file(s) ===")
        summary = evaluate_specific_files(args.files)
        if summary["missing"]:
            print(f"  WARNING: no such file id(s): {summary['missing']}")
        print(f"  evaluated {len(summary['evaluated'])} file(s), re-ranked {len(summary['groups_reranked'])} group(s)")
        print("RESULT " + json.dumps(summary), flush=True)

    print("\nDone.")
