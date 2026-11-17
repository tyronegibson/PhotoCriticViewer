"""Stage 1 technical cull: fast, objective, conventional-CV first pass.
Classifies only — never deletes or otherwise alters anything.

Face/eye/expression judgment is deliberately left to the stage-2 vision-language
model rather than Haar cascades: this installed opencv-python build (5.0.0) ships
no CascadeClassifier bindings or cascade XML files at all (OpenCV appears to have
dropped that legacy API from the 5.x Python wheel), and Haar-based eye detection is
unreliable on non-frontal poses regardless. Qwen3-VL already reports on expression
and eye state as part of its structured evaluation."""

from dataclasses import dataclass, field

import cv2
import numpy as np

from . import config


@dataclass
class TechnicalAnalysis:
    sharpness_score: float
    is_blurry: bool
    exposure_mean: float
    highlight_clip_pct: float
    shadow_clip_pct: float
    flags: list = field(default_factory=list)


def _center_crop(gray: np.ndarray, frac: float = 0.5) -> np.ndarray:
    """Subject-weighted crop: portraits are typically centered, and cropping out
    the (often smooth, often dark) surrounding background avoids the background
    dominating the sharpness signal."""
    h, w = gray.shape
    ch, cw = int(h * frac), int(w * frac)
    y0, x0 = (h - ch) // 2, (w - cw) // 2
    return gray[y0 : y0 + ch, x0 : x0 + cw]


def _sharpness(gray: np.ndarray) -> float:
    return float(cv2.Laplacian(_center_crop(gray), cv2.CV_64F).var())


def _exposure(gray: np.ndarray) -> tuple[float, float, float]:
    total_px = gray.size
    highlight_pct = float(np.count_nonzero(gray >= 253)) / total_px * 100
    shadow_pct = float(np.count_nonzero(gray <= 2)) / total_px * 100
    return float(gray.mean()), highlight_pct, shadow_pct


def analyze(rgb: np.ndarray) -> TechnicalAnalysis:
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)

    sharpness = _sharpness(gray)
    is_blurry = sharpness < config.SHARPNESS_BLUR_THRESHOLD

    exposure_mean, highlight_pct, shadow_pct = _exposure(gray)

    flags = []
    if is_blurry:
        flags.append("soft_focus_or_motion_blur")
    if highlight_pct > config.HIGHLIGHT_CLIP_WARN_PCT:
        flags.append("highlight_clipping")
    if shadow_pct > config.SHADOW_CLIP_WARN_PCT:
        flags.append("shadow_clipping")

    return TechnicalAnalysis(
        sharpness_score=sharpness,
        is_blurry=is_blurry,
        exposure_mean=exposure_mean,
        highlight_clip_pct=highlight_pct,
        shadow_clip_pct=shadow_pct,
        flags=flags,
    )
