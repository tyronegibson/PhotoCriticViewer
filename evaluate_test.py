"""Phase 2 POC: run one decoded preview through Qwen3-VL and get a structured evaluation."""

import json
import re
import time
from pathlib import Path

from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template

MODEL_PATH = "mlx-community/Qwen3-VL-30B-A3B-Instruct-8bit"
PROMPT_PATH = Path(__file__).parent / "prompts" / "evaluation_v1.txt"
# Reads decode_test.py output. Live previews are {file_id}.jpg; never read by stem.
PREVIEW_DIR = Path("/Volumes/AI-/PhotoCritic/poc-previews")


def extract_json(text: str) -> dict:
    text = text.strip()
    text = re.sub(r"^```(json)?", "", text).strip()
    text = re.sub(r"```$", "", text).strip()
    return json.loads(text)


if __name__ == "__main__":
    print("Loading model (first load reads weights from disk)...")
    t0 = time.time()
    model, processor = load(MODEL_PATH)
    print(f"Model loaded in {time.time() - t0:.1f}s")

    prompt_text = PROMPT_PATH.read_text()
    formatted_prompt = apply_chat_template(
        processor, model.config, prompt_text, num_images=1
    )

    stems = ["B0001056", "B0001057", "B0001058", "B0001059", "B0001060"]
    summary = []
    for stem in stems:
        image_path = str(PREVIEW_DIR / f"{stem}.jpg")
        t0 = time.time()
        result = generate(
            model,
            processor,
            formatted_prompt,
            image=image_path,
            max_tokens=1200,
            temperature=0.2,
            verbose=False,
        )
        gen_s = time.time() - t0
        raw_text = result.text if hasattr(result, "text") else str(result)

        print(f"\n=== {stem} ({gen_s:.1f}s) ===")
        try:
            parsed = extract_json(raw_text)
            print(json.dumps(parsed, indent=2))
            summary.append((stem, gen_s, parsed["overall_score"], parsed["classification"], parsed["recommendation"]))
        except json.JSONDecodeError as e:
            print(f"JSON PARSE FAILED: {e}")
            print(raw_text)
            summary.append((stem, gen_s, None, None, "PARSE_FAILED"))

    print("\n=== summary ===")
    for stem, gen_s, score, cls, rec in summary:
        print(f"{stem}: {gen_s:.1f}s  score={score}  class={cls}  rec={rec}")
