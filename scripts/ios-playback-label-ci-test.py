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
        self.assertEqual(default, 360)
        self.assertEqual(maximum, 360)
        # The parent's native wall (2400 s) must still end any hang first.
        self.assertLess(maximum, 2400)
        self.assertEqual(command[command.index('-test-timeouts-enabled') + 1], 'YES')

    def test_driver_requests_no_screenshot(self):
        # Hosted XCUIApplication.screenshot() hangs for minutes (40143225461, 40149233094 after a
        # qualified case). In 40195791463 its timeout was the only issue XCTest reported for a
        # failed case and hid the readiness error.
        source = (ROOT / 'scripts/ios-playback-label-native-system-dismissal/NativeCancelUITests.swift').read_text()
        self.assertNotIn('app.screenshot(', source)
        self.assertNotIn('XCTAttachment(screenshot:', source)
        self.assertIn('"stage": stage', source, 'a failed outcome names the wait that missed')

    def test_readiness_clock_starts_at_the_delivered_delete_callback(self):
        # 40195791463: the Delete tap returned at 41 s and the app recorded its capture at 159 s,
        # after the thirty-second readiness clock (started when tap() returned) had expired.
        source = (ROOT / 'scripts/ios-playback-label-native-system-dismissal/NativeCancelUITests.swift').read_text()
        body = source.split('    func testCapturedDeletionConfirmation', 1)[1].split('    private func ', 1)[0]
        tap = body.index('delete.tap()')
        delivered = body.index('value.captureRequestIDs == [initial.requestID]', tap)
        required = body.index('try require(\n            delivered,', delivered)
        clock = body.index('let readinessClock = ContinuousClock()')
        self.assertLess(tap, delivered)
        self.assertLess(required, clock, 'readiness starts only after the app-authored capture')
        # The delivery wait reads the receipt file only; no automation query competes with it.
        wait = body[body.index('HostedCondition.wait(limit: .seconds(150))', tap):required]
        self.assertNotIn('app.', wait)
        self.assertNotIn('windowReady', wait)
        # The thirty-second readiness deadline itself is unchanged.
        self.assertIn('readinessStart.advanced(by: .seconds(30))', body)

    def test_driver_reuses_the_accepted_dismissal_coordinate(self):
        # Each external walk takes about 9 s on a hosted runner. 40166387934 held readiness, then
        # a third walk for the same coordinate ran past the thirty-second deadline.
        source = (ROOT / 'scripts/ios-playback-label-native-system-dismissal/NativeCancelUITests.swift').read_text()
        body = source.split('    func testCapturedDeletionConfirmation', 1)[1].split('    private func ', 1)[0]
        self.assertEqual(body.count('dismissalCoordinate('), 1, 'one walk per readiness observation, no recompute')
        self.assertIn('readyCoordinate = stable ? observed : nil', body, 'bind only the accepted observation')
        self.assertIn('try XCTUnwrap(readyCoordinate)', body)


if __name__ == '__main__':
    unittest.main(verbosity=2)
