"""Measure auto-selection precision on a labeled camera-image evaluation set.

Input JSONL rows contain sceneKey, categoryKey (Swift raw values), confidence,
margin, candidateCorrect, cropSafe, trackingStable, and baselineCorrect.
The actual photographs stay outside this script. A group needs >=50 examples,
>=95% observed precision and a >=90% Wilson lower bound before auto-selection.
"""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


def calibrate(rows: list[dict]) -> tuple[dict[str, float], dict[str, dict]]:
    def wilson_lower(correct: int, total: int) -> float:
        z = 1.96
        p = correct / total
        z2 = z * z
        return (p + z2 / (2 * total) - z *
                ((p * (1 - p) + z2 / (4 * total)) / total) ** 0.5) / (1 + z2 / total)

    groups: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        groups[row["sceneKey"] + "|" + row["categoryKey"]].append(row)
    thresholds: dict[str, float] = {}
    report: dict[str, dict] = {}
    for key, examples in groups.items():
        baseline = sum(bool(r["baselineCorrect"]) for r in examples) / len(examples)
        best = None
        if len(examples) >= 50:
            for threshold in (0.72, 0.78, 0.84, 0.90, 0.95, 0.98):
                admitted = [r for r in examples
                            if float(r["confidence"]) >= threshold
                            and float(r["margin"]) >= 1.35]
                if len(admitted) < 30:
                    continue
                correct = sum(bool(r["candidateCorrect"]) and
                              bool(r["cropSafe"]) and bool(r["trackingStable"])
                              for r in admitted)
                precision = correct / len(admitted)
                lower = wilson_lower(correct, len(admitted))
                if precision >= 0.95 and lower >= 0.90:
                    best = {"threshold": threshold, "precision": precision,
                            "wilsonLower95": lower, "admitted": len(admitted)}
                    break
        if best:
            thresholds[key] = best["threshold"]
        report[key] = {"examples": len(examples), "baselineAccuracy": baseline,
                       "autoSelection": best}
    return thresholds, report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--output", type=Path,
                        default=Path("AISmartFramingCamera/Resources/LocalAutoselectThresholds.json"))
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.dataset.read_text(encoding="utf-8").splitlines()
            if line.strip()]
    if not rows:
        raise SystemExit("Evaluation set is empty; auto-selection remains disabled")
    thresholds, report = calibrate(rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(thresholds, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
