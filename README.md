# PhotoCriticViewer

PhotoCriticViewer is a local-first AI photo-culling and critique system that I built for my own medium-format work (Hasselblad X1D II). A local vision-language model (Qwen3-VL on Apple MLX) runs on my Mac Studio and scores every RAW frame. A native SwiftUI app shows the results, and a token-protected local API lets other AI agents query and drive it. No photos leave the machine, and original files are never modified.

## The evaluation problem, and how I fixed it

The first version "worked," but it was useless for ranking. Across 2,000 real results, scores only ranged from 77 to 92 (mean 80.3, SD 3.1). Sixty percent of frames got exactly 78, all of them were marked KEEP, and 97% were graded B. The model was hedging.

I diagnosed the problem and wrote the fix as a spec ([`requests/scoring-v4-request.md`](requests/scoring-v4-request.md)), which was then implemented with Claude Code:

- **Lower temperature and anchored rubrics.** The new prompt ([`prompts/evaluation_v4.txt`](prompts/evaluation_v4.txt)) gives concrete descriptions of what earns a 2, 4, 6, 8, or 10 in each category, tells the model the expected distribution, and requires a written reason *before* each score. You can compare it with v1–v3 in the same folder.
- **Grades computed in code, not by the model.** The model scores categories only. The overall score, grade, and KEEP/MAYBE/REJECT come from configurable weights and thresholds (`photocritic/scoring.py`).
- **Per-shoot calibration.** Each photo gets a percentile within its shoot and within the whole library, plus a z-score, with raw and calibrated scores stored separately (`photocritic/calibration.py`).
- **Reproducibility.** Every result records its prompt version, model ID, temperature, and weights.
- **Safe re-scoring.** A 50-photo sample is re-scored first and its distribution shown. The full library is only re-scored after my approval, and data changes go through migrations, never wipes.

## Measuring against a human

[`eval/`](eval/) is a model-comparison harness. It scores candidate vision models against my own **blind** Lightroom cull of a finished 320-frame shoot, using precision and recall at production thresholds, precision@K, ROC AUC, and Spearman correlation with my picks. It opens the production database read-only and runs offline, so switching models never overwrites another model's scores.

## Built for agents

- A **local HTTP API** ([`API.md`](API.md)) with token auth and an OpenAPI spec, so AI assistants can search results, queue critiques, pull picks, and export crops. It binds to localhost, and optional iPhone access is restricted to Tailscale's private address range.
- An **MCP server** (`mcp_server.py`) for assistants that speak the Model Context Protocol.
- A **photographer coaching report** that aggregates critiques into my strongest and weakest skills, recurring issues, and what to practice next.

**Stack:** Python · MLX / mlx-vlm · Qwen3-VL · LibRaw (rawpy) · SQLite · SwiftUI · Apple Vision (subject-aware crops) · XMP export to Lightroom and Capture One · MCP

*Built by Tyrone Gibson, an IT manager moving into applied AI. I set the requirements, data-safety rules, and acceptance criteria, then reviewed and tested the AI-assisted implementation.*

---

## Technical reference: PhotoCritic Local

A local-first photography evaluation and culling tool for professional RAW shoots
(built and tested against Hasselblad `.3FR` files from an X1D II 50C). Decodes RAW
files, runs a fast technical cull, evaluates every frame with a local vision-language
model, groups and ranks near-duplicate bursts, and shows the results in a native
macOS app. Nothing ever leaves the machine, and original RAW files are never modified.

## Requirements

- macOS on Apple Silicon (built/tuned on an M3 Ultra Mac Studio, 96GB unified memory)
- Python 3.13 (via Homebrew)
- [`uv`](https://github.com/astral-sh/uv) for the virtual environment
- `exiftool` (`brew install exiftool`)
- A fast local/external SSD for the workspace (models + previews + database) —
  RAW decode and VLM inference are both demanding; a slow USB/spinning drive as
  the workspace will bottleneck everything. The *source* shoot folder can live
  anywhere (including a slow drive or iCloud Drive) since it's only read from.

## Setup

```bash
cd ~/Developer/PhotoCritic
uv venv --python 3.13 .venv
source .venv/bin/activate
uv pip install rawpy pillow numpy mlx mlx-vlm huggingface_hub \
    imagehash exifread tqdm
```

Point the Hugging Face cache at your fast workspace drive before downloading the
model (edit `photocritic/config.py`'s `WORKSPACE_ROOT` first if it's not
`/Volumes/AI-/PhotoCritic`):

```bash
export HF_HOME="$(python3 -c 'from photocritic import config; print(config.HF_HOME)')"
python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/Qwen3-VL-30B-A3B-Instruct-8bit')
"
```

The 8-bit quantization (~33.5GB) was chosen over 4/6-bit for this use case — see
`prompts/evaluation_v1.txt` and the project history for why quality mattered more
than the extra few seconds/image here. Swap `config.VLM_MODEL_ID` for a smaller
quantization if you're on a memory-constrained Mac.

## Processing a shoot

```bash
source .venv/bin/activate
export HF_HOME="$(python3 -c 'from photocritic import config; print(config.HF_HOME)')"
python3 run_batch.py "/path/to/shoot folder"
```

This is fully resumable — interrupting and re-running the same folder picks up
from the last completed file/stage rather than starting over. Stages, in order:

1. **Ingest + technical cull** — decode each `.3FR` (LibRaw via `rawpy`), generate
   an analysis-resolution preview, extract EXIF, and run a fast CV pass (sharpness,
   exposure clipping). Parallelized across `config.INGEST_WORKERS` threads.
2. **Similarity grouping** — perceptual-hash clustering to find near-duplicate
   bursts (`config.SIMILARITY_HASH_THRESHOLD`).
3. **Evaluation** — every frame scored by Qwen3-VL against `prompts/evaluation_v1.txt`
   (composition, focus, lighting, etc., plus an overall 0-100 score and KEEP/MAYBE/
   REJECT recommendation), batched via `mlx_vlm.batch_generate`.
4. **Ranking** — each similarity group's frames compared head-to-head via
   `prompts/ranking_v1.txt` to pick the strongest/weakest, rather than trusting
   independent scores to differentiate near-duplicates.

## Viewing results

Open `PhotoCriticViewer/PhotoCriticViewer.xcodeproj` in Xcode and run (⌘R), or:

```bash
cd PhotoCriticViewer
xcodegen generate   # only needed after editing project.yml
xcodebuild -project PhotoCriticViewer.xcodeproj -scheme PhotoCriticViewer -destination "platform=macOS" build
open "$(xcodebuild -project PhotoCriticViewer.xcodeproj -scheme PhotoCriticViewer -showBuildSettings 2>/dev/null | awk -F' = ' '/CODESIGNING_FOLDER_PATH/{print $2}')"
```

Native SwiftUI app: shoot sidebar → ranked grid → photo detail (scores, reasoning,
EXIF) → group comparison (side-by-side burst ranking). Reads `photocritic.db` and
the preview JPEGs directly and read-only — no server, no network, doesn't touch
the database the Python pipeline is the only writer of. If the workspace drive
isn't mounted at `/Volumes/AI-/PhotoCritic`, update the default in
`PhotoCriticViewer/PhotoCriticViewer/Data/WorkspaceConfig.swift`.

## Exporting to Lightroom / Capture One / Bridge

```bash
python3 export_xmp.py "/path/to/shoot folder"           # dry run — reports counts only
python3 export_xmp.py "/path/to/shoot folder" --apply    # actually writes
```

Writes a `.xmp` sidecar next to each RAW file with `xmp:Rating` (classification
A-F → 5-1 stars) and `xmp:Label` (KEEP/MAYBE/REJECT → Green/Yellow/Red) — the
fields all major RAW/DAM tools read. **Sidecars are only ever created, never
modified** — a file that already has a `.xmp` (from Capture One, Lightroom, etc.)
is skipped and reported, since a naive merge could corrupt real edits already
stored there. The original RAW file is never touched either way.

## Connecting Claude (MCP)

`mcp_server.py` exposes the same read/curation functions `curate.py` uses —
listing shoots, photo/group detail, deleting, renaming, look/person tagging —
as MCP tools, so an MCP-capable assistant can browse and curate shoots directly.

Register with Claude Code (run once, from this directory):

```bash
claude mcp add photocritic -- "$(pwd)/.venv/bin/python3" "$(pwd)/mcp_server.py"
```

Register with Claude Desktop by adding to `claude_desktop_config.json`'s `mcpServers`:

```json
"photocritic": {
    "command": "/absolute/path/to/PhotoCritic/.venv/bin/python3",
    "args": ["/absolute/path/to/PhotoCritic/mcp_server.py"]
}
```

Grok doesn't have broad public MCP client support as of this writing — if that
changes and it can run a local stdio MCP server the way Claude Desktop/Code do,
the same command above should work unmodified, since MCP itself is a standard,
model-agnostic protocol (not something Anthropic-specific to work around).

## Architecture

```
photocritic/
  config.py         workspace paths, thresholds, tuned constants (with rationale)
  raw_decoder.py     RawDecoder abstraction — LibRawDecoder is the only impl so far
  vision_model.py    VisionModel abstraction — Qwen3VL is the only impl so far
  technical_cull.py  stage-1 CV pass (sharpness, exposure clipping)
  similarity.py      perceptual-hash + union-find clustering
  metadata.py        EXIF via exiftool
  db.py              SQLite schema, resumability (presence-check), read queries
  pipeline.py        orchestrates the four stages above
  xmp_export.py       XMP sidecar generation

run_batch.py          CLI: process a shoot folder
export_xmp.py          CLI: write XMP sidecars
prompts/                versioned, editable prompt templates (not embedded in code)

PhotoCriticViewer/      native SwiftUI macOS app (the viewing layer)
  project.yml            xcodegen project definition
  PhotoCriticViewer/
    Data/                SQLiteConnection (raw C sqlite3 API) + PhotoCriticDatabase
                          (read-only queries mirroring photocritic/db.py)
    Models/               Evaluation (Codable, decodes the same JSON Python wrote)
                          + the other view-facing model structs
    Views/                ContentView (nav shell), DashboardView, PhotoDetailView,
                          GroupComparisonView
```

Workspace (models, previews, database, logs) lives at `config.WORKSPACE_ROOT`
(Python) / `WorkspaceConfig.root` (Swift) — keep these in sync if you change it.
Separate from the original shoot folder, per the never-touch-the-originals rule.
The Swift app is a read-only client of the same SQLite database and preview
JPEGs the Python pipeline writes; it never writes to the database itself.

## Troubleshooting

- **`AttributeError: module 'cv2' has no attribute 'CascadeClassifier'`** — the
  installed `opencv-python` (5.0.0) ships no Haar cascade bindings or XML files.
  Face/eye detection was dropped from the technical cull for this reason; the
  VLM's stage-2 evaluation covers expression/eyes instead.
- **`RuntimeError: [METAL] Command buffer execution failed: Insufficient Memory`**
  during evaluation — the batch size in `config.EVAL_BATCH_SIZE` is too high for
  available GPU memory. 20 images/batch worked at 71.5GB peak on a 96GB M3 Ultra;
  24 failed. Lower `EVAL_BATCH_SIZE` if you hit this on a smaller Mac.
- **Ingest+cull is much slower than expected** — check what drive the *source*
  shoot folder is on (`diskutil info <volume>` → Protocol/Solid State). A USB/
  HFS+ spinning-adjacent drive can be 15-20x slower per file than an NVMe SSD;
  this is I/O, not something the pipeline can optimize around.
- **Scores cluster tightly / look repetitive** — check `EVALUATION_PROMPT_VERSION`
  and the temperature used in `vision_model.py`'s `evaluate_single`/`evaluate_batch`.
  Low temperature was the actual cause the one time this came up, not the prompt
  wording — see the project history for a controlled A/B test on this.
- **PhotoCriticViewer shows no shoots / a database error** — the app is looking
  for `photocritic.db` at `WorkspaceConfig.root` (default `/Volumes/AI-/PhotoCritic`);
  confirm that drive is mounted and update the path in `WorkspaceConfig.swift` if
  it's changed. It opens the database `SQLITE_OPEN_READONLY`, so it won't create
  one if missing.
- **Naming a Swift model type after a SwiftUI framework type** — the grid-item
  model here is `PhotoGridItem`, not `GridItem`, because `GridItem` collides with
  SwiftUI's own type used for `LazyVGrid`/`LazyHGrid` column specs. Same applies
  to `Scene`, `View`, `App`, `Color`, etc. — check before naming a new model type.

## Notes

- Camera model in the EXIF may not match what you expect if the brief/plan
  assumed a different body — the pipeline is camera-agnostic as long as LibRaw
  supports the `.3FR` variant.
- No data is ever uploaded anywhere; the only network access is the one-time
  model download from Hugging Face.
