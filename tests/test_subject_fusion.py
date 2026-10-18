"""Test fusion-evaluation accounting with explicitly synthetic unit fixtures."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from validate_subject_fusion import evaluate_fusion


class SubjectFusionEvaluationTests(unittest.TestCase):
    def truth(self) -> dict:
        return {"images": [{"id": 1, "file_name": "1.jpg", "width": 100, "height": 100}],
                "annotations": [{"id": 1, "image_id": 1, "category_id": 1,
                                 "bbox": [20, 20, 40, 40], "iscrowd": 0}],
                "annotationSHA256": "synthetic-unit-fixture"}

    def candidate(self, group: str, box: list[float], *, is_group: bool = False) -> dict:
        return {"evaluationGroup": group, "box": box, "confidence": 0.9,
                "isGroup": is_group, "label": "synthetic " + group}

    def native(self, *candidates: dict) -> dict:
        return {"model": "synthetic-unit-fixture", "records": [{"file": "1.jpg", "imageID": 1,
                "candidates": list(candidates), "hero": candidates[0] if candidates else None}]}

    def test_faces_and_group_union_are_excluded_while_body_member_is_counted(self) -> None:
        native = self.native(self.candidate("people", [0.1, 0.1, 0.8, 0.8], is_group=True),
                             self.candidate("faces", [0.3, 0.2, 0.1, 0.1]),
                             self.candidate("people", [0.2, 0.2, 0.4, 0.4]))
        report = evaluate_fusion(self.truth(), native, "synthetic-unit-fixture")
        people = report["metrics"]["groups"]["people"]
        self.assertEqual(people["predictions"], 1)
        self.assertEqual(people["truePositives"], 1)
        self.assertEqual(people["falsePositives"], 0)
        self.assertEqual(len(report["records"][0]["candidates"]), 3)
        self.assertTrue(report["records"][0]["hero"]["isGroup"])

    def test_animal_species_are_collapsed_without_claiming_species_accuracy(self) -> None:
        truth = self.truth()
        truth["annotations"] = [
            {"id": 1, "image_id": 1, "category_id": 17, "bbox": [10, 10, 20, 20], "iscrowd": 0},
            {"id": 2, "image_id": 1, "category_id": 18, "bbox": [60, 60, 20, 20], "iscrowd": 0}]
        native = self.native(self.candidate("animals", [0.1, 0.1, 0.2, 0.2]),
                             self.candidate("animals", [0.6, 0.6, 0.2, 0.2]))
        report = evaluate_fusion(truth, native, "synthetic-unit-fixture")
        animals = report["metrics"]["groups"]["animals"]
        self.assertEqual(animals["groundTruth"], 2)
        self.assertEqual(animals["truePositives"], 2)
        self.assertEqual(animals["falseNegatives"], 0)
        self.assertIn("all COCO animal species collapsed", report["metrics"]["perClass"]["17"]["name"])

    def test_duplicate_source_cannot_replace_a_missing_frozen_image(self) -> None:
        truth = self.truth()
        truth["images"].append({"id": 2, "file_name": "2.jpg", "width": 100, "height": 100})
        native = self.native(self.candidate("people", [0.2, 0.2, 0.4, 0.4]))
        native["records"].append(native["records"][0])
        with self.assertRaisesRegex(RuntimeError, "every frozen source exactly once"):
            evaluate_fusion(truth, native, "synthetic-unit-fixture")

    def test_gt_does_not_manufacture_or_correct_an_expected_hero(self) -> None:
        for native in (self.native(), self.native(self.candidate("animals", [0.2, 0.2, 0.4, 0.4]))):
            with self.subTest(hero=native["records"][0]["hero"]):
                observed = native["records"][0]["hero"]
                report = evaluate_fusion(self.truth(), native, "synthetic-unit-fixture")
                row = report["records"][0]
                self.assertEqual(row["hero"], observed)
                self.assertFalse(row["heroIsPhotographicGroundTruth"])
                self.assertNotIn("expectedHero", row)
                self.assertEqual(report["metrics"]["groups"]["people"]["falseNegatives"], 1)
                if observed is not None:
                    self.assertEqual(report["metrics"]["groups"]["animals"]["falsePositives"], 1)
                    self.assertAlmostEqual(row["heroIndividualGTOverlaps"][0]["IoU"], 1)


if __name__ == "__main__":
    unittest.main()
