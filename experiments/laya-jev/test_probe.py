"""Check scoring semantics independently of a live model/provider."""
import unittest
from probe import evaluate, summary


class EvaluationChecks(unittest.TestCase):
    def test_noul_uses_probability_not_provider_confidence(self):
        result = evaluate({"type": "noul"}, {"type": "noul", "noul": .1, "confidence": .99}, False)
        self.assertTrue(result["correct"])
        self.assertAlmostEqual(result["top_probability"], .9)
        self.assertAlmostEqual(result["brier"], .01)

    def test_score_uses_modal_level_and_reports_expected_value_error(self):
        result = evaluate({"type": "score", "criteria": ["low", "medium", "high"]},
                          {"type": "score", "score": .96, "probabilities": {"0": .40, "1": .24, "2": .36}}, 0)
        self.assertTrue(result["correct"])
        self.assertAlmostEqual(result["absolute_error"], .96)

    def test_invalid_distribution_is_an_error(self):
        with self.assertRaises(ValueError):
            evaluate({"type": "choice", "criteria": {"a": "", "b": ""}},
                     {"type": "choice", "choice": "a", "probabilities": {"a": .8, "b": .8}}, "a")
        with self.assertRaises(ValueError):
            evaluate({"type": "noul"}, {"type": "noul", "noul": float("nan")}, True)

    def test_stress_cases_do_not_inflate_short_input_accuracy(self):
        def row(task, correct, latency):
            return {"task": task, "language": "en", "response": {}, "latency_ms": latency,
                    "decisions": {"a": {"correct": correct, "top_probability": .99}}}
        result = summary([row("triage", False, 10), row("stress", True, 1000)])
        self.assertEqual((result["correct"], result["decisions"]), (0, 1))
        self.assertEqual(result["median_request_ms"], 10)
        self.assertEqual(result["wrong_at_90pct"], 1)


if __name__ == "__main__":
    unittest.main()
