#!/usr/bin/env python3
"""Check evidence coverage and scores for the AHAMPO live journey contract."""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import sys

FIXTURE_HASH = "ce7371c6e462d1213c17cee0d0d49d59cff3727b4e5a0df854cff7aa26f3fed1"
PRIMARY = ("zen", "safari", "helium")
STOCK = ("firefox", "chrome")
FULL = ("layout", "empty", "fresh-page", "reselect", "textarea", "deselection",
        "wake", "reopen", "transport", "edit-undo")
SPOT = ("fresh-page", "textarea")
UNAVAILABLE = ("empty", "unavailable", "transport", "edit-undo")
MANUAL = ("visual-light", "visual-dark", "accessibility", "explicit-permission",
          "audible-offline", "draft-workflow", "native-textedit", "dictation",
          "playback-navigation", "lifecycle")
DIMENSIONS = ("functionality", "usability", "accessibility", "visual")


def ids():
    for target in PRIMARY + STOCK:
        for case in FULL if target in PRIMARY else SPOT:
            yield f"granted/{target}/{case}"
    for case in UNAVAILABLE:
        yield f"unavailable/{case}"
    yield from MANUAL


def stamp(value):
    if not isinstance(value, str):
        return False
    try:
        return datetime.fromisoformat(value.removesuffix("Z") + ("+00:00" if value.endswith("Z") else "")).tzinfo is not None
    except ValueError:
        return False


def read_json(path):
    with path.open(encoding="utf-8") as doc:
        return json.load(doc)


def template(candidate, sha256):
    return {
        "candidate": candidate, "sha256": sha256, "reviewer": "", "environment": "",
        "cases": [{
            "id": case, "status": "blocked",
            "scores": {dimension: None for dimension in DIMENSIONS},
            "evidence": [{"path": "", "at": "", "observation": ""}],
            "deductions": "",
        } for case in ids()]
    }


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def artifact(item, directory):
    if not isinstance(item, dict) or not stamp(item.get("at")) or not nonempty(item.get("observation")):
        return False
    name = item.get("path")
    if not nonempty(name) or Path(name).is_absolute():
        return False
    path = (directory / name).resolve()
    return path.is_relative_to(directory) and path.is_file() and path.stat().st_size > 0


def score_ok(value):
    return (type(value) in (int, float) and math.isfinite(value)
            and 8.5 <= value <= 10)


def unique(items, key, problems, source):
    result = {}
    if not isinstance(items, list):
        problems.append(f"{source}: expected a list of rows")
        return result
    for item in items:
        if not isinstance(item, dict) or not nonempty(item.get(key)):
            problems.append(f"{source}: invalid row")
            continue
        if item[key] in result:
            problems.append(f"{source}: duplicate row {item[key]}")
        result[item[key]] = item
    return result


def grade(args):
    problems = []
    needed_runs = {
        **{f"granted/{name}": FULL for name in PRIMARY},
        **{f"granted/{name}": SPOT for name in STOCK},
        "unavailable": UNAVAILABLE,
    }
    seen_runs = set()
    for path in args.run:
        run = read_json(path)
        mode = run.get("mode")
        target = run.get("target")
        key = f"granted/{target}" if mode == "granted" else mode
        if key not in needed_runs or target not in PRIMARY + STOCK:
            problems.append(f"{path}: unknown run scope")
            continue
        if key in seen_runs:
            problems.append(f"{path}: duplicate run {key}")
            continue
        seen_runs.add(key)
        if (run.get("candidate") != args.candidate or run.get("sha256") != args.sha
                or run.get("fixtureSHA256") != FIXTURE_HASH):
            problems.append(f"{key}: exact candidate or fixture identity differs")
        pids = [run.get("candidatePID"), run.get("browserPID")]
        if (not stamp(run.get("started")) or any(type(pid) is not int or pid <= 0 for pid in pids)
                or pids[0] == pids[1] or not nonempty(run.get("osVersion"))
                or not nonempty(run.get("browserVersion"))):
            problems.append(f"{key}: incomplete live preflight metadata")
        results = unique(run.get("results"), "id", problems, key)
        expected = ("preflight", *needed_runs[key], "cleanup")
        for case in sorted(set(results).difference(expected)):
            problems.append(f"{key}/{case}: unexpected runner row")
        for case in expected:
            item = results.get(case, {})
            evidence = item.get("evidence")
            if (item.get("status") != "completed" or not isinstance(evidence, list)
                    or not evidence or not all(map(nonempty, evidence))):
                problems.append(f"{key}/{case}: runner did not verify the required observations")
    for key in sorted(set(needed_runs) - seen_runs):
        problems.append(f"{key}: live run missing")

    review = read_json(args.review)
    if (review.get("candidate") != args.candidate or review.get("sha256") != args.sha
            or not nonempty(review.get("reviewer")) or not nonempty(review.get("environment"))):
        problems.append("review: incomplete reviewer, environment or candidate identity")
    reviewed = unique(review.get("cases"), "id", problems, "review")
    evidence_root = args.review.resolve().parent
    for case in sorted(set(reviewed).difference(ids())):
        problems.append(f"{case}: unexpected independent reviewer row")
    for case in ids():
        row = reviewed.get(case, {})
        if row.get("status") != "pass":
            problems.append(f"{case}: reviewer pass missing")
        scores = row.get("scores")
        if not isinstance(scores, dict) or set(scores) != set(DIMENSIONS):
            problems.append(f"{case}: four scores required")
        else:
            for dimension in DIMENSIONS:
                if not score_ok(scores[dimension]):
                    problems.append(f"{case}: {dimension} score must be 8.5 to 10")
            if any(scores[d] != 10 for d in DIMENSIONS) and not nonempty(row.get("deductions")):
                problems.append(f"{case}: explain the scores below 10")
        evidence = row.get("evidence")
        if not isinstance(evidence, list) or not evidence or not all(artifact(item, evidence_root) for item in evidence):
            problems.append(f"{case}: timestamped observations and local evidence required")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=lambda text: str(Path(text).resolve()), required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--template", action="store_true")
    parser.add_argument("--run", type=Path, action="append", default=[])
    parser.add_argument("--review", type=Path)
    args = parser.parse_args()
    if len(args.sha) != 64 or any(character not in "0123456789abcdef" for character in args.sha):
        parser.error("--sha must be the approved lowercase executable SHA-256")
    if args.template:
        print(json.dumps(template(args.candidate, args.sha), indent=2))
        return 0
    if args.review is None:
        parser.error("--review is required for grading")
    try:
        problems = grade(args)
    except (OSError, TypeError, AttributeError, ValueError) as error:
        print(f"Evidence could not be read: {error}", file=sys.stderr)
        return 2
    print(json.dumps({
        "result": "failed" if problems else "passed",
        "required_scored_cases": len(list(ids())),
        "reasons": problems,
    }, indent=2))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
