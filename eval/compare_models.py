"""Compare vision models on one finished shoot against the photographer's own blind cull.

    .venv-eval/bin/python eval/compare_models.py prepare --shoot-id 149 \
        --collection "PCV Eval - Blind Cull"
    .venv-eval/bin/python eval/compare_models.py run [--models qwen36-35b,qwen36-35b-think] [--limit 16]
    .venv-eval/bin/python eval/compare_models.py report

Everything is written under /Volumes/AI-/PhotoCritic/eval/<date>/ (override with --eval-dir):
    manifest.json        frozen inputs: frames, preview paths, ground-truth labels, prod scores
    lrcat-copy/          the copy of the Lightroom catalog the labels were read from
    runs/<slug>.jsonl    per-frame results for each model (resumable)
    runs/<slug>.stats.json
    report.md / report.html

Safety: the production database is opened with PRAGMA query_only=ON and never written; the
Lightroom catalog is copied first and only the copy is read; photos and previews are only read.

Ground truth labels (from the Lightroom flags on the blind-cull collection):
    Pick (P) = 1 keeper, unflagged = 0, Reject (X) = -1.
"""

from __future__ import annotations

import argparse
import base64
import html
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO))

import metrics  # noqa: E402

PROD_DB = Path("/Volumes/AI-/PhotoCritic/database/photocritic.db")
DEFAULT_CATALOG = Path.home() / "Pictures/Lightroom/Lightroom Catalog.lrcat"
EVAL_ROOT = Path("/Volumes/AI-/PhotoCritic/eval")
PROD_MODEL_VERSION = "mlx-community/Qwen3-VL-30B-A3B-Instruct-8bit"
EVAL_PYTHON = REPO / ".venv-eval/bin/python"


def load_models() -> list[dict]:
    return json.loads((HERE / "models.json").read_text())["models"]


# ---------------------------------------------------------------- prepare

def _read_prod(shoot_id: int) -> list[dict]:
    from photocritic import config

    if not PROD_DB.exists():
        sys.exit(f"production DB not found: {PROD_DB}")
    conn = sqlite3.connect(PROD_DB)
    conn.execute("PRAGMA query_only=ON")
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """SELECT f.id AS file_id, f.filename, f.full_path, t.preview_path,
                  e.overall_score AS prod_score, e.recommendation AS prod_recommendation
           FROM files f
           LEFT JOIN technical_analysis t ON t.file_id = f.id
           LEFT JOIN ai_evaluations e ON e.file_id = f.id AND e.model_version = ? AND e.prompt_version = ?
           WHERE f.shoot_id = ? ORDER BY f.filename""",
        (PROD_MODEL_VERSION, config.EVALUATION_PROMPT_VERSION, shoot_id),
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def _copy_catalog(catalog: Path, dest_dir: Path) -> Path:
    dest_dir.mkdir(parents=True, exist_ok=True)
    for suffix in ("", "-wal", "-shm"):
        src = Path(str(catalog) + suffix)
        if src.exists():
            shutil.copy2(src, dest_dir / ("catalog.lrcat" + suffix))
    return dest_dir / "catalog.lrcat"


def _read_flags(catalog_copy: Path, collection: str) -> dict[str, int]:
    conn = sqlite3.connect(catalog_copy)
    rows = conn.execute(
        """SELECT rf.absolutePath || fo.pathFromRoot || f.baseName || '.' || f.extension AS path, i.pick
           FROM AgLibraryCollection c
           JOIN AgLibraryCollectionImage ci ON ci.collection = c.id_local
           JOIN Adobe_images i ON i.id_local = ci.image
           JOIN AgLibraryFile f ON f.id_local = i.rootFile
           JOIN AgLibraryFolder fo ON fo.id_local = f.folder
           JOIN AgLibraryRootFolder rf ON rf.id_local = fo.rootFolder
           WHERE c.name = ?""",
        (collection,),
    ).fetchall()
    conn.close()
    return {p: int(round(pick or 0)) for p, pick in rows}


def cmd_prepare(args) -> None:
    eval_dir = Path(args.eval_dir)
    manifest_path = eval_dir / "manifest.json"
    if manifest_path.exists() and not args.force:
        sys.exit(f"{manifest_path} exists; pass --force to rebuild it (re-reads the Lightroom flags)")
    if subprocess.run(["pgrep", "-x", "Adobe Lightroom Classic"], capture_output=True).returncode == 0:
        print("note: Lightroom is running -- quit it first so the latest flags are flushed to the catalog file")

    frames = _read_prod(args.shoot_id)
    catalog_copy = _copy_catalog(Path(args.catalog), eval_dir / "lrcat-copy")
    flags = _read_flags(catalog_copy, args.collection)
    if not flags:
        sys.exit(f"collection {args.collection!r} not found or empty in {args.catalog}")

    kept, missing_preview, not_in_collection = [], [], []
    for f in frames:
        if f["full_path"] not in flags:
            not_in_collection.append(f["filename"])
            continue
        if not f["preview_path"] or not Path(f["preview_path"]).exists():
            missing_preview.append(f["filename"])
            continue
        f["label"] = flags[f["full_path"]]
        kept.append(f)
    n_pick = sum(f["label"] == 1 for f in kept)
    if n_pick == 0:
        sys.exit("no Picks (P flags) found in the collection -- has the cull been done and Lightroom quit?")

    manifest = {
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "shoot_id": args.shoot_id,
        "collection": args.collection,
        "catalog_source": str(args.catalog),
        "labels": {"pick": n_pick, "unflagged": sum(f["label"] == 0 for f in kept),
                   "reject": sum(f["label"] == -1 for f in kept)},
        "excluded": {"not_in_collection": not_in_collection, "missing_preview": missing_preview},
        "frames": kept,
    }
    eval_dir.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"manifest: {len(kept)} frames, labels {manifest['labels']}, "
          f"excluded {len(not_in_collection)} not in collection / {len(missing_preview)} missing preview")
    print(manifest_path)


# ---------------------------------------------------------------- run

def _select(models: list[dict], names: str | None) -> list[dict]:
    if not names:
        return [m for m in models if m.get("default")]
    by_slug = {m["slug"]: m for m in models}
    unknown = [n for n in names.split(",") if n not in by_slug]
    if unknown:
        sys.exit(f"unknown model slug(s): {unknown}; known: {sorted(by_slug)}")
    return [by_slug[n] for n in names.split(",")]


def cmd_run(args) -> None:
    eval_dir = Path(args.eval_dir)
    manifest = eval_dir / "manifest.json"
    if not manifest.exists():
        sys.exit(f"no manifest at {manifest}; run `prepare` first")
    runs = eval_dir / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    for m in _select(load_models(), args.models):
        batch = args.batch_size or m["batch_size"]
        for attempt in range(3):
            env = dict(os.environ,
                       PHOTOCRITIC_VLM_MODEL=m["repo"],
                       PHOTOCRITIC_VLM_THINKING="on" if m["thinking"] else "off",
                       PHOTOCRITIC_EVAL_BATCH_SIZE=str(batch),
                       PHOTOCRITIC_LEGACY_BATCH_TEMPLATE="on" if m.get("legacy_template") else "off",
                       HF_HUB_OFFLINE="1")  # never download during a run
            env.pop("PHOTOCRITIC_WORKSPACE", None)
            cmd = [str(EVAL_PYTHON), str(HERE / "run_model.py"), "--manifest", str(manifest),
                   "--out", str(runs / f"{m['slug']}.jsonl"), "--stats", str(runs / f"{m['slug']}.stats.json"),
                   "--batch-size", str(batch)]
            if args.limit:
                cmd += ["--limit", str(args.limit)]
            print(f"\n=== {m['slug']} ({m['repo']}, thinking={m['thinking']}, batch={batch})", flush=True)
            # caffeinate: a long run once died from a GPU reset when the Mac tried to sleep.
            rc = subprocess.run(["caffeinate", "-dimsu", *cmd], env=env, cwd=REPO).returncode
            if rc == 0:
                break
            # A Metal OOM aborts the process (killed by a signal: rc < 0). A normal Python error
            # (rc > 0) won't be fixed by a smaller batch, so don't retry it.
            if rc > 0 or batch == 1:
                print(f"!!! {m['slug']} failed (exit {rc}); skipping -- see the traceback above", flush=True)
                break
            batch = max(1, batch // 2)
            print(f"!!! {m['slug']} exited {rc} (likely Metal OOM); resuming at batch {batch}", flush=True)


# ---------------------------------------------------------------- report

def _load_run(path: Path) -> dict[int, dict]:
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                out[r["file_id"]] = r  # last write wins
    return out


def _thumb(preview_path: str, size: int = 320) -> str:
    from PIL import Image

    with Image.open(preview_path) as im:
        im.thumbnail((size, size))
        buf = io.BytesIO()
        im.convert("RGB").save(buf, "JPEG", quality=80)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


def _fmt(x, pct=False):
    if x is None:
        return "–"
    if isinstance(x, float):
        return f"{x * 100:.0f}%" if pct else f"{x:.2f}"
    return str(x)


def cmd_report(args) -> None:
    eval_dir = Path(args.eval_dir)
    manifest = json.loads((eval_dir / "manifest.json").read_text())
    frames = {f["file_id"]: f for f in manifest["frames"]}
    models = load_models()
    present = [m for m in models if (eval_dir / "runs" / f"{m['slug']}.jsonl").exists()]

    results, rows_for_corr = {}, {}
    # Production scores (scored earlier with mlx_vlm 0.6.17) as a reference column.
    prod = {fid: f["prod_score"] for fid, f in frames.items() if f.get("prod_score") is not None}
    for m in present:
        run = _load_run(eval_dir / "runs" / f"{m['slug']}.jsonl")
        ok = [run[fid] for fid in frames if fid in run and run[fid]["ok"] and run[fid]["overall_score"] is not None]
        fids = [r["file_id"] for r in ok]
        scores = [r["overall_score"] for r in ok]
        labels = [frames[fid]["label"] for fid in fids]
        summary = metrics.summarize(fids, scores, [r["recommendation"] for r in ok], labels) if ok else None
        stats_path = eval_dir / "runs" / f"{m['slug']}.stats.json"
        stats = json.loads(stats_path.read_text()) if stats_path.exists() else []
        tot_s = sum(s["eval_seconds_this_session"] for s in stats)
        tot_n = sum(s["frames_this_session"] for s in stats)
        results[m["slug"]] = {
            "model": m, "summary": summary,
            "scored": len(ok), "failed": sum(1 for fid in frames if fid in run and not run[fid]["ok"]),
            "missing": sum(1 for fid in frames if fid not in run),
            "seconds_per_photo": tot_s / tot_n if tot_n else None,
            "load_seconds": stats[-1]["load_seconds"] if stats else None,
            "peak_metal_gb": max((s["peak_metal_gb"] for s in stats), default=None),
            "peak_rss_gb": max((s["peak_rss_gb"] for s in stats), default=None),
            "batch_size": stats[-1]["batch_size"] if stats else None,
            "disagreements": metrics.biggest_disagreements(fids, scores, labels, 10) if ok else [],
            "run": run,
        }
        rows_for_corr[m["slug"]] = dict(zip(fids, scores))
    rows_for_corr["production (stored)"] = prod

    # model-vs-model rank correlation on frames both scored
    slugs = list(rows_for_corr)
    corr = {}
    for a in slugs:
        for b in slugs:
            common = sorted(set(rows_for_corr[a]) & set(rows_for_corr[b]))
            corr[(a, b)] = metrics.spearman([rows_for_corr[a][i] for i in common],
                                            [rows_for_corr[b][i] for i in common]) if len(common) > 2 else None

    today = date.today().isoformat()
    lab = manifest["labels"]
    md = [f"# PCV model comparison — {today}", "",
          f"Shoot {manifest['shoot_id']} · ground truth = your blind cull in Lightroom collection "
          f"“{manifest['collection']}”: **{lab['pick']} picks**, {lab['unflagged']} unflagged, {lab['reject']} rejects "
          f"({len(frames)} frames). Same prompt (evaluation_v4) and scoring code for every model.", "",
          "## Summary", "",
          "| Model | Scored | P / R at prod thresholds | P@K (K = your picks) | ROC AUC | Spearman vs you | Keepers it would REJECT | Your rejects it REJECTs | s/photo | Peak GPU mem |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for slug, r in results.items():
        s = r["summary"]
        if not s:
            md.append(f"| {slug} | 0 | – | – | – | – | – | – | – | – |")
            continue
        t, k = s["at_production_thresholds"], s["at_top_k"] or {}
        md.append(f"| {slug} | {r['scored']}{f' (+{r['failed']} failed)' if r['failed'] else ''}"
                  f"{f' ({r['missing']} not run)' if r['missing'] else ''} | {_fmt(t['precision'], True)} / {_fmt(t['recall'], True)} "
                  f"| {_fmt(k.get('precision'), True)} | {_fmt(s['roc_auc'])} | {_fmt(s['spearman_vs_labels'])} "
                  f"| {s['keepers_model_rejects']} | {s['user_rejects_caught'][0]}/{s['user_rejects_caught'][1]} "
                  f"| {_fmt(r['seconds_per_photo'])} | {_fmt(r['peak_metal_gb'])} GB |")
    md += ["", "**How to read it:** *P/R at prod thresholds* uses the KEEP cutoff tuned for Qwen3-VL, so it is "
           "unfair to models that score on a different scale. *P@K* and *ROC AUC* don't depend on any threshold: they ask "
           "whether the model ranks your picks above the rest. They're the fairest quality comparison. For a "
           "pre-filter, *Keepers it would REJECT* must be near 0.", "",
           "## Rank correlation between models (Spearman)", "",
           "| | " + " | ".join(slugs) + " |", "|---" * (len(slugs) + 1) + "|"]
    for a in slugs:
        md.append(f"| {a} | " + " | ".join(_fmt(corr[(a, b)]) for b in slugs) + " |")
    md += ["", "## Run details", ""]
    for slug, r in results.items():
        md.append(f"- **{slug}** — `{r['model']['repo']}` thinking={r['model']['thinking']} batch={r['batch_size']} "
                  f"load {_fmt(r['load_seconds'])}s, peak RSS {_fmt(r['peak_rss_gb'])} GB")
    md += ["", "The 10 biggest disagreements per model, with thumbnails, are in `report.html`."]
    (eval_dir / "report.md").write_text("\n".join(md) + "\n")

    # HTML: same summary + disagreement galleries with thumbnails and the model's reasons.
    label_name = {1: "Pick", 0: "unflagged", -1: "Reject"}
    parts = ["<!doctype html><meta charset=utf-8><title>PCV model comparison</title>",
             "<style>body{font:14px -apple-system,system-ui,sans-serif;margin:24px;max-width:1200px;color:#222;background:#fff}"
             "table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}"
             ".g{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px}"
             ".c{border:1px solid #ddd;padding:8px;border-radius:6px}.c img{width:100%;border-radius:4px}"
             ".k{font-weight:600}.r{font-size:12px;color:#555}"
             "@media (prefers-color-scheme:dark){body{background:#111;color:#ddd}.c,td,th{border-color:#444}.r{color:#aaa}}</style>"]
    try:  # markdown-it is optional; fall back to <pre> if it's missing
        import markdown_it

        parts.append(markdown_it.MarkdownIt().enable("table").render("\n".join(md[:-1])))
    except Exception:
        parts.append("<pre>" + html.escape("\n".join(md)) + "</pre>")
    for slug, r in results.items():
        if not r["disagreements"]:
            continue
        parts.append(f"<h2>{html.escape(slug)}: 10 biggest disagreements</h2><div class=g>")
        for d in r["disagreements"]:
            f = frames[d["file_id"]]
            rec = r["run"][d["file_id"]]
            reasons = "".join(f"<div><b>{html.escape(c)}</b> {rec['category_scores'].get(c, '')}: {html.escape(t)}</div>"
                              for c, t in (rec.get("category_reasons") or {}).items())
            parts.append(f"<div class=c><img src='{_thumb(f['preview_path'])}'>"
                         f"<div class=k>{html.escape(f['filename'])}: you {label_name[d['label']]}, model "
                         f"{d['score']:.1f} ({rec['recommendation']}, top {100 - d['percentile'] * 100:.0f}%)</div>"
                         f"<div>{html.escape(d['kind'])}</div><details><summary>model's reasons</summary>"
                         f"<div class=r>{reasons}</div></details></div>")
        parts.append("</div>")
    (eval_dir / "report.html").write_text("\n".join(parts))
    print(eval_dir / "report.md")
    print(eval_dir / "report.html")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--eval-dir", default=str(EVAL_ROOT / date.today().isoformat()))
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--shoot-id", type=int, required=True)
    p.add_argument("--collection", required=True)
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG))
    p.add_argument("--force", action="store_true")
    r = sub.add_parser("run")
    r.add_argument("--models", help="comma-separated slugs from eval/models.json (default: entries with default=true)")
    r.add_argument("--batch-size", type=int, help="override every model's batch size")
    r.add_argument("--limit", type=int, default=0, help="only the first N frames (smoke test)")
    sub.add_parser("report")
    args = ap.parse_args()
    {"prepare": cmd_prepare, "run": cmd_run, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()
