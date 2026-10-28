#!/usr/bin/env python3
"""Regression checks for the test-result guards; no Xcode, simulator or Swift toolchain needed.

A suite whose every case skips is reported as passed by XCTest. Nightly 40383997585 (2026-10-26)
ran all 33 portrait header clearance cases that way: each waited 30 s for an application scene,
then skipped. These checks pin that the report's skip guard rejects such a run.
"""
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REPORT = load("ci_test_report", "ci-test-report.py")

SKIPPED_NIGHTLY = """\
2026-10-26T19:22:55.4502440Z Test Case '-[MonitorUITests.MonitorPortraitHeaderClearanceTests testCodecSpaceControlsDecideTheRecordedR3DNEArtifact]' started.
2026-10-26T19:23:25.5866030Z Test Case '-[MonitorUITests.MonitorPortraitHeaderClearanceTests testCodecSpaceControlsDecideTheRecordedR3DNEArtifact]' skipped (30.138 seconds).
2026-10-26T19:23:25.6093720Z Test Case '-[MonitorUITests.MonitorIconTests testIconsRender]' passed (0.010 seconds).
2026-10-26T19:39:26.8669250Z \t Executed 33 tests, with 33 tests skipped and 0 failures (0 unexpected) in 990.710 (990.773) seconds
2026-10-26T19:39:42.0353710Z Test Suite 'MonitorUITests.xctest' passed at 2026-10-26 19:39:41.956.
"""
SWIFT_TESTING = """\
◇ Test run started.
✔ Test attemptsThatNeverShowAPictureStopAtTheTotalBudget() passed after 22.817 seconds.
➔ Test realMimoExportsIfPresent() skipped.
➜ Test "11. Session owners receive only their own native events" skipped: "N/A for CORE-01"
✘ Test brokenThing() failed after 0.002 seconds with 1 issue.
✔ Test "Upload is skipped when offline" passed after 0.250 seconds.
✔ Test "Retry failed after a timeout" passed after 1.500 seconds with 1 known issue.
✔ Suite "Session recovery episode" passed after 22.876 seconds.
✔ Test run with 4 tests in 1 suite passed after 22.900 seconds.
Test Case '-[OpenCineAppKitTests.ReliabilityReportingTests testUpload]' passed (0.500 seconds).
"""


class ReportTests(unittest.TestCase):
    def test_a_fully_skipped_suite_fails_the_skip_guard(self):
        parsed = {"kit": REPORT.parse(SKIPPED_NIGHTLY)}
        problems = REPORT.guard(parsed, True, [], ["MonitorUITests"])
        self.assertEqual(len(problems), 1)
        self.assertIn("MonitorPortraitHeaderClearanceTests/testCodecSpaceControlsDecideTheRecordedR3DNEArtifact",
                      problems[0])

    def test_only_an_allowed_skip_passes(self):
        parsed = {"kit": REPORT.parse(SKIPPED_NIGHTLY)}
        self.assertEqual(REPORT.guard(parsed, True, [r"MonitorPortraitHeaderClearanceTests/"], ["MonitorUITests"]), [])

    def test_a_required_module_that_executed_nothing_fails(self):
        parsed = {"kit": REPORT.parse(SKIPPED_NIGHTLY)}
        problems = REPORT.guard(parsed, False, [], ["OpenCineHostedAccessibilityTests"])
        self.assertEqual(problems, ["OpenCineHostedAccessibilityTests: no test case executed"])

    def test_a_module_whose_every_case_skipped_executed_nothing(self):
        only_skips = "\n".join(line for line in SKIPPED_NIGHTLY.splitlines() if "MonitorIconTests" not in line)
        problems = REPORT.guard({"kit": REPORT.parse(only_skips)}, False, [], ["MonitorUITests"])
        self.assertEqual(problems, ["MonitorUITests: no test case executed"])

    def test_swift_testing_and_xctest_lines_are_counted_separately(self):
        parsed = REPORT.parse(SWIFT_TESTING)
        self.assertEqual(REPORT.counts(parsed["tests"]), {"passed": 3, "failed": 1, "skipped": 2})
        self.assertEqual(REPORT.counts(parsed["cases"]), {"passed": 1, "failed": 0, "skipped": 0})
        self.assertEqual([s["name"] for s in parsed["suites"]], ['"Session recovery episode"'])
        self.assertEqual(parsed["runs"], ["Test run with 4 tests in 1 suite passed after 22.900 seconds"])

    def test_a_result_word_inside_a_display_name_is_part_of_the_name(self):
        tests = {t["name"]: t for t in REPORT.parse(SWIFT_TESTING)["tests"]}
        self.assertEqual(tests['"Upload is skipped when offline"'], {
            "framework": "Swift Testing", "name": '"Upload is skipped when offline"', "result": "passed",
            "seconds": 0.25})
        self.assertEqual(tests['"Retry failed after a timeout"']["result"], "passed")
        self.assertEqual(tests['"Retry failed after a timeout"']["seconds"], 1.5)
        self.assertEqual(tests['"11. Session owners receive only their own native events"']["result"], "skipped")
        self.assertEqual(REPORT.guard({"host": REPORT.parse(SWIFT_TESTING)}, True,
                                      [r"realMimo", r"Session owners"], []), [])

    def test_xctest_case_lines_are_not_read_as_swift_testing_lines(self):
        parsed = REPORT.parse(SKIPPED_NIGHTLY)
        self.assertEqual(parsed["tests"], [])
        self.assertEqual(REPORT.counts(parsed["cases"]), {"passed": 1, "failed": 0, "skipped": 1})

    def test_the_command_fails_and_reports_the_guard(self):
        with tempfile.TemporaryDirectory() as scratch:
            log = Path(scratch) / "kit.log"
            log.write_text(SKIPPED_NIGHTLY)
            output = io.StringIO()
            with redirect_stdout(output):
                code = REPORT.main(["--log", f"kit={log}", "--no-skips", "--require-module", "MonitorUITests"])
        self.assertEqual(code, 1)
        self.assertIn("::error::kit: 1 unexpected skipped tests", output.getvalue())
        self.assertIn("MonitorUITests.MonitorPortraitHeaderClearanceTests", output.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
