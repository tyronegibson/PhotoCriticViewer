"""A/B test evaluation_v1 vs evaluation_v2 on a diverse sample: compare score spread."""

from photocritic import config
from photocritic.vision_model import get_shared_model

SAMPLE = ["B0001053", "B0001057", "B0001061", "B0001065", "B0001069",
          "B0001073", "B0001103", "B0001108", "B0001112", "B0001116"]

v1_text = (config.PROMPTS_DIR / "evaluation_v1.txt").read_text()
v3_text = (config.PROMPTS_DIR / "evaluation_v3.txt").read_text()

model = get_shared_model()

for label, prompt_text in [("v1", v1_text), ("v3", v3_text)]:
    print(f"\n=== {label} ===")
    scores = []
    for stem in SAMPLE:
        # POC: reads decode_test.py output, not live previews (those are keyed by file id).
        img_path = str(config.WORKSPACE_ROOT / "poc-previews" / f"{stem}.jpg")
        result = model.evaluate_single(img_path, prompt_text)
        if result["ok"]:
            s = result["parsed"]["overall_score"]
            scores.append(s)
            extra = ""
            if "distinguishing_strength" in result["parsed"]:
                extra = f"  | + {result['parsed']['distinguishing_strength'][:60]}"
            print(f"{stem}: {s}{extra}")
        else:
            print(f"{stem}: FAILED {result['error']}")
    if scores:
        print(f"-- {label} spread: min={min(scores)} max={max(scores)} unique={len(set(scores))}/{len(scores)} "
              f"stdev={(sum((x-sum(scores)/len(scores))**2 for x in scores)/len(scores))**0.5:.2f}")
