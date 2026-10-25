#!/usr/bin/env python3
"""Regression checks for the portable native playback CI entry; no Xcode or simulator needed.

The hosted runner is several times slower than a developer Mac (nightly 40143225461: a 38 s app
launch, a 26 s interruption check, an evidence screenshot that never returned while the automatic
screen recording never finalized). The case's own thirty-second deadlines stay in the driver;
these checks pin the budget and capture settings around it.
"""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load_ci():
    spec = importlib.util.spec_from_file_location('playback_label_ci', ROOT / 'scripts/ios-playback-label-ci.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PlaybackLabelCITests(unittest.TestCase):
    def setUp(self):
        self.ci = load_ci()
        self.legacy = self.ci.load_legacy(ROOT)
        self.out = Path(tempfile.gettempdir()) / 'playback-label-ci-test'

    def test_scheme_records_no_automatic_screen_capture(self):
        spec = self.ci.project_spec(ROOT, self.out, '00000000-0000-4000-8000-000000000000', '0' * 64)
        test = spec['schemes'][self.legacy.SYSTEM_SCHEME]['test']
        self.assertIs(test.get('captureScreenshotsAutomatically'), False)
        self.assertEqual(test.get('preferredScreenCaptureFormat'), 'screenshots')

    def test_execution_allowance_covers_a_slow_hosted_case(self):
        command = self.ci.native_command(self.legacy, self.out, '00000000-0000-4000-8000-000000000000')
        def value(flag):
            return int(command[command.index(flag) + 1])
        # 40143225461 reached settlement at 101 s and needed teardown evidence after it.
        default = value('-default-test-execution-time-allowance')
        maximum = value('-maximum-test-execution-time-allowance')
        self.assertGreaterEqual(default, 300)
        self.assertGreaterEqual(maximum, default)
        # The parent's native wall (2400 s) must still end any hang first.
        self.assertLess(maximum, 2400)
        self.assertEqual(command[command.index('-test-timeouts-enabled') + 1], 'YES')


if __name__ == '__main__':
    unittest.main(verbosity=2)
