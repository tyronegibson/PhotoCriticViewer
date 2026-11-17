"""Model selection is config-driven (PHOTOCRITIC_VLM_MODEL / PHOTOCRITIC_EVAL_BATCH_SIZE) and
read fresh on every access. No model is ever loaded here."""

import os
import unittest
from unittest.mock import patch

from photocritic import config, vision_model

DEFAULT = "mlx-community/Qwen3-VL-30B-A3B-Instruct-8bit"


class ModelConfigTest(unittest.TestCase):
    def test_default_is_qwen3_vl_30b(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("PHOTOCRITIC_VLM_MODEL", None)
            os.environ.pop("PHOTOCRITIC_EVAL_BATCH_SIZE", None)
            self.assertEqual(config.VLM_MODEL_ID, DEFAULT)
            self.assertEqual(config.EVAL_BATCH_SIZE, 8)

    def test_env_overrides_are_read_fresh(self):
        with patch.dict(os.environ, {"PHOTOCRITIC_VLM_MODEL": "org/other-model",
                                     "PHOTOCRITIC_EVAL_BATCH_SIZE": "3"}):
            self.assertEqual(config.VLM_MODEL_ID, "org/other-model")
            self.assertEqual(config.EVAL_BATCH_SIZE, 3)
        self.assertEqual(config.VLM_MODEL_ID, DEFAULT)

    def test_bad_batch_size_rejected(self):
        with patch.dict(os.environ, {"PHOTOCRITIC_EVAL_BATCH_SIZE": "0"}):
            with self.assertRaises(ValueError):
                _ = config.EVAL_BATCH_SIZE

    def test_shared_model_reloads_when_model_id_changes(self):
        loaded = []

        class Fake:
            def __init__(self):
                self.model_id = config.VLM_MODEL_ID
                self.version_tag = config.VLM_MODEL_VERSION
                loaded.append(self.version_tag)

        with patch.object(vision_model, "MLXVisionModel", Fake), \
             patch.object(vision_model, "_shared_model", None):
            with patch.dict(os.environ, {"PHOTOCRITIC_VLM_MODEL": "org/a"}):
                a1 = vision_model.get_shared_model()
                a2 = vision_model.get_shared_model()
            with patch.dict(os.environ, {"PHOTOCRITIC_VLM_MODEL": "org/b"}):
                b = vision_model.get_shared_model()
            with patch.dict(os.environ, {"PHOTOCRITIC_VLM_MODEL": "org/b", "PHOTOCRITIC_VLM_THINKING": "on"}):
                b_think = vision_model.get_shared_model()
        self.assertIs(a1, a2)
        self.assertEqual(b.model_id, "org/b")
        self.assertEqual(loaded, ["org/a", "org/b", "org/b+thinking"])
        self.assertIsNot(b, b_think)

    def test_thinking_flag_and_version_tag(self):
        os.environ.pop("PHOTOCRITIC_VLM_THINKING", None)
        self.assertFalse(config.VLM_THINKING)
        self.assertEqual(config.VLM_MODEL_VERSION, config.VLM_MODEL_ID)
        with patch.dict(os.environ, {"PHOTOCRITIC_VLM_THINKING": "on"}):
            self.assertTrue(config.VLM_THINKING)
            self.assertEqual(config.VLM_MODEL_VERSION, config.VLM_MODEL_ID + "+thinking")
        with patch.dict(os.environ, {"PHOTOCRITIC_VLM_THINKING": "maybe"}):
            with self.assertRaises(ValueError):
                _ = config.VLM_THINKING

    def test_extract_json_strips_reasoning(self):
        ex = vision_model._extract_json
        self.assertEqual(ex('{"a": 1}'), {"a": 1})
        self.assertEqual(ex('<think>hmm {"no": 0}</think>\n```json\n{"a": 1}\n```'), {"a": 1})
        # template opened <think> in the prompt: output has only the closing tag
        self.assertEqual(ex('reasoning {"x": 2} more</think>{"a": 1}'), {"a": 1})
        self.assertEqual(ex('Here is the result: {"a": {"b": 2}} Done.'), {"a": {"b": 2}})

    def test_legacy_batch_template_default_and_tag(self):
        os.environ.pop("PHOTOCRITIC_LEGACY_BATCH_TEMPLATE", None)
        os.environ.pop("PHOTOCRITIC_VLM_THINKING", None)
        self.assertTrue(config.LEGACY_BATCH_TEMPLATE)  # production default unchanged
        self.assertEqual(config.VLM_MODEL_VERSION, config.VLM_MODEL_ID)
        with patch.dict(os.environ, {"PHOTOCRITIC_LEGACY_BATCH_TEMPLATE": "off", "PHOTOCRITIC_VLM_THINKING": "on"}):
            self.assertFalse(config.LEGACY_BATCH_TEMPLATE)
            self.assertEqual(config.VLM_MODEL_VERSION, config.VLM_MODEL_ID + "+thinking+tmpl1")

    def test_legacy_alias(self):
        self.assertIs(vision_model.Qwen3VL, vision_model.MLXVisionModel)


if __name__ == "__main__":
    unittest.main()
