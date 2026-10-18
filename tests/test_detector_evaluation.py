"""Check labelled-evaluation semantics independently of any model prediction."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from evaluate_detector_coco import evaluate, overlap


class DetectorEvaluationTests(unittest.TestCase):
    def truth(self, *, crowd: bool = False, small: bool = False) -> dict:
        return {"images": [{"id": 1, "file_name": "1.jpg", "width": 100, "height": 100}],
                "categories": [{"id": 1, "name": "person"}, {"id": 17, "name": "cat"}],
                "annotations": [{"id": 1, "image_id": 1, "category_id": 1,
                                 "bbox": [20, 20, 2 if small else 40, 40], "iscrowd": int(crowd)}]}

    def predictions(self, *items: tuple[int, float, list[float]]) -> dict:
        return {"records": [{"file": "1.jpg", "detections": [
            {"classID": category, "confidence": score, "box": box} for category, score, box in items]}]}

    def test_perfect_box_has_full_precision_recall_and_ap(self) -> None:
        scores = evaluate(self.truth(), self.predictions((1, 0.9, [0.2, 0.2, 0.4, 0.4])), False)
        self.assertEqual(scores["groups"]["people"]["AP50_retainedPredictions"], 1)
        self.assertEqual(scores["groups"]["people"]["precision"], 1)
        self.assertEqual(scores["groups"]["people"]["recall"], 1)

    def test_duplicate_is_a_false_positive(self) -> None:
        box = [0.2, 0.2, 0.4, 0.4]
        scores = evaluate(self.truth(), self.predictions((1, 0.9, box), (1, 0.8, box)), False)
        self.assertEqual(scores["groups"]["people"]["truePositives"], 1)
        self.assertEqual(scores["groups"]["people"]["falsePositives"], 1)

    def test_matching_is_class_aware(self) -> None:
        scores = evaluate(self.truth(), self.predictions((17, 0.9, [0.2, 0.2, 0.4, 0.4])), False)
        self.assertEqual(scores["groups"]["people"]["falseNegatives"], 1)
        self.assertEqual(scores["groups"]["animals"]["falsePositives"], 1)

    def test_higher_confidence_false_positive_reduces_interpolated_ap(self) -> None:
        scores = evaluate(self.truth(), self.predictions((1, 0.99, [0.7, 0.7, 0.2, 0.2]),
                                                         (1, 0.8, [0.2, 0.2, 0.4, 0.4])), False)
        self.assertEqual(scores["groups"]["people"]["AP50_retainedPredictions"], 0.5)

    def test_crowd_uses_intersection_over_prediction_area(self) -> None:
        self.assertAlmostEqual(overlap([0.3, 0.3, 0.1, 0.1], [0.2, 0.2, 0.4, 0.4], crowd=True), 1)
        truth = self.truth(crowd=True)
        # Include one regular annotation so macro AP remains defined.
        truth["annotations"].append({"id": 2, "image_id": 1, "category_id": 17,
                                     "bbox": [70, 70, 20, 20], "iscrowd": 0})
        scores = evaluate(truth, self.predictions((1, 0.9, [0.3, 0.3, 0.1, 0.1])), False)
        self.assertEqual(scores["ignoredPredictions"], 1)
        self.assertEqual(scores["groups"]["people"]["falsePositives"], 0)

    def test_small_boxes_remain_false_negatives_in_all_box_report(self) -> None:
        scores = evaluate(self.truth(small=True), self.predictions(), False)
        self.assertEqual(scores["groups"]["people"]["falseNegatives"], 1)

    def test_missing_source_is_rejected(self) -> None:
        with self.assertRaises(RuntimeError):
            evaluate(self.truth(), {"records": []}, False)

    def test_duplicate_source_record_is_rejected(self) -> None:
        predictions = self.predictions((1, 0.9, [0.2, 0.2, 0.4, 0.4]))
        predictions["records"].append(predictions["records"][0])
        with self.assertRaisesRegex(RuntimeError, "Duplicate"):
            evaluate(self.truth(), predictions, False)

    def test_size_ignored_noncrowd_cannot_absorb_duplicate_predictions(self) -> None:
        truth = self.truth()
        truth["annotations"][0]["bbox"] = [2, 20, 96, 40]
        box = [0.02, 0.2, 0.95, 0.4]
        scores = evaluate(truth, self.predictions((1, 0.9, box), (1, 0.8, box)), True)
        self.assertEqual(scores["ignoredPredictions"], 1)
        self.assertEqual(scores["groups"]["people"]["groundTruth"], 0)
        self.assertEqual(scores["groups"]["people"]["falsePositives"], 1)

    def test_crowd_can_absorb_multiple_predictions(self) -> None:
        scores = evaluate(self.truth(crowd=True), self.predictions(
            (1, 0.9, [0.25, 0.25, 0.1, 0.1]), (1, 0.8, [0.4, 0.4, 0.1, 0.1])), False)
        self.assertEqual(scores["ignoredPredictions"], 2)
        self.assertEqual(scores["groups"]["people"]["falsePositives"], 0)

    def test_regular_match_has_priority_over_better_overlapping_crowd(self) -> None:
        truth = self.truth()
        truth["annotations"].append({"id": 2, "image_id": 1, "category_id": 1,
                                     "bbox": [10, 10, 60, 60], "iscrowd": 1})
        box = [0.25, 0.25, 0.3, 0.3]
        self.assertGreater(overlap(box, [0.1, 0.1, 0.6, 0.6], crowd=True),
                           overlap(box, [0.2, 0.2, 0.4, 0.4]))
        scores = evaluate(truth, self.predictions((1, 0.9, box)), False)
        self.assertEqual(scores["ignoredPredictions"], 0)
        self.assertEqual(scores["groups"]["people"]["truePositives"], 1)
        self.assertEqual(scores["matching"][0]["matchedAnnotation"], 1)

    def test_group_ap_explicitly_reports_pooled_aggregation(self) -> None:
        scores = evaluate(self.truth(), self.predictions((1, 0.9, [0.2, 0.2, 0.4, 0.4])), False)
        self.assertIn("Pooled/micro", scores["groupAPAggregation"])
        self.assertIn("not the mean of per-class AP", scores["groupAPAggregation"])


if __name__ == "__main__":
    unittest.main()
