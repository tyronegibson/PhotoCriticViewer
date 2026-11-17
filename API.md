# PhotoCriticViewer Local Control API

A local HTTP API that lets an assistant drive PhotoCriticViewer: list/ingest photos, trigger
the real AI evaluation pipeline, read calibrated results, get a coaching report, manage a
posting workflow, and export deliverables. It is **not** a second place where logic lives —
every endpoint calls into the same code the app's own UI uses (`organize.py` / `evaluate.py`
via `IngestRunner`, `curate.py` / `export_photo.py` via `CurationRunner`, and the same
read-only `PhotoCriticDatabase` the dashboard reads from), plus a Swift-only finishing pass for
export (`LocalAPIExportProcessor`) that needs Apple's Vision framework.

- Binds to **127.0.0.1**, port **8765** by default. Optionally *also* binds this Mac's
  **Tailscale address** for the iPhone remote (off by default — see "Remote access" below).
  Never binds 0.0.0.0, a LAN address, or anything outside Tailscale's 100.64.0.0/10.
- Every request except `GET /health` and the static web UI page (`GET /`, `GET /remote`)
  requires `Authorization: Bearer <token>`.
- Starts when the app launches, stops when it quits. Toggle it off in **Settings → Local Control
  API**.

## Auth

The token is generated once, the first time the app launches, and saved to:

```
~/.photocritic/api_token      (permissions 600 -- only you can read it)
```

```bash
TOKEN=$(cat ~/.photocritic/api_token)
```

Every example below assumes `$TOKEN` is set that way.

## Paths: what /open and /export can touch

`/open` and `/export` check paths against an **allowlist** (Settings → Local Control API →
Allowed Paths). Default is **the active PhotoCritic workspace plus
`/Volumes/ProfessionallyUnorganized`** (your originals volume) — not your whole home folder,
which this app never needs to touch. Add another archive volume in Settings if you keep
originals somewhere else too. A path outside every allowed root is rejected with
`400 invalid_path`, naming the roots it checked.

## Errors

```json
{ "error": { "code": "invalid_path", "message": "..." } }
```

| Status | When |
|---|---|
| 400 | Bad/missing body field, invalid path, invalid preset/params |
| 401 | Missing or wrong bearer token |
| 404 | Unknown endpoint, unknown job id, unknown file id, or a `/critique` path that isn't an already-organized shoot |
| 409 | `/open`, `/export`, or `/posted` only — another job of that kind is already running. **`/critique` never 409s** — see below |
| 500 | The underlying script failed; the message includes a log tail |

## Calibrated scoring — what the numbers mean

As of `evaluation_v4`, the model only returns **per-category scores (0-10) and a one-line
reason for each**, written before the score. It no longer picks an overall score, grade, or
recommendation — those are computed in **code** (`photocritic/scoring.py`) from the category
scores, using weights and thresholds in `photocritic/config.py` (`CATEGORY_WEIGHTS`,
`OVERALL_SCORE_CENTER`/`OVERALL_SCORE_CONTRAST`, `GRADE_THRESHOLDS`,
`RECOMMENDATION_THRESHOLDS` — edit those directly to retune).

A weighted *average* across 13 categories compresses spread on its own (averaging many
independently-varying numbers regresses toward the mean) even when each category discriminates
well individually — confirmed on a real 50-photo sample: zero duplicate scores and roughly
2-3x the old per-category SD, but the aggregate's range came in under target. `weighted_overall`
corrects for this with a contrast stretch around `OVERALL_SCORE_CENTER` (5.0/10, the rubric's
own "competent but unremarkable" anchor) by `OVERALL_SCORE_CONTRAST` (1.5, chosen by testing
several values against that same sample's real category-score vectors — the smallest value
that cleared both an SD≥8 and range≥50 target with nothing clamping at 0 or 100). Re-running
that same 48-photo sample through the new formula (no model call, just recomputing from
already-stored category scores — see `rescore.py --recompute-scores-only`):

```
sd=9.3→13.9  range=36.7→55.0  grades A/B/C/D, recommendations KEEP/MAYBE/REJECT all represented
```

Every evaluated photo carries two scores:

- **`score`** (raw `overall_score`, 0-100) — the weighted-category score against the fixed
  rubric. Comparable across the whole library in principle.
- **`calibrated_score`** (0-100) — your photo's **percentile rank within the whole library**.
  Spreads out by construction (it's a percentile), so it stays useful for ranking/filtering
  even if raw scores are naturally clustered because your work really is consistently similar
  quality. `percentile_shoot` and `percentile_library` are the raw ingredients; `scores` in the
  response is always `score` (raw), never pre-calibrated.

Every evaluation also stores its generation `temperature`, the `weights` snapshot used, and how
many self-consistency samples (`sample_count`) contributed — queryable directly from
`ai_evaluations` if you need full provenance, though the API doesn't surface those three yet.

**Re-scoring** (`rescore.py`) never deletes or overwrites old evaluations — a re-score under a
new `EVALUATION_PROMPT_VERSION` just adds a new row, which naturally becomes "the latest" one
everything reads.

```bash
# See the current spread on a sample before committing to anything:
python3 rescore.py --sample 50

# Re-score the ENTIRE library -- backs up the database first, asks you to type "yes":
python3 rescore.py --all
```

## Remote access (iPhone over Tailscale) — V1.5 Phase 1

**Settings → Remote Access** → "Also listen on this Mac's Tailscale address". This adds a
second listener on the Tailscale IP (default `100.100.10.20`; **Detect** reads it from
`tailscale ip -4`). It uses the same port, the same token and the same routes. 127.0.0.1 keeps
working either way.

- **Rollback:** turn the toggle off. That closes the second listener and nothing else. With
  the toggle off the app behaves exactly as before V1.5, apart from the new read-only routes
  below, which are also available on 127.0.0.1.
- **Address check:** only a 100.64.0.0/10 address is accepted. If Tailscale isn't connected
  yet (after login or wake), the listener retries every 30s while the toggle stays on. Settings
  shows the live status.
- **Phone setup:** open `http://100.100.10.20:8765/` on the iPhone, or press **Show iPhone setup
  QR** and scan it. The QR carries the token in the URL `#fragment`, which browsers never
  send to a server. The page stores it in the phone's localStorage and removes it from the
  address bar. The QR contains the token, so don't screenshot or share it.
- **What reaches the phone:** previews (already-rendered JPEGs, optionally downsized) and
  exported image files only. `/downloads` refuses anything outside `<workspace>/exports`, and
  any non-image extension (RAW included), even inside it.
- **Testing from the Mac itself doesn't work:** on this Mac, Tailscale intercepts connections
  to the Mac's own Tailscale IP, so they never reach a listener bound to that address. Test
  from another device on the tailnet. `curl` from the Mac against that IP will time out.

### The web UI — `GET /` (also `/remote`), no auth

A single page served by the app: browse shoots, filter and sort a shoot's grid, open a photo's
critique, start a critique (whole shoot or selected photos), watch jobs, and export selected
photos (up to 20) with any preset, then save them to the phone. It uses only the public
endpoints below, so a future SwiftUI iPhone app can do everything it does.

### `GET /shoots`

```json
[{"id": 12, "name": "2026-06-19", "parent": "Photo dump", "folder_path": "/Volumes/…",
  "total_files": 240, "evaluated": 240, "keep": 31, "maybe": 80, "reject": 129}]
```

### `GET /shoots/{id}/photos?sort=score|filename&recommendation=KEEP|MAYBE|REJECT`

One row per file: `id, filename, has_preview, score?, classification?, recommendation?,
group_id?, group_rank?, group_role?, look?, person?`.

### `GET /previews/{id}?w=N`

`image/jpeg`. Without `w` you get the workspace preview as-is. With `w`, the size is rounded
up to 256/512/1024/2048 and cached under `<workspace>/cache/remote_thumbs/`; the cache
rebuilds itself when the preview is newer. Returns 404 `no_preview` if there's no preview.

### `GET /jobs?limit=50`

Most recent first (max 200). Each job has `id, status (queued|running|done|failed), params
("shoot:12" / "files:3"), created_at, stage?, current?, total?, error?, result?`. Finished jobs
are pruned after 24h. `GET /jobs/{id}` is unchanged.

### `GET /downloads?path=/abs/path`

Streams one exported image as an attachment. The file must resolve, symlinks included, to a
location under `<workspace>/exports`, have an image extension (jpg, jpeg, png, tif, tiff, webp,
heic) and be at most 200MB. Otherwise you get 403 `forbidden_path`.

### `GET /remote/config`

`{"app_version", "remote_exports_dir", "export_presets", "preview_sizes"}`. The web UI exports
to `<remote_exports_dir>/<YYYY-MM-DD>` and downloads from there.

## Endpoints

### `GET /health` — no auth required

```bash
curl http://127.0.0.1:8765/health
```
```json
{"ok": true, "app": "PhotoCriticViewer", "version": "2.0"}
```

### `POST /open` — ensure a folder is organized, return its photos

Runs `organize.py` and **waits for it to finish** (give this a generous timeout for a large new
folder). Already-organized folders just get re-confirmed and return quickly.

```bash
curl -X POST http://127.0.0.1:8765/open \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"path": "/Volumes/ProfessionallyUnorganized/Medium Format/Photo dump/2026-06-19"}'
```
```json
{"shoot_ids": [42], "photos": [{"id": 13606, "filename": "B0006632.3FR", "path": "/Volumes/.../B0006632.3FR", "shoot_id": 42}]}
```

### `POST /critique` — run the real AI evaluation pipeline

Triggers `evaluate.py` (Qwen3-VL — slow, GPU-heavy). **Never returns 409** — the job is always
accepted and queued, run in arrival order once whatever else needs `IngestRunner` (another
critique job, an `/open`, or the UI's own buttons) is free. Jobs persist in SQLite
(`<workspace>/database/local_api_jobs.sqlite`) and survive a relaunch as history — a job still
`queued`/`running` when the app restarts is marked `failed` with `"interrupted by an app
restart"` rather than silently resumed, since the subprocess behind it is gone either way.
Finished jobs older than 24h are pruned automatically.

**By id — evaluates ONLY those files, not their whole shoot:**
```bash
curl -X POST http://127.0.0.1:8765/critique \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"ids": [13606, 13607]}'
```

**By path — evaluates the WHOLE shoot (must already be organized; call `/open` first if not):**
```bash
curl -X POST http://127.0.0.1:8765/critique \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"path": "/Volumes/ProfessionallyUnorganized/Medium Format/Photo dump/2026-06-19"}'
```
```json
{"job_id": "3F2A1C4E-...-..."}
```

### `GET /jobs/{id}` — poll a /critique job

```bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/jobs/3F2A1C4E-...-...
```
```json
{"id": "3F2A1C4E-...", "status": "running", "stage": "evaluate", "current": 12, "total": 48}
```
`status`: `queued` → `running` → `done`/`failed`. `done` includes
`"result": {"mode": "files"|"shoot", ...}`. `failed` includes `"error"` with a log tail.

### `GET /results` — list evaluated photos across all shoots

| Query param | Meaning | Default |
|---|---|---|
| `min_score` | raw `score` floor | none |
| `sort` | `score_desc` \| `score_asc` \| `filename` | `score_desc` |
| `limit` | max rows (capped at 2000) | 200 |

```bash
curl -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8765/results?min_score=85&limit=20"
```
```json
[{
  "id": 13606, "shoot_id": 42, "path": "/Volumes/.../B0006632.3FR", "filename": "B0006632.3FR",
  "shoot": "/Volumes/.../2026-06-19", "score": 92, "calibrated_score": 97.4,
  "percentile_shoot": 95.0, "percentile_library": 97.4,
  "scores": {"composition": 9, "...": "..."},
  "classification": "A", "recommendation": "KEEP",
  "critique": "...", "tags": ["A", "KEEP", "black sheer lingerie"],
  "reviewed_at": "2026-09-07T18:36:56.389276+00:00"
}]
```

### `GET /results/{id}` — full detail for one photo

```bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/results/13606
```
Adds `category_reasons` (the one-line reason behind each category score, v4+ only),
`style_summary` (`{"lighting", "mood", "setup", "wardrobe"}`, for caption-writing, v4+ only),
`strengths`/`weaknesses`/`technical_issues`/`artistic_choices`, `technical`, `metadata`,
`group`, and `posted_to` (if marked posted anywhere).

### `GET /report` — coaching report

Aggregates your own evaluation history into feedback on **your photography**, not individual
photos.

| Query param | Meaning |
|---|---|
| `shoot` | scope to one `shoot_id` |
| `since` | ISO date/datetime — only evaluations at or after this |

```bash
curl -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8765/report"
```
```json
{
  "photo_count": 2000,
  "strongest_categories": [{"category": "subject", "mean": 8.58}, {"category": "focus", "mean": 8.38}],
  "weakest_categories": [{"category": "background", "mean": 6.74}, {"category": "color_tonality", "mean": 7.17}, "..."],
  "trend_by_month": [{"month": "2026-06", "mean_score": 71.2, "count": 310}, "..."],
  "trend_by_shoot": [{"shoot": "/Volumes/.../2026-06-19", "mean_score": 74.5, "count": 48}, "..."],
  "recurring_issues": [{"issue": "flat lighting on camera-left side", "count": 14}, "..."],
  "best_photos": [{"id": 13606, "filename": "...", "score": 92, "calibrated_score": 97.4, "reason": "..."}],
  "weakest_photos": ["..."],
  "things_to_practice": [
    "Work on background separation — wider aperture, more subject-to-background distance, or a cleaner backdrop.",
    "Refine the color grade and skin-tone accuracy in post — a consistent LUT/preset may help.",
    "..."
  ]
}
```
`recurring_issues` comes from frequency-counting the model's own `weaknesses`/`technical_issues`
text (v4's prompt specifically asks for concrete, fixable phrasing — light direction/ratio,
background separation, crop, pose angles, hand placement, color grade — not generic praise).
`things_to_practice` is a fixed per-category tip for each of your current weakest categories.

### `GET /picks` — posting-workflow picks

| Query param | Meaning |
|---|---|
| `min_percentile` | `calibrated_score`/`percentile_library` floor |
| `grade` | exact classification match (`A`, `B`, …) |
| `not_posted` | `true` → exclude anything already posted to *any* platform |
| `limit` | capped at 2000 |

```bash
curl -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8765/picks?min_percentile=90&not_posted=true"
```
Returns the same shape as `/results`.

### `POST /posted` — mark a photo as posted

```bash
curl -X POST http://127.0.0.1:8765/posted \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"id": 13606, "platform": "instagram"}'
```
Platform is any string you like (`instagram`, `modelmayhem`, `inpose`, `portfolio`, ...).
Writes through `curate.py mark-posted` into a new `posted_to` table — Python remains the sole
writer to `photocritic.db`.

### `POST /export` — subject-aware export

Two stages: `export_photo.py` decodes the RAW to a full-resolution JPEG and handles EXIF (the
only part that needs Python/rawpy); `LocalAPIExportProcessor` (Swift) then does the **crop,
resize, color space, and watermark** — subject-aware cropping needs Apple's Vision framework
(face detection, falling back to person detection), which has no Python-side equivalent here.

| Body field | Meaning | Default |
|---|---|---|
| `ids` (required) | file ids | — |
| `dest` (required) | destination folder (created if missing; inside an allowed root) | — |
| `preset` | `instagram_4x5` \| `instagram_square` \| `instagram_story` \| `modelmayhem` \| `original` | `original` |
| `long_edge` | override the preset's resize target | preset default |
| `quality` | override the preset's JPEG quality, 1-100 | preset default |
| `crop_offset` | `{"x": 0-1, "y": 0-1}` — skip Vision entirely, center the crop here | none (Vision decides) |
| `watermark` | text drawn bottom-right, semi-transparent | none |

Vision tries face detection first (expanded into an approximate head+shoulders region so hair
and chin aren't clipped), falls back to person/body detection, then falls back to a plain
center crop if neither finds anything. The crop is always nudged so the detected subject is
never cut off — that's the specific thing a naive center crop gets wrong.

> **`modelmayhem` preset note:** Model Mayhem's long-cited upload guidance is roughly 1000px on
> the long edge, well under their size cap — that's what this preset uses, but it isn't pulled
> from a current official spec. Check MM's own upload page if you need an exact match.

```bash
curl -X POST http://127.0.0.1:8765/export \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"ids": [13606], "dest": "/Volumes/.../export", "preset": "instagram_4x5", "watermark": "@yourhandle"}'
```
```json
{"results": [{"file_id": 13606, "path": "/Volumes/.../export/B0006632_instagram_4x5.jpg"}], "exported": 1, "failed": 0}
```

### `GET /openapi.json`

The full OpenAPI 3.0 spec (requires auth, like everything but `/health`).

## What changed to build this

| Area | Files |
|---|---|
| Calibrated scoring | `prompts/evaluation_v4.txt` (anchored rubrics, reason-before-score, no model-picked grade), `photocritic/scoring.py` (weighted-overall + contrast stretch, grade/recommendation, self-consistency median), `photocritic/calibration.py` (percentile/z-score), `photocritic/config.py` (weights/center/contrast/thresholds/temperature), `photocritic/vision_model.py` (low temp, batched self-consistency), `photocritic/db.py` (new `ai_evaluations` columns, additive migration), `photocritic/pipeline.py:recompute_overall_scores` (re-derive scores after tuning weights, no model call), `rescore.py` (`--sample`/`--all`/`--recompute-scores-only` + histogram) |
| Per-file critique + queue | `evaluate.py --files`, `photocritic/pipeline.py:evaluate_specific_files`, `LocalAPIJobStore.swift` (SQLite-backed), `LocalAPICritiqueQueue.swift` (serial dispatch) |
| Coaching report | `LocalAPIServer.swift:handleReport` |
| Posting workflow | `photocritic/db.py` (`posted_to` table), `curate.py mark-posted`/`unmark-posted`, `LocalAPIServer.swift:handlePicks`/`handleMarkPosted` |
| Subject-aware export | `export_photo.py` (decode-only intermediate), `LocalAPIExportProcessor.swift` (Vision crop, resize, sRGB, watermark) |
| Housekeeping | `LocalAPISettings.swift` (allowlist default), `Views/DashboardView.swift` split into `LookNameSheet.swift`/`PhotoCardView.swift`/`ExportSheet.swift`/`BestSelectionSheet.swift`/`PreviewImage.swift`, `PhotoCriticViewerTests` (new Xcode test target), `tests/test_scoring.py`/`test_calibration.py`/`test_evaluate_missing_preview.py` |

### A bug found and fixed along the way

Adding `tests/test_scoring.py` and `tests/test_calibration.py` exposed a real, latent
test-isolation bug: `photocritic/config.py`'s workspace paths were frozen at module-import time,
and `db.connect()`'s default parameter was frozen the same way. Whichever test file happened to
import `photocritic` first in a given `unittest discover` run decided the workspace for every
other test file, regardless of each file's own `PHOTOCRITIC_WORKSPACE` override — which, for one
run, pointed `tests/test_organize_twin.py` and `tests/test_travel_sync.py` at the **real**
production database. Caught immediately, the real database was cleaned up by hand (nothing
real was touched — every stray row traced to a throwaway temp-folder path), and the actual fix
went into `config.py`/`db.py` themselves: workspace paths are now resolved fresh on every
access (module `__getattr__`), not frozen once. See those two files' comments for the full story.
