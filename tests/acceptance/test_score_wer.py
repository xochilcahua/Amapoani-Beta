import json
import tempfile
import unittest
from pathlib import Path

from score_wer import edit_distance, read_records, score, words


class TestWordErrorRate(unittest.TestCase):
    def test_normalization_preserves_words_and_numbers(self):
        self.assertEqual(words("L’AMI, NIN\u0303O—5.  'Fine'"), ["l'ami", "niño", "5", "fine"])
        self.assertNotEqual(words("five"), words("5"))

    def test_edit_operations_and_empty_output(self):
        self.assertEqual(edit_distance(["a", "b"], ["a", "c", "d"]), 2)
        self.assertEqual(edit_distance(["a", "b"], ["a"]), 1)
        self.assertEqual(edit_distance(["a", "b"], []), 2)
        self.assertEqual(edit_distance(["a"], ["a", "a", "a"]), 2)

    def test_totals_use_reference_words_and_disclose_each_condition(self):
        references = {
            "one": {"condition": "clean", "text": "One word"},
            "two": {"condition": "noise", "text": "one two three four"},
        }
        hypotheses = {"one": {"text": "One Word."}, "two": {"text": "one two"}}
        result = score(references, hypotheses)
        self.assertEqual(result["overall"], {"errors": 2, "reference_words": 6, "wer": 1 / 3})
        self.assertEqual(result["conditions"]["noise"]["wer"], 0.5)
        self.assertEqual(result["conditions"]["clean"]["wer"], 0)

    def test_missing_and_unexpected_specimens_fail(self):
        references = {"required": {"condition": "clean", "text": "one"}}
        with self.assertRaisesRegex(ValueError, "missing=.*required.*unexpected=.*extra"):
            score(references, {"extra": {"text": "one"}})

    def test_duplicate_ids_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.jsonl"
            row = json.dumps({"id": "duplicate", "text": "sample"})
            path.write_text(f"{row}\n{row}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate ID"):
                read_records(path)

    def test_silence_does_not_disappear_into_aggregate(self):
        with self.assertRaisesRegex(ValueError, "score silence separately"):
            score({"silence": {"condition": "noise", "text": ""}}, {"silence": {"text": "one"}})


if __name__ == "__main__":
    unittest.main()
