"""Run with: python -m unittest discover -s eval"""

import unittest

from metrics import align, basic_normalize, percentile, score


class AlignTests(unittest.TestCase):
    def test_identical(self):
        s = score("Run the tests now.", "run the tests now", use_whisper_normalizer=False)
        self.assertEqual((s.substitutions, s.deletions, s.insertions), (0, 0, 0))
        self.assertEqual(s.wer, 0)

    def test_dropped_word(self):
        s = score("please run all the tests", "please run the tests", use_whisper_normalizer=False)
        self.assertEqual(s.deletions, 1)
        self.assertEqual([o.ref for o in s.ops if o.kind == "del"], ["all"])
        self.assertAlmostEqual(s.wer, 0.2)

    def test_invented_word(self):
        s = score("fix the bug", "fix the bug thank you", use_whisper_normalizer=False)
        self.assertEqual(s.insertions, 2)
        self.assertEqual([o.hyp for o in s.ops if o.kind == "ins"], ["thank", "you"])

    def test_substitution(self):
        s = score("deploy to kubernetes", "deploy to cooper netties", use_whisper_normalizer=False)
        self.assertEqual(s.errors, 2)
        self.assertEqual(s.ref_words, 3)

    def test_empty_reference_counts_insertions(self):
        s = score("", "thank you for watching", use_whisper_normalizer=False)
        self.assertEqual(s.insertions, 4)
        self.assertIsNone(s.wer)

    def test_empty_hypothesis(self):
        s = score("hello there", "", use_whisper_normalizer=False)
        self.assertEqual(s.deletions, 2)
        self.assertEqual(s.wer, 1.0)

    def test_alignment_order(self):
        ops = align(["a", "b", "c"], ["a", "x", "c", "d"])
        self.assertEqual([o.kind for o in ops], ["equal", "sub", "equal", "ins"])


class CompoundTests(unittest.TestCase):
    def test_split_in_hypothesis(self):
        s = score("send it before the standup", "send it before the stand up", use_whisper_normalizer=False)
        self.assertEqual(s.errors, 0)

    def test_split_in_reference(self):
        s = score("add a log line", "add a logline", use_whisper_normalizer=False)
        self.assertEqual(s.errors, 0)

    def test_three_way_split(self):
        s = score("the oomkilled error", "the o om killed error", use_whisper_normalizer=False)
        self.assertEqual(s.errors, 0)

    def test_real_errors_still_count(self):
        s = score("the pod keeps crashing", "the port keeps crashing", use_whisper_normalizer=False)
        self.assertEqual(s.substitutions, 1)

    def test_strict_mode(self):
        s = score("the standup", "the stand up", use_whisper_normalizer=False, compounds=False)
        self.assertEqual(s.errors, 2)


class HelperTests(unittest.TestCase):
    def test_basic_normalize(self):
        self.assertEqual(basic_normalize("Don’t  STOP—now!"), "don't stop now")

    def test_percentile(self):
        self.assertEqual(percentile([1, 2, 3, 4, 5], 0.5), 3)
        self.assertAlmostEqual(percentile([0, 10], 0.9), 9)
        self.assertIsNone(percentile([], 0.5))


if __name__ == "__main__":
    unittest.main()
