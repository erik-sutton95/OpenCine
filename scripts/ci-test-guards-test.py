#!/usr/bin/env python3
"""Regression checks for the test-result guards; no Xcode, simulator or Swift toolchain needed.

A suite whose every case skips is reported as passed by XCTest. Nightly 40383997585 (2026-10-26)
ran all 33 portrait header clearance cases that way: each waited 30 s for an application scene,
then skipped. These checks pin that both guards reject such a run.
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
HEADER = load("header_clearance_hosted", "ios-header-clearance-hosted-test.py")
SOURCE = ROOT / "Tests/MonitorUITests/MonitorPortraitHeaderClearanceTests.swift"

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

    def test_a_skip_reason_inside_a_display_name_is_not_a_skip(self):
        parsed = REPORT.parse('✔ Test "Tests skipped: offline mode" passed after 0.100 seconds.\n'
                              '➜ Test "Upload skipped: no network" skipped: "needs a server"\n')
        self.assertEqual([(t["name"], t["result"]) for t in parsed["tests"]],
                         [('"Tests skipped: offline mode"', "passed"), ('"Upload skipped: no network"', "skipped")])

    def test_a_skip_comment_over_several_lines_fails_the_skip_guard(self):
        # Swift Testing prints a comment's line breaks as they are (swift test, 2026-10-30).
        log = ('◇ Test "Upload skipped: "x"" started.\n'
               '➜ Test multi() skipped: "first line\n'
               'second line"\n'
               '✔ Test "Upload skipped: "x"" passed after 0.001 seconds.\n'
               '✔ Test run with 2 tests in 0 suites passed after 0.001 seconds.\n')
        parsed = REPORT.parse(log)
        self.assertEqual([(t["name"], t["result"]) for t in parsed["tests"]],
                         [("multi()", "skipped"), ('"Upload skipped: "x""', "passed")])
        self.assertEqual(REPORT.guard({"host": parsed}, True, [], []),
                         ["host: 1 unexpected skipped tests: multi()"])

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


class HeaderClearanceRunnerTests(unittest.TestCase):
    def test_every_source_case_is_classified_once(self):
        groups = HEADER.classify(HEADER.source_cases(SOURCE))
        self.assertEqual(len(groups["phone"]) + len(groups["tablet"]), HEADER.EXPECTED_CASES)
        self.assertFalse(set(groups["phone"]) & set(groups["tablet"]))

    def test_an_added_or_removed_case_must_be_classified(self):
        names = HEADER.source_cases(SOURCE)
        with self.assertRaises(SystemExit):
            HEADER.classify(names + ["testNewCase"])
        with self.assertRaises(SystemExit):
            HEADER.classify([name for name in names if name != HEADER.TABLET_CASES[0]])

    def test_the_old_skip_fails_the_runner_verdict(self):
        names = ["testCodecSpaceControlsDecideTheRecordedR3DNEArtifact"]
        log = SKIPPED_NIGHTLY.replace("MonitorUITests.MonitorPortraitHeaderClearanceTests",
                                      "HeaderClearanceHostedTests.MonitorPortraitHeaderClearanceTests")
        verdict = HEADER.verdict(HEADER.outcomes(log, names))
        self.assertEqual((verdict["executed"], verdict["skipped"]), (0, 1))
        self.assertEqual(verdict["unexpected"], {names[0]: ["skipped"]})

    def test_a_missing_or_repeated_case_fails_the_runner_verdict(self):
        name = "testCodecSpaceControlsDecideTheRecordedR3DNEArtifact"
        line = f"Test Case '-[HeaderClearanceHostedTests.MonitorPortraitHeaderClearanceTests {name}]' passed (1.0 seconds).\n"
        self.assertEqual(HEADER.verdict(HEADER.outcomes("", [name]))["unexpected"], {name: []})
        self.assertEqual(HEADER.verdict(HEADER.outcomes(line * 2, [name]))["unexpected"], {name: ["passed", "passed"]})
        self.assertEqual(HEADER.verdict(HEADER.outcomes(line, [name]))["unexpected"], {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
