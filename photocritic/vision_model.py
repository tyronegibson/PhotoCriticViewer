"""VisionModel abstraction — the evaluation/ranking model must be replaceable.

Which model loads is config.VLM_MODEL_ID (env PHOTOCRITIC_VLM_MODEL); the prompt, output
schema and parsing are identical for every model so results stay comparable."""

import contextlib
import functools
import json
import os
import re
from abc import ABC, abstractmethod

from . import config

os.environ.setdefault("HF_HOME", str(config.HF_HOME))


_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.DOTALL)


def _strip_reasoning(text: str) -> str:
    """Drop a thinking-mode reasoning block, if any, so only the final answer is parsed.
    Handles a closed <think>...</think> block and a template that opens <think> in the prompt
    (output then starts mid-reasoning and only contains the closing tag)."""
    text = _THINK_BLOCK.sub("", text)
    if "</think>" in text:
        text = text.rsplit("</think>", 1)[1]
    return text


def _extract_json(text: str) -> dict:
    text = _strip_reasoning(text).strip()
    text = re.sub(r"^```(json)?", "", text).strip()
    text = re.sub(r"```$", "", text).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Thinking models sometimes add a sentence around the JSON; take the outermost object.
        start, end = text.find("{"), text.rfind("}")
        if start != -1 and end > start:
            return json.loads(text[start : end + 1])
        raise


class VisionModel(ABC):
    @abstractmethod
    def evaluate_single(self, image_path: str, prompt_text: str) -> dict: ...

    @abstractmethod
    def evaluate_batch(self, image_paths: list[str], prompt_text: str) -> list[dict]: ...

    @abstractmethod
    def rank_group(self, image_paths: list[str], prompt_text: str) -> dict: ...


class MLXVisionModel(VisionModel):
    """Any mlx_vlm-loadable vision-language model (Qwen3-VL, Gemma, ...)."""

    def __init__(self, model_id: str | None = None, thinking: bool | None = None):
        self.model_id = model_id or config.VLM_MODEL_ID
        self.thinking = config.VLM_THINKING if thinking is None else thinking
        # The value stored in the DB's model_version column for this model's results.
        self.legacy_batch_template = config.LEGACY_BATCH_TEMPLATE
        self.version_tag = (self.model_id + ("+thinking" if self.thinking else "")
                            + ("" if self.legacy_batch_template else "+tmpl1"))
        from mlx_vlm import generate, load
        from mlx_vlm.prompt_utils import apply_chat_template

        self._generate = generate
        self._apply_chat_template = apply_chat_template
        self.model, self.processor = load(self.model_id)

    def _template_kwargs(self) -> dict:
        # Only pass enable_thinking=True explicitly; off is mlx_vlm's own default, so the
        # default model's prompt renders byte-for-byte as it did before this option existed.
        return {"enable_thinking": True} if self.thinking else {}

    @contextlib.contextmanager
    def _batch_thinking_template(self):
        """batch_generate renders the chat template internally without forwarding template
        kwargs, so thinking mode can't be requested through its API. When thinking is on (and
        the prompt is templated only once), temporarily wrap the apply_chat_template it calls."""
        if not self.thinking or self.legacy_batch_template:
            yield
            return
        # importlib, not `import mlx_vlm.generate.ar`: mlx_vlm re-exports a *function* named
        # `generate`, which shadows the subpackage for attribute-style imports.
        import importlib

        ar = importlib.import_module("mlx_vlm.generate.ar")

        original = ar.apply_chat_template
        ar.apply_chat_template = functools.partial(original, enable_thinking=True)
        try:
            yield
        finally:
            ar.apply_chat_template = original

    def _token_budget(self, max_tokens: int) -> int:
        return max_tokens + (config.THINKING_EXTRA_TOKENS if self.thinking else 0)

    def _repair_json(self, raw_text: str, max_tokens: int) -> dict | None:
        """One repair retry: ask the model (text-only) to reformat as strict JSON."""
        repair_prompt = (
            "The following text was supposed to be a single strict JSON object "
            "but failed to parse. Return ONLY the corrected JSON object, no "
            f"commentary:\n\n{raw_text}"
        )
        repair_formatted = self._apply_chat_template(
            self.processor, self.model.config, repair_prompt, num_images=0
        )
        repair_result = self._generate(
            self.model,
            self.processor,
            repair_formatted,
            image=None,
            max_tokens=max_tokens,
            temperature=0.0,
            verbose=False,
        )
        repair_text = repair_result.text if hasattr(repair_result, "text") else str(repair_result)
        try:
            return _extract_json(repair_text)
        except json.JSONDecodeError:
            return None

    def _run(self, prompt_text: str, image_paths, max_tokens: int = 1400, temperature: float = 0.2) -> dict:
        formatted = self._apply_chat_template(
            self.processor, self.model.config, prompt_text, num_images=len(image_paths),
            **self._template_kwargs(),
        )
        result = self._generate(
            self.model,
            self.processor,
            formatted,
            image=image_paths,
            max_tokens=self._token_budget(max_tokens),
            temperature=temperature,
            verbose=False,
        )
        raw_text = result.text if hasattr(result, "text") else str(result)
        try:
            return {"ok": True, "parsed": _extract_json(raw_text), "raw": raw_text}
        except json.JSONDecodeError as e:
            repaired = self._repair_json(raw_text, max_tokens)
            if repaired is not None:
                return {"ok": True, "parsed": repaired, "raw": raw_text}
            return {"ok": False, "error": str(e), "raw": raw_text}

    def evaluate_single(self, image_path: str, prompt_text: str) -> dict:
        # evaluation_v4: low temperature (config.EVALUATION_TEMPERATURE, 0-0.2) rather than the
        # high 0.8 v2/v3 used -- that high temperature was a direct contributor to the score
        # clustering real production data showed (free-floating per-category scores sampled at
        # temp 0.8 converge toward similar round numbers more than they spread out). Anchored
        # rubrics in the prompt now do the work of creating genuine score spread; sampling noise
        # no longer needs to.
        return self._run(prompt_text, [image_path], temperature=config.EVALUATION_TEMPERATURE)

    def evaluate_batch(self, image_paths: list[str], prompt_text: str) -> list[dict]:
        """~5x faster per-image than evaluate_single: mlx_vlm.batch_generate groups
        same-shaped images into one forward pass instead of one call per image.
        Chunked at config.EVAL_BATCH_SIZE — see that constant for why.

        Self-consistency (config.EVALUATION_SELF_CONSISTENCY_N > 1): each image is repeated N
        times within the batch -- still one forward pass per chunk, since repeats are just more
        items in the same batched call -- and the N independent (stochastic, since temperature >
        0) samples per image are combined via photocritic.scoring.median_combine before being
        returned. N=1 (the default) skips all of this and returns exactly what it did before.
        """
        import mlx.core as mx
        import mlx_vlm
        from mlx_vlm.sample_utils import make_sampler

        from .scoring import median_combine

        n = max(1, config.EVALUATION_SELF_CONSISTENCY_N)
        max_tokens = self._token_budget(config.EVALUATION_MAX_TOKENS)
        # batch_generate applies the chat template ITSELF. Legacy (default) behaviour hands it an
        # already-templated prompt -> double-templated; see config.LEGACY_BATCH_TEMPLATE.
        if self.legacy_batch_template:
            batch_prompt = self._apply_chat_template(
                self.processor, self.model.config, prompt_text, num_images=1,
                **self._template_kwargs(),
            )
        else:
            batch_prompt = prompt_text
        # repeated_paths[i*n : i*n+n] are the N samples for image_paths[i].
        repeated_paths = [p for p in image_paths for _ in range(n)]
        raw_results: list[dict | None] = [None] * len(repeated_paths)

        batch_size = config.EVAL_BATCH_SIZE
        for start in range(0, len(repeated_paths), batch_size):
            chunk = repeated_paths[start : start + batch_size]
            prompts = [batch_prompt] * len(chunk)
            with self._batch_thinking_template():
                resp = mlx_vlm.batch_generate(
                    self.model, self.processor,
                    images=chunk, prompts=prompts,
                    max_tokens=max_tokens, sampler=make_sampler(temp=config.EVALUATION_TEMPERATURE),
                )
            # Each chunk's forward pass fits comfortably on its own (tested up to batch
            # size 20 in isolation), but MLX's GPU buffer cache otherwise keeps growing
            # across many sequential chunks in one long-running process -- a real
            # evaluate_batch run OOM'd ~35min/252 files in despite every individual chunk
            # being well within budget. clear_cache() releases unused cached buffers back
            # to the system after each chunk; next chunk just reallocates, which is cheap
            # relative to generation time.
            mx.clear_cache()
            for i, raw_text in enumerate(resp.texts):
                try:
                    raw_results[start + i] = {"ok": True, "parsed": _extract_json(raw_text), "raw": raw_text}
                except json.JSONDecodeError as e:
                    # Rare: repair individually rather than re-running the whole chunk.
                    repaired = self._repair_json(raw_text, max_tokens)
                    if repaired is not None:
                        raw_results[start + i] = {"ok": True, "parsed": repaired, "raw": raw_text}
                    else:
                        raw_results[start + i] = {"ok": False, "error": str(e), "raw": raw_text}

        if n == 1:
            return raw_results

        combined: list[dict | None] = [None] * len(image_paths)
        for i in range(len(image_paths)):
            samples = raw_results[i * n : i * n + n]
            ok_samples = [s for s in samples if s is not None and s["ok"]]
            if not ok_samples:
                combined[i] = samples[0] if samples[0] is not None else {"ok": False, "error": "no samples", "raw": ""}
                continue
            merged_parsed = median_combine([s["parsed"] for s in ok_samples])
            combined[i] = {"ok": True, "parsed": merged_parsed, "raw": ok_samples[0]["raw"]}
        return combined

    def rank_group(self, image_paths: list[str], prompt_text: str) -> dict:
        return self._run(prompt_text, image_paths, max_tokens=1800, temperature=0.2)


# Backwards-compatible alias: the class was Qwen3VL before the model became configurable.
Qwen3VL = MLXVisionModel

_shared_model: MLXVisionModel | None = None


def get_shared_model() -> MLXVisionModel:
    """One loaded model per process. If config.VLM_MODEL_ID changed since it was loaded (env var
    set mid-process), load the new one rather than silently scoring with the old one under the
    new model's ID."""
    global _shared_model
    if _shared_model is None or _shared_model.version_tag != config.VLM_MODEL_VERSION:
        _shared_model = None
        _shared_model = MLXVisionModel()
    return _shared_model
