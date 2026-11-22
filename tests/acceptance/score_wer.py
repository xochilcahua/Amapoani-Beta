#!/usr/bin/env python3
"""Score externally transcribed utterances. The reference controls the denominator."""

import argparse
import json
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path


def words(value):
    normalized = unicodedata.normalize("NFC", value).casefold().replace("’", "'")
    normalized = "".join(
        " " if char != "'" and unicodedata.category(char)[0] in "PS" else char
        for char in normalized
    )
    return [word.strip("'") for word in normalized.split() if word.strip("'")]


def edit_distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for index, expected in enumerate(reference, 1):
        current = [index]
        for column, observed in enumerate(hypothesis, 1):
            current.append(min(
                previous[column] + 1,
                current[column - 1] + 1,
                previous[column - 1] + (expected != observed),
            ))
        previous = current
    return previous[-1]


def score(references, hypotheses):
    if not references or references.keys() != hypotheses.keys():
        missing = sorted(references.keys() - hypotheses.keys())
        unexpected = sorted(hypotheses.keys() - references.keys())
        raise ValueError(f"Expected exact case coverage; missing={missing}, unexpected={unexpected}")

    groups = defaultdict(lambda: [0, 0])
    totals = [0, 0]
    for case, reference in references.items():
        expected = words(reference["text"])
        if not expected:
            raise ValueError(f"{case}: score silence separately from WER")
        observed = words(hypotheses[case]["text"])
        errors = edit_distance(expected, observed)
        for counts in (totals, groups[reference["condition"]]):
            counts[0] += errors
            counts[1] += len(expected)

    def summarize(counts):
        errors, count = counts
        return {"errors": errors, "reference_words": count, "wer": errors / count}

    return {
        "overall": summarize(totals),
        "conditions": {name: summarize(counts) for name, counts in sorted(groups.items())},
    }


def read_records(path):
    records = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        case = record["id"]
        if case in records:
            raise ValueError(f"{path}: duplicate ID {case}")
        records[case] = record
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("references", type=Path)
    parser.add_argument("hypotheses", type=Path)
    args = parser.parse_args()
    try:
        report = score(read_records(args.references), read_records(args.hypotheses))
    except (KeyError, TypeError, ValueError, OSError) as error:
        parser.exit(2, f"{error}\n")
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
