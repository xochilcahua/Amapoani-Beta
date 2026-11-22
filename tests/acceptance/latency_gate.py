"""Score externally observed timings against a scheduled p95 gate."""

import argparse
import json
import math
import sys
from pathlib import Path


def evaluate(expected_ids, limit_ms, measurements):
    if not expected_ids or len(expected_ids) != len(set(expected_ids)):
        raise ValueError("The sample schedule must contain unique IDs")
    validate_ms(limit_ms)
    expected = set(expected_ids)
    observed = set()
    durations = []
    timeouts = []
    for measurement in measurements:
        sample_id = measurement["id"]
        if sample_id in observed:
            raise ValueError(f"Duplicate measurement: {sample_id}")
        observed.add(sample_id)
        elapsed = measurement["elapsed_ms"]
        if elapsed is None:
            timeouts.append(sample_id)
        else:
            validate_ms(elapsed)
            durations.append(elapsed)

    if expected != observed:
        missing = sorted(expected - observed)
        unexpected = sorted(observed - expected)
        raise ValueError(f"Timing sample coverage differs. Missing {missing}. Unexpected {unexpected}.")

    # A timeout participates as an unbounded duration, so it sorts above every sample.
    rank = (95 * len(expected_ids) + 99) // 100
    p95 = sorted(durations)[rank - 1] if rank <= len(durations) else None
    return {
        "samples": len(expected_ids),
        "p95_ms": p95,
        "limit_ms": limit_ms,
        "timeouts": sorted(timeouts),
        "passed": not timeouts and p95 is not None and p95 <= limit_ms,
    }


def validate_ms(value):
    if type(value) not in (int, float) or value < 0:
        raise ValueError("A duration must be a finite, nonnegative number of milliseconds")
    if type(value) is float and not math.isfinite(value):
        raise ValueError("A duration must be a finite, nonnegative number of milliseconds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schedule", type=Path)
    parser.add_argument("measurements", type=Path)
    args = parser.parse_args()
    try:
        schedule = json.loads(args.schedule.read_text(encoding="utf-8"))
        measurements = json.loads(args.measurements.read_text(encoding="utf-8"))
        result = evaluate(schedule["sample_ids"], schedule["limit_ms"], measurements)
    except (KeyError, TypeError, ValueError, OSError) as error:
        parser.exit(2, f"{error}\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
