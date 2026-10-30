#!/usr/bin/env python3
"""Regression checks for the Gradle task timing report; no Gradle or Android SDK needed."""
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("gradle_task_timing_report", ROOT / "scripts/gradle-task-timing-report.py")
REPORT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(REPORT)

TIMING = """\
:core:compileKotlin\t4000\texecuted\t1000\t5000
:media:compileKotlin\t3000\texecuted\t1000\t4000
:media:compileDebugKotlin\t500\tup-to-date\t5000\t5500
:core:test\t2000\texecuted\t5000\t7000
:core:compileJava\t0\tskipped\t5000\t5000
:vulkan:lintAnalyzeDebug\t1500\tfailed\t6000\t7500
malformed line
"""


class GradleTaskTimingReportTests(unittest.TestCase):
    def test_outcomes_span_and_work_by_task_type(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "timing.tsv"
            path.write_text(TIMING)
            summary = REPORT.summarize(REPORT.read(path))
        self.assertEqual(summary["outcomes"], {"executed": 3, "up-to-date": 1, "skipped": 1, "failed": 1})
        self.assertEqual(summary["spanMs"], 6500)
        self.assertEqual(summary["workedMs"], 10500)
        self.assertEqual(summary["byType"]["compileKotlin"], {"ms": 7000, "count": 2})
        self.assertNotIn("compileDebugKotlin", summary["byType"])

    def test_task_inventory_is_written_sorted_and_unique(self):
        with tempfile.TemporaryDirectory() as scratch:
            path, tasks = Path(scratch) / "timing.tsv", Path(scratch) / "tasks.txt"
            path.write_text(TIMING + TIMING)
            with redirect_stdout(io.StringIO()):
                self.assertEqual(REPORT.main([str(path), "--tasks", str(tasks)]), 0)
            self.assertEqual(tasks.read_text().splitlines(), sorted({line.split("\t")[0] for line in
                                                                     TIMING.splitlines() if "\t" in line}))

    def test_a_missing_timing_file_reports_no_tasks(self):
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(REPORT.main(["/nonexistent/timing.tsv"]), 0)
        self.assertIn("0 tasks (no tasks)", output.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
