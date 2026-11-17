"""Workspace paths and constants. Workspace lives on the fast external drive,
kept separate from original shoot folders per the integrity rules."""

import os
from pathlib import Path

# PHOTOCRITIC_WORKSPACE points a second machine (e.g. a travelling laptop), or a test, at its
# own workspace; the viewer app sets it for the scripts it launches. Unset = the Studio's drive.
#
# WORKSPACE_ROOT and everything derived from it below are computed FRESH on every access
# (via module __getattr__, PEP 562) rather than frozen once at import time. A plain
# `WORKSPACE_ROOT = Path(os.environ.get(...) or default)` assignment here looks the same at
# every call site but is wrong in a way that bit this project for real: the FIRST import of
# this module in a process bakes in whatever PHOTOCRITIC_WORKSPACE was at that instant, and no
# later os.environ[...] = ... anywhere else can change it -- including a test file that sets
# the env var in its own module body, if some OTHER module (even one that doesn't look related,
# e.g. one only importing photocritic.scoring) happened to import this module first in the same
# process. That raced two test files against the real production database and really did write
# fake rows into it before this was caught. See db.connect() below for the matching fix to its
# default parameter, which had the exact same freeze-at-def-time problem.
_WORKSPACE_ENV_VAR = "PHOTOCRITIC_WORKSPACE"
_DEFAULT_WORKSPACE_ROOT = "/Volumes/AI-/PhotoCritic"


def _workspace_root() -> Path:
    return Path(os.environ.get(_WORKSPACE_ENV_VAR) or _DEFAULT_WORKSPACE_ROOT)


_DERIVED_PATHS = {
    "WORKSPACE_ROOT": lambda: _workspace_root(),
    "CACHE_DIR": lambda: _workspace_root() / "cache",
    "PREVIEWS_DIR": lambda: _workspace_root() / "previews",
    "DATABASE_DIR": lambda: _workspace_root() / "database",
    "MODELS_DIR": lambda: _workspace_root() / "models",
    "LOGS_DIR": lambda: _workspace_root() / "logs",
    "EXPORTS_DIR": lambda: _workspace_root() / "exports",
    "DATABASE_PATH": lambda: _workspace_root() / "database" / "photocritic.db",
    "HF_HOME": lambda: _workspace_root() / "models" / "hf-cache",
    "VLM_MODEL_ID": lambda: os.environ.get(_VLM_MODEL_ENV_VAR) or DEFAULT_VLM_MODEL_ID,
    "VLM_THINKING": lambda: _vlm_thinking(),
    # What evaluation/ranking rows are keyed by (model_version column): the model ID, plus
    # "+thinking" when thinking mode is on, so thinking and non-thinking runs of the same model
    # never overwrite or satisfy each other's "already evaluated" check.
    "LEGACY_BATCH_TEMPLATE": lambda: _on_off(_LEGACY_BATCH_TEMPLATE_ENV_VAR, default=True),
    "VLM_MODEL_VERSION": lambda: (os.environ.get(_VLM_MODEL_ENV_VAR) or DEFAULT_VLM_MODEL_ID)
    + ("+thinking" if _vlm_thinking() else "")
    + ("" if _on_off(_LEGACY_BATCH_TEMPLATE_ENV_VAR, default=True) else "+tmpl1"),
    "EVAL_BATCH_SIZE": lambda: _eval_batch_size(),
}


def _on_off(env_var: str, default: bool) -> bool:
    raw = (os.environ.get(env_var) or "").strip().lower()
    if raw == "":
        return default
    if raw in ("0", "false", "no", "off"):
        return False
    if raw in ("1", "true", "yes", "on"):
        return True
    raise ValueError(f"{env_var} must be on/off, got {raw!r}")


def _vlm_thinking() -> bool:
    return _on_off(_VLM_THINKING_ENV_VAR, default=False)


def _eval_batch_size() -> int:
    raw = os.environ.get(_EVAL_BATCH_SIZE_ENV_VAR)
    if not raw:
        return DEFAULT_EVAL_BATCH_SIZE
    value = int(raw)
    if value < 1:
        raise ValueError(f"{_EVAL_BATCH_SIZE_ENV_VAR} must be >= 1, got {raw!r}")
    return value


def __getattr__(name: str):
    if name in _DERIVED_PATHS:
        return _DERIVED_PATHS[name]()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")

PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"
EVALUATION_PROMPT_PATH = PROMPTS_DIR / "evaluation_v4.txt"
RANKING_PROMPT_PATH = PROMPTS_DIR / "ranking_v1.txt"

# v4 rewrite (2026-10): the model no longer picks overall_score/classification/recommendation
# at all -- see photocritic/scoring.py, which computes all three in code from the category
# scores the model DOES return, using CATEGORY_WEIGHTS/GRADE_THRESHOLDS/RECOMMENDATION_THRESHOLDS
# below. This was in direct response to real production data clustering hard (77-92 range, 60%
# exactly 78, category SD ~0.5-0.8) under v2's free-floating overall_score + high (0.8) sampling
# temperature. v4 also drops the per-category score temperature way down (EVALUATION_TEMPERATURE)
# and anchors every category 0/2/4/6/8/10 with concrete descriptions instead of a bare 0-10 ask.
EVALUATION_TEMPERATURE = 0.15

# Score each image EVALUATION_SELF_CONSISTENCY_N times (independent samples at
# EVALUATION_TEMPERATURE) and take the per-category MEDIAN across them, rather than trusting one
# sample -- trades N-1x extra evaluate calls for less sampling noise on borderline frames. 1 =
# off (one sample, as before). Implemented as N repeats of the same image within one
# evaluate_batch call (see vision_model.py), so this stays on the fast batched path rather than
# falling back to one-call-per-image.
EVALUATION_SELF_CONSISTENCY_N = 1

# r1's prompt (open-ended "one-line reason") measured at ~1107 tokens/response on average
# (category reasons alone averaged 26 words, not "one line") -- right up against the old 1400
# cap, and a direct driver of per-file eval time, since autoregressive generation time scales
# with output length. r2's enforced 10-word cap per reason should cut this substantially; 1000
# leaves real margin above the new expected length without the old cap's slack. Lower this
# further only after confirming actual responses aren't truncating against it (a truncated,
# unrepairable response fails that file, logged as "eval FAILED", not silently wrong).
EVALUATION_MAX_TOKENS = 1000

# Bump whenever evaluation_v4.txt's WORDING changes materially (the schema is stable; the
# instructions inside it aren't) -- e.g. r2 tightened "one-line reason" to an enforced 10-word
# cap after a real sample run showed the model writing 26 words/reason on average, right up
# against the 1400-token generation cap and a direct driver of per-file eval time.
EVALUATION_PROMPT_REVISION = "r2"

# Version tag for DB dedup/resumability — bumped independently of the prompt file whenever
# generation params change materially (temperature, self-consistency N, the prompt's wording/
# schema), since the tag needs to capture "would re-running this produce meaningfully different
# output," not just "did the prompt text change." Already-evaluated files are NOT retroactively
# re-run: has_evaluation checks this exact tag, so old files just keep their old evaluation
# until explicitly re-scored (see rescore.py) -- bumping this is what makes a file eligible for
# re-scoring, never an automatic wipe of what's already stored.
EVALUATION_PROMPT_VERSION = f"evaluation_v4-{EVALUATION_PROMPT_REVISION}-t{EVALUATION_TEMPERATURE}-n{EVALUATION_SELF_CONSISTENCY_N}"
RANKING_PROMPT_VERSION = "ranking_v1"

# Weighted average across these categories (see photocritic/scoring.py) is the RAW overall_score
# stored per evaluation. Weights don't need to sum to 1 -- scoring.py normalizes by whatever
# categories are actually present, so a legacy row missing a category (schema changed over time)
# or a future added category both degrade gracefully rather than erroring. Lighting, expression,
# pose, composition, and emotional_impact weighted higher per Tyrone's own stated priorities for
# what actually makes a frame a "keeper" versus merely technically clean.
# A weighted AVERAGE across 13 categories mathematically compresses spread relative to any one
# category alone (averaging many independently-varying numbers regresses toward the mean) --
# confirmed on a real 50-photo sample re-score: per-category SD roughly doubled to tripled vs.
# the pre-v4 baseline, with zero duplicate scores, but the aggregate overall_score's range came
# in under target (36.7 vs. a 50-point goal) even though each category discriminated well on
# its own. weighted_overall corrects for this with a contrast stretch around OVERALL_SCORE_CENTER
# (5.0/10 -- the rubric's own "competent but unremarkable" anchor, see evaluation_v4.txt):
# deviations from that center are multiplied by OVERALL_SCORE_CONTRAST before scaling to 0-100,
# the same way a contrast curve widens a photograph's tonal range around its midpoint. 1.5 was
# chosen by testing several values against that same real sample's actual category-score
# vectors (no re-running the model needed) -- it's the smallest value that cleared both the
# SD>=8 and range>=50 targets with zero photos needing to clamp at 0 or 10.
OVERALL_SCORE_CENTER = 5.0
OVERALL_SCORE_CONTRAST = 1.5

CATEGORY_WEIGHTS: dict[str, float] = {
    "composition": 1.3,
    "subject": 1.0,
    "lighting": 1.3,
    "exposure": 0.8,
    "focus": 1.0,
    "expression": 1.3,
    "pose": 1.3,
    "background": 0.8,
    "color_tonality": 0.9,
    "emotional_impact": 1.3,
    "visual_hierarchy": 0.8,
    "professional_polish": 0.9,
    "client_delivery_value": 1.0,
}

# RAW overall_score (0-100, from scoring.weighted_overall) -> letter grade. Checked in
# descending order; the first threshold overall_score meets or exceeds wins. These are a
# starting point calibrated against evaluation_v4's rubric (5/10 per category = "competent but
# unremarkable" -> a weighted ~50 should land mid-pack, not at a grade boundary) -- adjust freely,
# nothing else in the codebase hardcodes these numbers.
GRADE_THRESHOLDS: list[tuple[float, str]] = [
    (85.0, "A"),
    (70.0, "B"),
    (50.0, "C"),
    (30.0, "D"),
    (0.0, "F"),
]

# Same idea as GRADE_THRESHOLDS, independent scale (recommendation is a client-delivery
# decision, not a direct function of the letter grade) so the two can be tuned separately.
RECOMMENDATION_THRESHOLDS: list[tuple[float, str]] = [
    (70.0, "KEEP"),
    (45.0, "MAYBE"),
    (0.0, "REJECT"),
]

# The vision model is swappable without code changes: PHOTOCRITIC_VLM_MODEL overrides the
# Hugging Face repo ID (any mlx_vlm-loadable model), PHOTOCRITIC_EVAL_BATCH_SIZE the chunk size.
# Both are read fresh on every access via the module __getattr__ above, for the same reason the
# workspace paths are. Results are keyed by model ID in the DB (ai_evaluations.model_version), so
# switching models never overwrites another model's rows. Unset = the default below.
_VLM_MODEL_ENV_VAR = "PHOTOCRITIC_VLM_MODEL"
_EVAL_BATCH_SIZE_ENV_VAR = "PHOTOCRITIC_EVAL_BATCH_SIZE"
DEFAULT_VLM_MODEL_ID = "mlx-community/Qwen3-VL-30B-A3B-Instruct-8bit"

# PHOTOCRITIC_VLM_THINKING=on lets reasoning models (Qwen3.5/3.6, Gemma 4) "think" before
# answering. Off by default (mlx_vlm also renders chat templates with enable_thinking=False by
# default); has no effect on models without a thinking mode (e.g. Qwen3-VL-30B-A3B-Instruct).
# The prompt and output schema are identical either way -- the reasoning is stripped before JSON
# parsing -- but thinking needs room, so THINKING_EXTRA_TOKENS is added to every max_tokens.
_VLM_THINKING_ENV_VAR = "PHOTOCRITIC_VLM_THINKING"
THINKING_EXTRA_TOKENS = 6000

# KNOWN BUG, kept as the default so existing production scores stay reproducible until a
# deliberate switch: evaluate_batch used to hand mlx_vlm.batch_generate a prompt that was ALREADY
# chat-templated, and batch_generate templates it again -- so every batched evaluation saw a
# nested prompt (a user turn inside a user turn, two image placeholders for one image, two
# assistant headers). Qwen3-VL tolerates it; LFM3-VL and Gemma 4 crash on it.
# PHOTOCRITIC_LEGACY_BATCH_TEMPLATE=off sends the raw prompt so it is templated exactly once.
# Results from the fixed path are tagged "+tmpl1" in model_version so they never mix with legacy rows.
_LEGACY_BATCH_TEMPLATE_ENV_VAR = "PHOTOCRITIC_LEGACY_BATCH_TEMPLATE"

# mlx_vlm.batch_generate groups same-shaped images into one forward pass, which is
# dramatically faster per-image than sequential single-image calls (~3.8-4.5s/image
# vs ~19-20s/image measured on the M3 Ultra). Empirically: 20 images/batch succeeded
# in isolation (71.5GB peak GPU memory); 24 hit a Metal "Insufficient Memory" error
# despite 96GB total unified memory — there's a lower ceiling on the GPU's working set
# than total RAM (~83.5GB max_recommended_working_set_size on this machine).
#
# 12 looked safe in isolated testing but turned out NOT to be during a real sustained
# evaluate_batch run: peak measured at 82GB -- within ~1.5GB of that ceiling -- so a
# slightly heavier chunk (larger images, longer generations) was enough to tip over
# into a Metal OOM twice during an actual unattended re-score, at different file counts
# each time (not a fixed "crashes at N files" bug -- genuine peak-memory variance chunk
# to chunk). 8 trades a bit of per-image speed for real headroom under that ceiling
# instead of running the whole multi-hour job a hair's breadth from the edge.
#
# The 8 below is tuned for the default 30B model; other models have different memory profiles,
# so PHOTOCRITIC_EVAL_BATCH_SIZE can override it (see _VLM_MODEL_ENV_VAR above).
DEFAULT_EVAL_BATCH_SIZE = 8

# concurrent RAW decode + technical cull workers. rawpy/cv2 release the GIL during
# their C-extension calls, so a thread pool gives real parallelism on the M3 Ultra's
# cores for CPU-bound decode work. Benefit is smaller (or negative) on slow/USB
# source drives where decode is I/O-bound rather than CPU-bound.
INGEST_WORKERS = 8

ANALYSIS_LONG_EDGE = 1568  # full-frame analysis preview
DETAIL_CROP_LONG_EDGE = 1024  # face/detail crop for focus & eye inspection

# similarity grouping: perceptual-hash Hamming distance threshold (0-64, lower = stricter)
SIMILARITY_HASH_THRESHOLD = 8

# Technical cull thresholds. Calibrated at ANALYSIS_LONG_EDGE resolution using a
# center-weighted crop (see technical_cull.py) — NOT whole-frame, and NOT full-res.
# Whole-frame variance was tried first and rejected: shallow-DOF portraits with large
# smooth/dark backgrounds scored as "blurry" even when the subject was tack-sharp,
# because the flat background dominates the frame-wide variance.
SHARPNESS_BLUR_THRESHOLD = 60.0  # center-crop Laplacian variance below this = likely soft/blurry
HIGHLIGHT_CLIP_WARN_PCT = 2.0  # % of pixels at max value — skin/highlight blowouts are rarely intentional
SHADOW_CLIP_WARN_PCT = 15.0  # % of pixels at zero value — kept loose: low-key/high-contrast
# lighting is a deliberate, common professional choice, not a defect (per evaluation_v1's
# artistic-choice guidance). This flag exists for genuinely crushed frames, not stylistic ones.


def ensure_workspace_dirs() -> None:
    # Built from _workspace_root() directly, not the bare names (CACHE_DIR, etc.) -- those are
    # only resolvable from OUTSIDE this module, via the module __getattr__ above (PEP 562);
    # code inside this module referring to them as plain globals doesn't go through it, since
    # they were deliberately removed as real module-level assignments.
    root = _workspace_root()
    for d in (root / "cache", root / "previews", root / "database", root / "models",
              root / "logs", root / "exports", root / "models" / "hf-cache"):
        d.mkdir(parents=True, exist_ok=True)
