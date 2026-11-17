"""Unit tests for photocritic/calibration.py's percentile/z-score math. Pure functions, no DB.

Run: python3 -m unittest tests.test_calibration   (from the project root, using .venv)
"""

import sys
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT))

from photocritic import calibration  # noqa: E402


class ComputeCalibrationTest(unittest.TestCase):
    def test_percentile_library_spans_close_to_full_range(self):
        rows = [
            {"evaluation_id": i, "file_id": i, "shoot_id": 1, "overall_score": score}
            for i, score in enumerate([50, 60, 70, 80, 90], start=1)
        ]
        out = {r["file_id"]: r for r in calibration.compute_calibration(rows)}
        self.assertLess(out[1]["percentile_library"], 20)
        self.assertGreater(out[5]["percentile_library"], 80)
        # calibrated_score is, by design, the same as percentile_library.
        self.assertEqual(out[1]["calibrated_score"], out[1]["percentile_library"])

    def test_percentile_shoot_is_scoped_to_its_own_shoot(self):
        rows = [
            {"evaluation_id": 1, "file_id": 1, "shoot_id": 1, "overall_score": 90},  # best in shoot 1
            {"evaluation_id": 2, "file_id": 2, "shoot_id": 1, "overall_score": 50},
            {"evaluation_id": 3, "file_id": 3, "shoot_id": 2, "overall_score": 95},  # best in shoot 2
            {"evaluation_id": 4, "file_id": 4, "shoot_id": 2, "overall_score": 94},
        ]
        out = {r["file_id"]: r for r in calibration.compute_calibration(rows)}
        # file 1 is the top of its (2-file) shoot, but not the top of the library.
        self.assertGreater(out[1]["percentile_shoot"], out[1]["percentile_library"])

    def test_single_file_library_lands_at_the_midpoint(self):
        rows = [{"evaluation_id": 1, "file_id": 1, "shoot_id": 1, "overall_score": 77}]
        out = calibration.compute_calibration(rows)
        self.assertEqual(out[0]["percentile_library"], 50.0)
        self.assertEqual(out[0]["z_score_library"], 0.0)

    def test_tied_scores_split_the_percentile_rather_than_all_claiming_the_top(self):
        rows = [
            {"evaluation_id": i, "file_id": i, "shoot_id": 1, "overall_score": 80}
            for i in range(1, 5)
        ]
        out = calibration.compute_calibration(rows)
        for r in out:
            self.assertEqual(r["percentile_library"], 50.0)

    def test_z_score_sign_matches_above_below_mean(self):
        rows = [
            {"evaluation_id": 1, "file_id": 1, "shoot_id": 1, "overall_score": 50},
            {"evaluation_id": 2, "file_id": 2, "shoot_id": 1, "overall_score": 90},
        ]
        out = {r["file_id"]: r for r in calibration.compute_calibration(rows)}
        self.assertLess(out[1]["z_score_library"], 0)
        self.assertGreater(out[2]["z_score_library"], 0)


if __name__ == "__main__":
    unittest.main()
