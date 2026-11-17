"""Worker: score every frame in an eval manifest with ONE model, appending results to a JSONL.

Launched by compare_models.py in its own process (so each model's peak memory is measured in
isolation and its weights are fully released afterwards). The model is chosen exactly the way
production chooses it -- PHOTOCRITIC_VLM_MODEL / PHOTOCRITIC_VLM_THINKING env vars, set by the
orchestrator -- and scored with the production prompt, parser and score_in_code.

Never opens the production database. Resumable: frames already in the output JSONL are skipped,
and every chunk is flushed as soon as it finishes, so a crash (e.g. a Metal OOM) loses at most
one chunk.
"""

import argparse
import json
import resource
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from photocritic import config, scoring  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out", required=True, help="JSONL of per-frame results (appended)")
    ap.add_argument("--stats", required=True, help="JSON run stats (overwritten)")
    ap.add_argument("--batch-size", type=int, required=True)
    ap.add_argument("--limit", type=int, default=0, help="only the first N frames (smoke test)")
    args = ap.parse_args()

    import mlx.core as mx

    from photocritic.vision_model import MLXVisionModel

    manifest = json.loads(Path(args.manifest).read_text())
    frames = manifest["frames"]
    if args.limit:
        frames = frames[: args.limit]
    out_path = Path(args.out)
    done = set()
    if out_path.exists():
        for line in out_path.read_text().splitlines():
            if line.strip():
                done.add(json.loads(line)["file_id"])
    pending = [f for f in frames if f["file_id"] not in done]
    print(f"{config.VLM_MODEL_VERSION}: {len(done)} already done, {len(pending)} to score", flush=True)
    if not pending:
        return 0

    prompt_text = config.EVALUATION_PROMPT_PATH.read_text()
    mx.reset_peak_memory()
    t0 = time.perf_counter()
    model = MLXVisionModel()
    load_s = time.perf_counter() - t0

    eval_s = 0.0
    scored_n = 0
    batch_broken = False
    with out_path.open("a") as out:
        for start in range(0, len(pending), args.batch_size):
            chunk = pending[start : start + args.batch_size]
            t = time.perf_counter()
            path = "batch"
            if not batch_broken:
                try:
                    results = model.evaluate_batch([f["preview_path"] for f in chunk], prompt_text)
                except Exception as e:  # e.g. an mlx_vlm batch path that doesn't support this model
                    print(f"batch_generate failed ({type(e).__name__}: {str(e)[:200]}); "
                          "falling back to one image per call for the rest of this run", flush=True)
                    batch_broken = True
            if batch_broken:
                path = "single"
                results = [model.evaluate_single(f["preview_path"], prompt_text) for f in chunk]
            dt = time.perf_counter() - t
            eval_s += dt
            for f, r in zip(chunk, results):
                rec = {"file_id": f["file_id"], "filename": f["filename"], "ok": bool(r and r["ok"]),
                       "chunk_seconds": dt, "chunk_size": len(chunk), "path": path}
                if rec["ok"] and not scoring.extract_category_scores(r["parsed"]):
                    # Parsed as JSON but has no category scores (e.g. a thinking model ran out of
                    # tokens mid-reasoning and the fallback grabbed a fragment). Count it as failed.
                    rec.update(ok=False)
                    r = {"error": "parsed JSON has no category scores", "raw": r.get("raw", "")}
                if rec["ok"]:
                    s = scoring.score_in_code(r["parsed"])
                    rec.update(overall_score=s["overall_score"], recommendation=s["recommendation"],
                               classification=s["classification"],
                               category_scores=scoring.extract_category_scores(r["parsed"]),
                               category_reasons=scoring.extract_category_reasons(r["parsed"]))
                else:
                    rec.update(error=(r or {}).get("error", "no result"), raw_head=(r or {}).get("raw", "")[:1500],
                               raw_tail=(r or {}).get("raw", "")[-1500:], raw_len=len((r or {}).get("raw", "")))
                out.write(json.dumps(rec) + "\n")
            out.flush()
            scored_n += len(chunk)
            print(f"PROGRESS {len(done) + scored_n}/{len(frames)}  {dt / len(chunk):.2f}s/photo", flush=True)

    # ru_maxrss is bytes on macOS. Metal peak is what actually bounds batch size.
    stats = {
        "model_version": model.version_tag,
        "load_seconds": load_s,
        "eval_seconds_this_session": eval_s,
        "frames_this_session": scored_n,
        "seconds_per_photo": eval_s / scored_n if scored_n else None,
        "peak_metal_gb": mx.get_peak_memory() / 1e9,
        "peak_rss_gb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9,
        "batch_size": args.batch_size,
        "generation_path": "single (batch_generate unsupported)" if batch_broken else "batch",
        "mlx_vlm_version": __import__("mlx_vlm").__version__,
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    stats_path = Path(args.stats)
    history = json.loads(stats_path.read_text()) if stats_path.exists() else []
    history.append(stats)
    stats_path.write_text(json.dumps(history, indent=2))
    print(json.dumps(stats), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
