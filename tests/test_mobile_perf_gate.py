import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from mobile_perf_gate import metrics, studio_replay


class MobilePerfGateTests(unittest.TestCase):
    def test_play_never_runs_a_probe(self):
        class PlayingStudio:
            def tool(self, name, args):
                self.assert_state(name)
                return {'content': [{'text': '- Current Studio Mode: Play'}]}

            @staticmethod
            def assert_state(name):
                if name != 'get_studio_state':
                    raise AssertionError('A playing Studio must receive no probe or mutation')

        result = studio_replay(PlayingStudio(), 'Heavenly', 'assigned-studio', {})
        self.assertEqual(result['status'], 'skipped-user-play-or-unavailable')

    def test_tail_budget_cannot_pass_on_a_fast_mean(self):
        frames = []
        for ms in [1] * 18 + [4] * 2:
            frames.append(dict(phase='gameplay', totalMs=ms, submissionMs=ms,
                               activeGuiNodes=1, parkedGuiNodes=0, propertyWrites=1,
                               heapDeltaKB=0, activeSheets=1, decodedRGBA8Bytes=4096,
                               geometrySubmissions=0))
        result = metrics({'frames': frames})['gameplay']
        self.assertLess(result['hostMs']['mean'] * 5, 16.67)
        self.assertFalse(result['estimates']['budgetPhone']['cpu60fpsPass'])
        self.assertEqual(result['estimates']['budgetPhone']['p95Ms'], 20)


if __name__ == '__main__':
    unittest.main()
