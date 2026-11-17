# Vision-model evaluation

This folder compares candidate vision models against the photographer's own **blind** cull of one finished shoot. Every model gets the same production prompt (`prompts/evaluation_v4.txt`), the same parser and the same `scoring.score_in_code`.

## Ground truth

The ground truth is the Lightroom collection **PCV Eval - Blind Cull**. It holds the 320 originals of a finished client shoot from `Photo dump/2026-10-17`, added with no ratings or labels by the `PCVBlindCull.lrplugin` plugin (Library → Plug-in Extras). Flag each frame:

- **P (Pick):** a frame you'd deliver.
- **X (Reject):** optional. Use it for frames that are clearly technically bad (blinks, missed focus, misfires).
- **Unflagged:** everything else, counted as not a keeper.

## Running it

Use `.venv-eval` (mlx-vlm 0.7.12). The production `.venv` is left untouched.

```sh
# quit Lightroom first so the flags are flushed to disk
.venv-eval/bin/python eval/compare_models.py prepare --shoot-id 149 --collection "PCV Eval - Blind Cull"
.venv-eval/bin/python eval/compare_models.py run                       # default models from models.json
.venv-eval/bin/python eval/compare_models.py run --models qwen36-35b-think   # thinking mode: opt in
.venv-eval/bin/python eval/compare_models.py report
```

## Output

Everything is written to `/Volumes/AI-/PhotoCritic/eval/<date>/`:

- `manifest.json`
- `lrcat-copy/`
- `runs/*.jsonl`
- `report.md`
- `report.html` (includes thumbnails of the biggest disagreements)

## Safety

- The production database is opened with `query_only` and never written.
- Only a copy of the Lightroom catalog is read.
- Photos and previews are only ever read.
- Runs set `HF_HUB_OFFLINE=1`, so nothing is downloaded mid-run.

## Choosing a model in production

To use a different model in production, set:

- `PHOTOCRITIC_VLM_MODEL=<repo>`
- `PHOTOCRITIC_VLM_THINKING=on|off`
- `PHOTOCRITIC_EVAL_BATCH_SIZE=N`

Results are keyed per model version, so switching models never overwrites another model's scores. A model that needs mlx-vlm 0.7.x (LFM3, possibly Gemma 4) would also need the production `.venv` upgraded. That is a separate decision.
