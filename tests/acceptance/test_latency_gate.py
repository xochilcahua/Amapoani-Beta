import unittest

from latency_gate import evaluate


class TestLatencyGate(unittest.TestCase):
    def test_nearest_rank_and_inclusive_limit(self):
        ids = [str(i) for i in range(20)]
        measurements = [{"id": sample, "elapsed_ms": int(sample)} for sample in reversed(ids)]
        result = evaluate(ids, 18, measurements)
        self.assertEqual(result["p95_ms"], 18)
        self.assertTrue(result["passed"])
        self.assertFalse(evaluate(ids, 17, measurements)["passed"])

    def test_a_timeout_fails_even_when_p95_is_within_budget(self):
        ids = [str(i) for i in range(20)]
        measurements = [{"id": sample, "elapsed_ms": 10} for sample in ids[:-1]]
        measurements.append({"id": ids[-1], "elapsed_ms": None})
        result = evaluate(ids, 100, measurements)
        self.assertEqual(result["p95_ms"], 10)
        self.assertEqual(result["timeouts"], [ids[-1]])
        self.assertFalse(result["passed"])

    def test_unbounded_p95_is_reported_without_a_fake_duration(self):
        result = evaluate(["one"], 100, [{"id": "one", "elapsed_ms": None}])
        self.assertIsNone(result["p95_ms"])
        self.assertFalse(result["passed"])

    def test_missing_duplicate_and_invalid_measurements_are_errors(self):
        with self.assertRaisesRegex(ValueError, "Missing"):
            evaluate(["one"], 100, [])
        duplicated = [{"id": "one", "elapsed_ms": 1}] * 2
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            evaluate(["one"], 100, duplicated)
        for value in (float("nan"), float("inf"), False, -1):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "finite, nonnegative"):
                    evaluate(["one"], 100, [{"id": "one", "elapsed_ms": value}])


if __name__ == "__main__":
    unittest.main()
