import unittest
import json
import tempfile
from pathlib import Path
from analyze import edit_distance, words, percentile, summarize
from aligned_latency import measure
from text_metrics import technical_tokens, recognizes_tail

class MeasurementTests(unittest.TestCase):
    def test_word_error_rate_counts_insert_delete_and_substitute(self):
        self.assertEqual(edit_distance(['one', 'two', 'three'], ['one', 'four', 'five', 'six']), 3)
        self.assertEqual(words("API, don't pre-annotate."), ['api', "don't", 'pre', 'annotate'])

    def test_late_revision_does_not_rewrite_first_correct_latency(self):
        corpus = [{'id': 'f', 'sourceStart': 100, 'words': [
            {'text': 'hello', 'end': 100.4}, {'text': 'world', 'end': 100.6}]}]
        rows = [{'event': 'partial', 'fixture': 'f', 'sourceEnd': end, 'fixtureEnd': end,
                 'wallElapsed': wall, 'text': text} for end, wall, text in [
                    (.8, 1.0, 'hello world'), (1., 1.2, 'hello there'), (1.2, 1.4, 'hello world')]]
        result = measure(rows, corpus)
        self.assertEqual(result['coverage'], 1)
        self.assertAlmostEqual(result['firstCorrectWordLatencyP50Seconds'], .4)
        self.assertAlmostEqual(result['firstCorrectWordLatencyP95Seconds'], .6)
        self.assertAlmostEqual(result['stableCorrectWordLatencyP50Seconds'], .8)
        self.assertAlmostEqual(result['stableCorrectWordLatencyP95Seconds'], 1.)

    def test_reference_future_words_do_not_hide_lookahead(self):
        corpus = [{'id': 'f', 'sourceStart': 0, 'words': [
            {'text': 'yes', 'end': 2}, {'text': 'please', 'end': 2.2}]}]
        rows = [{'event': 'partial', 'fixture': 'f', 'sourceEnd': 1, 'fixtureEnd': 1,
                 'wallElapsed': 1.1, 'text': 'yes please'}]
        result = measure(rows, corpus)
        self.assertEqual(result['matchedWords'], 0)
        self.assertIsNone(result['firstCorrectWordLatencyP50Seconds'])

    def test_nearest_rank_small_sample(self):
        self.assertEqual(percentile([.1, .2, .9], .95), .9)

    def test_annotation_acronyms_preserve_case_and_compound_question_tails(self):
        self.assertEqual(technical_tokens('X_M_L_ and X. M. L. and xml'),['XML','and','XML','and','xml'])
        self.assertTrue(recognizes_tail('Some work is happening offline.','stuff that is happening off-line'))
        self.assertFalse(recognizes_tail('We should delete it','We should not delete the database'))

    def test_one_source_ending_does_not_mark_dual_run_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'run.jsonl'
            rows=[{'event':'load','engine':'test','source':'localUser','seconds':0},
                  {'event':'load','engine':'test','source':'systemAudio','seconds':0},
                  {'event':'end','engine':'test','source':'localUser'}]
            path.write_text('\n'.join(map(json.dumps,rows)))
            self.assertFalse(summarize(path)['complete'])

if __name__ == '__main__': unittest.main()
