"""Regression: a missing preview file (pruned, moved, or never finished writing) must not crash
the whole evaluate_batch chunk it's in -- every OTHER file in that chunk still gets evaluated.
The real vision model is never loaded here; vision_model.get_shared_model is monkeypatched with
a fake that returns a canned response, so this stays a fast unit test.

Run: python3 -m unittest tests.test_evaluate_missing_preview   (from the project root, using .venv)
"""

import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("PHOTOCRITIC_WORKSPACE", str(Path(tempfile.mkdtemp(prefix="pc-missing-preview-test-")) / "ws"))

from photocritic import db, pipeline  # noqa: E402

CANNED_RESPONSE = {
    "ok": True,
    "parsed": {
        "category_evaluations": {"composition": {"reason": "fine", "score": 6.0}},
        "reasoning": "ok",
    },
    "raw": "{}",
}


class FakeModel:
    model_id = "mlx-community/Qwen3-VL-30B-A3B-Instruct-8bit"
    version_tag = model_id

    def evaluate_batch(self, image_paths, prompt_text):
        return [dict(CANNED_RESPONSE) for _ in image_paths]


class MissingPreviewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pc-missing-preview-shoot-"))

    def make_file(self, conn, shoot_id, name, preview_exists: bool) -> int:
        full_path = str(self.tmp / name)
        Path(full_path).write_bytes(b"x")
        file_id = db.get_or_create_file(conn, shoot_id, name, full_path, 1, time.time())
        preview_path = str(self.tmp / f"{name}.preview.jpg")
        if preview_exists:
            Path(preview_path).write_bytes(b"x")
        db.save_technical_analysis(
            conn, file_id,
            type("TA", (), {"sharpness_score": 1.0, "is_blury": False, "is_blurry": False,
                             "exposure_mean": 1.0, "highlight_clip_pct": 0.0, "shadow_clip_pct": 0.0,
                             "flags": []})(),
            "phash", preview_path,
        )
        return file_id

    @patch("photocritic.vision_model.get_shared_model", return_value=FakeModel())
    def test_missing_preview_is_skipped_not_fatal_to_the_rest(self, _mock_model):
        with db.connect() as conn:
            db.init_schema(conn)
            shoot_id = db.get_or_create_shoot(conn, str(self.tmp))
            present_id = self.make_file(conn, shoot_id, "present.3fr", preview_exists=True)
            missing_id = self.make_file(conn, shoot_id, "missing.3fr", preview_exists=False)
            conn.commit()

            pipeline.run_evaluations(conn, [present_id, missing_id])
            conn.commit()

            self.assertTrue(db.has_evaluation(conn, present_id, pipeline.config.VLM_MODEL_VERSION, pipeline.config.EVALUATION_PROMPT_VERSION))
            self.assertFalse(db.has_evaluation(conn, missing_id, pipeline.config.VLM_MODEL_VERSION, pipeline.config.EVALUATION_PROMPT_VERSION))


if __name__ == "__main__":
    unittest.main()
