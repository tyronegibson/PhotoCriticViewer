"""eval/metrics.py: pure functions behind the model comparison report."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "eval"))

import metrics  # noqa: E402


class EvalMetricsTest(unittest.TestCase):
    def test_spearman(self):
        self.assertAlmostEqual(metrics.spearman([1, 2, 3, 4], [10, 20, 30, 40]), 1.0)
        self.assertAlmostEqual(metrics.spearman([1, 2, 3, 4], [4, 3, 2, 1]), -1.0)
        self.assertIsNone(metrics.spearman([1, 1, 1], [1, 2, 3]))

    def test_roc_auc(self):
        self.assertEqual(metrics.roc_auc([9, 8, 1, 2], [True, True, False, False]), 1.0)
        self.assertEqual(metrics.roc_auc([1, 2, 9, 8], [True, True, False, False]), 0.0)
        self.assertEqual(metrics.roc_auc([5, 5], [True, False]), 0.5)

    def test_precision_recall_and_top_k(self):
        pr = metrics.precision_recall([True, True, False, False], [True, False, True, False])
        self.assertEqual((pr["tp"], pr["fp"], pr["fn"]), (1, 1, 1))
        self.assertEqual(pr["precision"], 0.5)
        self.assertEqual(metrics.top_k_mask([3, 9, 1, 7], 2), [False, True, False, True])

    def test_disagreements_rank_kept_low_and_rejected_high(self):
        fids = [1, 2, 3, 4, 5]
        scores = [90, 80, 50, 20, 10]
        labels = [-1, 0, 0, 0, 1]  # model's best frame was rejected, its worst was a pick
        top = metrics.biggest_disagreements(fids, scores, labels, 2)
        self.assertEqual({d["file_id"] for d in top}, {1, 5})

    def test_summarize(self):
        s = metrics.summarize([1, 2, 3, 4], [90, 80, 30, 10], ["KEEP", "KEEP", "MAYBE", "REJECT"], [1, 0, 1, -1])
        self.assertEqual(s["user_keepers"], 2)
        self.assertEqual(s["at_top_k"]["precision"], 0.5)
        self.assertEqual(s["keepers_model_rejects"], 0)
        self.assertEqual(s["user_rejects_caught"], (1, 1))


if __name__ == "__main__":
    unittest.main()
