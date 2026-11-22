"""Verify the frozen package and enforce an 8.5 floor on every required case."""

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(root, expected_digest):
    manifest = root / "manifest.json"
    if digest(manifest) != expected_digest:
        raise ValueError("Manifest differs from the independently recorded digest")
    entries = json.loads(manifest.read_text(encoding="utf-8"))
    for name, expected in entries.items():
        relative = Path(name)
        location = root / relative
        if relative.is_absolute() or ".." in relative.parts or not location.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"Invalid manifest path {name}")
        if not location.is_file() or digest(location) != expected:
            raise ValueError(f"Frozen file changed or is missing: {name}")
    return entries


def grade(cases, rows):
    required = {row["id"] for row in cases if row.get("required", True)}
    if not required:
        raise ValueError("The catalog must require at least one case")
    seen = set()
    failed = []
    for row in rows:
        case = row["id"]
        if case not in required or case in seen:
            raise ValueError(f"Unexpected or duplicate case: {case}")
        seen.add(case)
        status = row["status"]
        score = row["score"]
        if status not in ("observed", "blocked"):
            raise ValueError(f"{case}: invalid status")
        if type(score) not in (int, float) or not 0 <= score <= 10 or not math.isfinite(score):
            raise ValueError(f"{case}: score must be between 0 and 10")
        if type(row["hard_checks_passed"]) is not bool:
            raise ValueError(f"{case}: hard_checks_passed must be a boolean")
        if not isinstance(row["evidence"], str) or not row["evidence"].strip():
            raise ValueError(f"{case}: missing evidence")
        if status != "observed" or score < 8.5 or not row["hard_checks_passed"]:
            if not isinstance(row["feedback"], str) or not row["feedback"].strip():
                raise ValueError(f"{case}: below-threshold or blocked cases require feedback")
            failed.append(case)
    missing = sorted(required - seen)
    return {"passed": not (failed or missing), "required": len(required), "failed": sorted(failed), "missing": missing}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("digest", help="Expected manifest SHA-256 from outside the frozen directory")
    parser.add_argument("results", type=Path, nargs="?")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    try:
        entries = verify(root, args.digest)
        print(f"Verified {len(entries)} frozen files")
        if args.results is None:
            return 0
        cases = json.loads((root / "cases.json").read_text(encoding="utf-8"))
        results = json.loads(args.results.read_text(encoding="utf-8"))
        summary = grade(cases, results)
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0 if summary["passed"] else 1
    except (KeyError, TypeError, ValueError, OSError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
