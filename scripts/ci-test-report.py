#!/usr/bin/env python3
"""Summarize test logs per suite and per test, and optionally fail on unexpected skips.

Reads `swift test` and `xcodebuild test` console logs (XCTest case lines and Swift Testing
lines) and writes a Markdown report: executed, failed and skipped counts per log, the slowest
suites and the slowest tests. With `--no-skips`, any skipped test not matched by `--allow-skip`
fails the run, and `--require-module` fails it when a named test bundle executed nothing. This
turns a fully skipped suite (which XCTest reports as passed) into a failure.

Swift Testing runs tests concurrently: its suite and test times are elapsed wall time inside that
run and overlap, so they show where time goes but are not additive. XCTest suite times are the
sum of their serial case times.

  ci-test-report.py --log host=test.log [--log ...] [--title T] [--top N] [--summary]
                    [--no-skips] [--allow-skip REGEX ...] [--require-module NAME ...] [--json PATH]

`--summary` appends the report to $GITHUB_STEP_SUMMARY when it is set (stdout otherwise).
"""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import re
import sys

PREFIX = r"^(?:\d{4}-\d\d-\d\dT[\d:.]+Z )?"
XCTEST_CASE = re.compile(
    PREFIX + r"Test Case '-\[(?P<module>[\w.]+)\.(?P<suite>\w+) (?P<name>\w+)\]' "
    r"(?P<result>passed|failed|skipped) \((?P<seconds>[0-9.]+) seconds\)", re.M)
# The result is read at the end of the line, after the complete name: a display name may itself
# contain "passed", "failed" or "skipped" ("Upload is skipped when offline" passed after ...).
SWIFT_TESTING_DONE = re.compile(
    PREFIX + r"[^\x00-\x7f]+ (?P<kind>Test|Suite) (?P<name>.+) (?P<result>passed|failed) after "
    r"(?P<seconds>[0-9.]+) seconds(?: with [^\n]*)?\.?$", re.M)
SWIFT_TESTING_SKIPPED = re.compile(
    PREFIX + r"[^\x00-\x7f]+ (?P<kind>Test|Suite) (?P<name>.+?) skipped(?:\.|: [^\n]*)$", re.M)
SWIFT_TESTING_RUN = re.compile(PREFIX + r"[^\x00-\x7f]+ (?P<line>Test run with \d+ tests? in \d+ suites? .*)$", re.M)
XCTEST_TOTAL = re.compile(PREFIX + r"Test Suite '(?P<bundle>[^']+)\.xctest' (?:passed|failed)", re.M)


def parse(text):
    """Every XCTest case, Swift Testing test and suite result in one console log."""
    cases = [dict(m.groupdict(), framework="XCTest", seconds=float(m["seconds"]))
             for m in XCTEST_CASE.finditer(text)]
    tests, suites = [], []
    found = [(m.start(), m["kind"], m["name"], m["result"], float(m["seconds"]))
             for m in SWIFT_TESTING_DONE.finditer(text)]
    found += [(m.start(), m["kind"], m["name"], "skipped", 0.0) for m in SWIFT_TESTING_SKIPPED.finditer(text)]
    for _, kind, name, result, seconds in sorted(found):
        if name.startswith("run with "):
            continue
        entry = {"framework": "Swift Testing", "name": name.strip(), "result": result, "seconds": seconds}
        (tests if kind == "Test" else suites).append(entry)
    runs = [m["line"].rstrip(".") for m in SWIFT_TESTING_RUN.finditer(text)]
    return {"cases": cases, "tests": tests, "suites": suites, "runs": runs,
            "bundles": sorted({m["bundle"] for m in XCTEST_TOTAL.finditer(text)})}


def counts(entries):
    tally = defaultdict(int)
    for entry in entries:
        tally[entry["result"]] += 1
    return {key: tally[key] for key in ("passed", "failed", "skipped")}


def xctest_suites(cases):
    """Per XCTest class: case counts and the serial sum of case durations."""
    suites = {}
    for case in cases:
        key = case["module"] + "." + case["suite"]
        suite = suites.setdefault(key, {"name": key, "passed": 0, "failed": 0, "skipped": 0, "seconds": 0.0})
        suite[case["result"]] += 1
        suite["seconds"] += case["seconds"]
    return list(suites.values())


def skipped_ids(parsed):
    ids = [f"{c['module']}.{c['suite']}/{c['name']}" for c in parsed["cases"] if c["result"] == "skipped"]
    return ids + [t["name"] for t in parsed["tests"] if t["result"] == "skipped"]


def guard(parsed_logs, no_skips, allow_skip, require_modules):
    """Problems that fail the run: unexpected skips and required bundles that executed nothing."""
    problems = []
    if no_skips:
        allowed = [re.compile(pattern) for pattern in allow_skip]
        for label, parsed in parsed_logs.items():
            unexpected = [i for i in skipped_ids(parsed) if not any(a.search(i) for a in allowed)]
            if unexpected:
                problems.append(f"{label}: {len(unexpected)} unexpected skipped tests: " + ", ".join(unexpected[:20])
                                + (" ..." if len(unexpected) > 20 else ""))
    for module in require_modules:
        executed = sum(1 for parsed in parsed_logs.values() for c in parsed["cases"]
                       if c["module"] == module and c["result"] != "skipped")
        if not executed:
            problems.append(f"{module}: no test case executed")
    return problems


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(str(cell) for cell in row) + " |" for row in rows]
    return "\n".join(lines)


def report(parsed_logs, title, top):
    out = [f"## {title}", ""]
    rows = []
    for label, parsed in parsed_logs.items():
        x, s = counts(parsed["cases"]), counts(parsed["tests"])
        rows.append([label, f"{x['passed']}/{x['failed']}/{x['skipped']}", f"{s['passed']}/{s['failed']}/{s['skipped']}",
                     "<br>".join(parsed["runs"]) or "-"])
    out += [table(["Log", "XCTest passed/failed/skipped", "Swift Testing passed/failed/skipped", "Swift Testing run"],
                  rows), ""]
    xsuites = [dict(s, log=label) for label, p in parsed_logs.items() for s in xctest_suites(p["cases"])]
    if xsuites:
        xsuites.sort(key=lambda s: -s["seconds"])
        out += [f"### Slowest XCTest suites (serial sum of case times; top {top} of {len(xsuites)})", "",
                table(["Suite", "Log", "Seconds", "Passed", "Failed", "Skipped"],
                      [[s["name"], s["log"], f"{s['seconds']:.3f}", s["passed"], s["failed"], s["skipped"]]
                       for s in xsuites[:top]]), ""]
    ssuites = [dict(s, log=label) for label, p in parsed_logs.items() for s in p["suites"]]
    if ssuites:
        ssuites.sort(key=lambda s: -s["seconds"])
        out += [f"### Slowest Swift Testing suites (elapsed in a concurrent run, not additive; top {top} of "
                f"{len(ssuites)})", "",
                table(["Suite", "Log", "Elapsed seconds", "Result"],
                      [[s["name"], s["log"], f"{s['seconds']:.3f}", s["result"]] for s in ssuites[:top]]), ""]
    tests = [dict(t, log=label, name=f"{t['module']}.{t['suite']}/{t['name']}") for label, p in parsed_logs.items()
             for t in p["cases"]] + [dict(t, log=label) for label, p in parsed_logs.items() for t in p["tests"]]
    if tests:
        tests.sort(key=lambda t: -t["seconds"])
        out += [f"### Slowest tests (top {top} of {len(tests)})", "",
                table(["Test", "Framework", "Log", "Seconds", "Result"],
                      [[t["name"].replace("|", "\\|"), t["framework"], t["log"], f"{t['seconds']:.3f}", t["result"]]
                       for t in tests[:top]]), ""]
    return "\n".join(out) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", action="append", required=True, metavar="LABEL=PATH")
    parser.add_argument("--title", default="Test timing")
    parser.add_argument("--top", type=int, default=15)
    parser.add_argument("--summary", action="store_true", help="append to $GITHUB_STEP_SUMMARY when set")
    parser.add_argument("--no-skips", action="store_true", help="fail on a skipped test not matched by --allow-skip")
    parser.add_argument("--allow-skip", action="append", default=[], metavar="REGEX")
    parser.add_argument("--require-module", action="append", default=[], metavar="NAME",
                        help="fail when this XCTest module executed no case")
    parser.add_argument("--json", type=Path, help="also write the parsed results here")
    args = parser.parse_args(argv)
    parsed_logs = {}
    for item in args.log:
        label, _, path = item.partition("=")
        if not path:
            label, path = Path(item).name, item
        log = Path(path)
        # A missing log is a failure of the step that should have written it, reported there.
        parsed_logs[label] = parse(log.read_text(errors="replace")) if log.is_file() else parse("")
    text = report(parsed_logs, args.title, args.top)
    problems = guard(parsed_logs, args.no_skips, args.allow_skip, args.require_module)
    if problems:
        text += "\n" + "\n".join(f"- **Guard:** {p}" for p in problems) + "\n"
    summary = os.environ.get("GITHUB_STEP_SUMMARY") if args.summary else None
    if summary:
        with open(summary, "a") as handle:
            handle.write(text)
    print(text)
    if args.json:
        args.json.write_text(json.dumps(parsed_logs, indent=1) + "\n")
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
