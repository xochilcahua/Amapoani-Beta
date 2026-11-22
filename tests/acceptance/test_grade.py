import json
import tempfile
import unittest
from pathlib import Path

from grade import digest, grade, verify


class TestBlindGrade(unittest.TestCase):
    def row(self, case, score=10, status="observed", hard=True):
        return dict(id=case, score=score, status=status, hard_checks_passed=hard,
                    evidence="Observed fixture outcome", feedback="Case has a failed step")

    def test_each_score_must_meet_floor(self):
        cases = [{"id": "a"}, {"id": "b"}]
        self.assertTrue(grade(cases, [self.row("a", 8.5), self.row("b")])["passed"])
        self.assertEqual(grade(cases, [self.row("a", 8.4), self.row("b")])["failed"], ["a"])

    def test_blocked_hard_failure_and_missing_block_acceptance(self):
        cases = [{"id": c} for c in ("a", "b", "c")]
        result = grade(cases, [self.row("a", status="blocked"), self.row("b", hard=False)])
        self.assertEqual(result["failed"], ["a", "b"])
        self.assertEqual(result["missing"], ["c"])

    def test_duplicate_and_unexplained_failed_case_are_rejected(self):
        cases = [{"id": "a"}]
        with self.assertRaisesRegex(ValueError, "duplicate"):
            grade(cases, [self.row("a"), self.row("a")])
        row = self.row("a", 0)
        row["feedback"] = ""
        with self.assertRaisesRegex(ValueError, "require feedback"):
            grade(cases, [row])

    def test_digest_detects_modified_manifest_and_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            case = root / "case.txt"
            case.write_text("expected", encoding="utf-8")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({case.name: digest(case)}), encoding="utf-8")
            expected = digest(manifest)
            verify(root, expected)
            case.write_text("edited", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "file changed"):
                verify(root, expected)
            manifest.write_text(json.dumps({case.name: digest(case)}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Manifest differs"):
                verify(root, expected)


if __name__ == "__main__":
    unittest.main()
