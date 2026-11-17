"""Unit tests for photocritic/scoring.py -- the code-side weighted-overall/grade/recommendation
computation and the self-consistency median combiner. Pure functions, no DB/model involved.

Run: python3 -m unittest tests.test_scoring   (from the project root, using .venv)
"""

import sys
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT))

from photocritic import scoring  # noqa: E402


class ExtractCategoryScoresTest(unittest.TestCase):
    def test_v4_nested_shape(self):
        parsed = {"category_evaluations": {"composition": {"reason": "x", "score": 7.5}, "lighting": {"reason": "y", "score": 3}}}
        self.assertEqual(scoring.extract_category_scores(parsed), {"composition": 7.5, "lighting": 3.0})

    def test_legacy_flat_shape(self):
        parsed = {"scores": {"composition": 8, "lighting": 6.5}}
        self.assertEqual(scoring.extract_category_scores(parsed), {"composition": 8.0, "lighting": 6.5})

    def test_missing_scores_is_empty_not_an_error(self):
        self.assertEqual(scoring.extract_category_scores({}), {})

    def test_malformed_category_entry_is_skipped(self):
        parsed = {"category_evaluations": {"composition": {"reason": "x", "score": 7}, "lighting": "not a dict"}}
        self.assertEqual(scoring.extract_category_scores(parsed), {"composition": 7.0})


class ExtractCategoryReasonsTest(unittest.TestCase):
    def test_v4_reasons(self):
        parsed = {"category_evaluations": {"composition": {"reason": "tight crop on the hand", "score": 7.5}}}
        self.assertEqual(scoring.extract_category_reasons(parsed), {"composition": "tight crop on the hand"})

    def test_legacy_rows_have_no_per_category_reasons(self):
        self.assertEqual(scoring.extract_category_reasons({"scores": {"composition": 8}}), {})


class WeightedOverallTest(unittest.TestCase):
    """contrast=1.0 is passed explicitly throughout -- it's the no-op value, isolating the
    weighted-average math itself from the contrast stretch (covered separately below)."""

    def test_equal_weights_is_a_plain_average_times_ten(self):
        scores = {"a": 5.0, "b": 7.0}
        self.assertEqual(scoring.weighted_overall(scores, weights={"a": 1.0, "b": 1.0}, contrast=1.0), 60.0)

    def test_weights_dont_need_to_sum_to_one(self):
        # (5*2 + 7*1) / 3 * 10 = 56.67
        scores = {"a": 5.0, "b": 7.0}
        self.assertAlmostEqual(scoring.weighted_overall(scores, weights={"a": 2.0, "b": 1.0}, contrast=1.0), 56.67, places=1)

    def test_missing_weight_defaults_to_one(self):
        scores = {"a": 5.0, "unweighted_category": 5.0}
        self.assertEqual(scoring.weighted_overall(scores, weights={"a": 1.0}, contrast=1.0), 50.0)

    def test_empty_scores_is_none_not_zero(self):
        self.assertIsNone(scoring.weighted_overall({}, weights={"a": 1.0}))

    def test_uses_config_weights_by_default(self):
        # Every real category at the same value should land on that value * 10 regardless of
        # the specific weights, since a uniform input is invariant to relative weighting.
        from photocritic import config
        scores = {cat: 6.0 for cat in config.CATEGORY_WEIGHTS}
        self.assertEqual(scoring.weighted_overall(scores, contrast=1.0), 60.0)


class ContrastStretchTest(unittest.TestCase):
    """weighted_overall's contrast stretch (config.OVERALL_SCORE_CENTER/OVERALL_SCORE_CONTRAST)
    -- added after a real 50-photo sample re-score showed the plain weighted average (contrast
    1.0) compressing range below target even with healthy per-category spread. See config.py's
    comment for how 1.5 was chosen."""

    def test_contrast_of_one_is_a_no_op(self):
        scores = {"a": 8.0}
        self.assertEqual(scoring.weighted_overall(scores, weights={"a": 1.0}, center=5.0, contrast=1.0), 80.0)

    def test_score_exactly_at_center_is_unaffected_by_contrast(self):
        scores = {"a": 5.0}
        for contrast in (1.0, 1.5, 3.0):
            self.assertEqual(scoring.weighted_overall(scores, weights={"a": 1.0}, center=5.0, contrast=contrast), 50.0)

    def test_higher_contrast_pushes_an_above_center_score_further_up(self):
        scores = {"a": 7.0}  # 2.0 above a center of 5.0
        low = scoring.weighted_overall(scores, weights={"a": 1.0}, center=5.0, contrast=1.0)
        high = scoring.weighted_overall(scores, weights={"a": 1.0}, center=5.0, contrast=2.0)
        self.assertEqual(low, 70.0)
        self.assertEqual(high, 90.0)  # 5 + (7-5)*2 = 9 -> 90
        self.assertGreater(high, low)

    def test_higher_contrast_pushes_a_below_center_score_further_down(self):
        scores = {"a": 3.0}  # 2.0 below center
        low_contrast = scoring.weighted_overall(scores, weights={"a": 1.0}, center=5.0, contrast=1.0)
        high_contrast = scoring.weighted_overall(scores, weights={"a": 1.0}, center=5.0, contrast=2.0)
        self.assertEqual(high_contrast, 10.0)  # 5 + (3-5)*2 = 1 -> 10
        self.assertLess(high_contrast, low_contrast)

    def test_clamped_to_the_valid_0_to_100_range_even_at_extreme_contrast(self):
        scores = {"a": 10.0}
        result = scoring.weighted_overall(scores, weights={"a": 1.0}, center=5.0, contrast=5.0)
        self.assertEqual(result, 100.0)  # would be 5 + 5*5 = 30 (/10 scale) unclamped -- clamped to 10

        scores = {"a": 0.0}
        result = scoring.weighted_overall(scores, weights={"a": 1.0}, center=5.0, contrast=5.0)
        self.assertEqual(result, 0.0)  # would go negative unclamped -- clamped to 0


class GradeAndRecommendationTest(unittest.TestCase):
    def test_grade_thresholds_are_inclusive_and_descending(self):
        thresholds = [(85.0, "A"), (70.0, "B"), (50.0, "C"), (30.0, "D"), (0.0, "F")]
        self.assertEqual(scoring.grade_for(85.0, thresholds), "A")
        self.assertEqual(scoring.grade_for(84.9, thresholds), "B")
        self.assertEqual(scoring.grade_for(0.0, thresholds), "F")
        self.assertEqual(scoring.grade_for(100.0, thresholds), "A")

    def test_recommendation_thresholds(self):
        thresholds = [(70.0, "KEEP"), (45.0, "MAYBE"), (0.0, "REJECT")]
        self.assertEqual(scoring.recommendation_for(70.0, thresholds), "KEEP")
        self.assertEqual(scoring.recommendation_for(69.9, thresholds), "MAYBE")
        self.assertEqual(scoring.recommendation_for(10.0, thresholds), "REJECT")


class ScoreInCodeTest(unittest.TestCase):
    def test_injects_overall_classification_recommendation(self):
        parsed = {
            "category_evaluations": {cat: {"reason": "r", "score": 9.0} for cat in ("composition", "lighting")},
            "reasoning": "unaffected field stays as-is",
        }
        weights = {"composition": 1.0, "lighting": 1.0}
        result = scoring.score_in_code({**parsed})
        # overall_score uses config weights by default -- just check it's computed and sane,
        # and that the untouched field survived.
        self.assertIsNotNone(result["overall_score"])
        self.assertIn(result["classification"], {"A", "B", "C", "D", "F"})
        self.assertIn(result["recommendation"], {"KEEP", "MAYBE", "REJECT"})
        self.assertEqual(result["reasoning"], "unaffected field stays as-is")
        # original input dict is not mutated
        self.assertNotIn("overall_score", parsed)

    def test_no_scoreable_categories_yields_none_not_a_crash(self):
        result = scoring.score_in_code({"reasoning": "no scores at all"})
        self.assertIsNone(result["overall_score"])
        self.assertIsNone(result["classification"])
        self.assertIsNone(result["recommendation"])


class MedianCombineTest(unittest.TestCase):
    def test_single_sample_passes_through_unchanged(self):
        sample = {"category_evaluations": {"composition": {"reason": "x", "score": 7}}}
        self.assertEqual(scoring.median_combine([sample]), sample)

    def test_takes_per_category_median_across_three_samples(self):
        samples = [
            {"category_evaluations": {"composition": {"reason": "a", "score": 3.0}, "lighting": {"reason": "a", "score": 8.0}}},
            {"category_evaluations": {"composition": {"reason": "b", "score": 7.0}, "lighting": {"reason": "b", "score": 7.0}}},
            {"category_evaluations": {"composition": {"reason": "c", "score": 7.5}, "lighting": {"reason": "c", "score": 6.0}}},
        ]
        combined = scoring.median_combine(samples)
        self.assertEqual(combined["category_evaluations"]["composition"]["score"], 7.0)
        self.assertEqual(combined["category_evaluations"]["lighting"]["score"], 7.0)
        self.assertEqual(combined["_self_consistency_sample_count"], 3)

    def test_an_outlier_sample_does_not_drag_the_median(self):
        samples = [
            {"category_evaluations": {"composition": {"reason": "a", "score": 1.0}}},  # outlier
            {"category_evaluations": {"composition": {"reason": "b", "score": 6.0}}},
            {"category_evaluations": {"composition": {"reason": "c", "score": 6.5}}},
        ]
        combined = scoring.median_combine(samples)
        self.assertEqual(combined["category_evaluations"]["composition"]["score"], 6.0)


if __name__ == "__main__":
    unittest.main()
