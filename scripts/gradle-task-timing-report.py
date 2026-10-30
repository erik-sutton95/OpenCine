#!/usr/bin/env python3
"""Summarize the per-task timing that scripts/gradle-task-timing.init.gradle records.

  gradle-task-timing-report.py TIMING.tsv [--title T] [--top N] [--summary] [--tasks PATH]

Writes Markdown: tasks per outcome, the build's wall span, the summed execution time of each task
type across modules (compileDebugKotlin, lintAnalyzeDebug, ...) and the slowest single tasks.
Gradle runs tasks in parallel, so summed task time exceeds the wall span; it shows where work goes,
not the critical path. `--tasks` also writes the sorted task paths, so two runs (one job against
several) can be compared for the same executed inventory. `--summary` appends the report to
$GITHUB_STEP_SUMMARY when it is set (stdout otherwise). A missing file reports no tasks.
"""
import argparse
from collections import defaultdict
import os
from pathlib import Path
import sys


def read(path):
    rows = []
    if not path.is_file():
        return rows
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) != 5:
            continue
        task, millis, outcome, start, end = parts
        rows.append({"task": task, "ms": int(millis), "outcome": outcome, "start": int(start), "end": int(end)})
    return rows


def summarize(rows):
    outcomes = defaultdict(int)
    by_type = defaultdict(lambda: {"ms": 0, "count": 0})
    for row in rows:
        outcomes[row["outcome"]] += 1
        if row["outcome"] in ("executed", "failed"):
            kind = by_type[row["task"].rsplit(":", 1)[-1]]
            kind["ms"] += row["ms"]
            kind["count"] += 1
    span = (max(r["end"] for r in rows) - min(r["start"] for r in rows)) if rows else 0
    worked = sum(r["ms"] for r in rows if r["outcome"] in ("executed", "failed"))
    return {"outcomes": dict(outcomes), "spanMs": span, "workedMs": worked, "byType": dict(by_type)}


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    return "\n".join(lines + ["| " + " | ".join(str(cell) for cell in row) + " |" for row in rows])


def report(rows, title, top):
    summary = summarize(rows)
    outcomes = ", ".join(f"{count} {name}" for name, count in sorted(summary["outcomes"].items())) or "no tasks"
    out = [f"## {title}", "",
           f"{len(rows)} tasks ({outcomes}); wall span {summary['spanMs'] / 1000:.1f} s, "
           f"summed execution {summary['workedMs'] / 1000:.1f} s (parallel tasks overlap).", ""]
    kinds = sorted(summary["byType"].items(), key=lambda item: -item[1]["ms"])
    if kinds:
        out += [f"### Executed time by task type (top {top} of {len(kinds)})", "",
                table(["Task type", "Tasks", "Summed seconds"],
                      [[name, kind["count"], f"{kind['ms'] / 1000:.1f}"] for name, kind in kinds[:top]]), ""]
    slowest = sorted((r for r in rows if r["outcome"] in ("executed", "failed")), key=lambda r: -r["ms"])
    if slowest:
        out += [f"### Slowest tasks (top {top})", "",
                table(["Task", "Seconds", "Outcome"],
                      [[r["task"], f"{r['ms'] / 1000:.1f}", r["outcome"]] for r in slowest[:top]]), ""]
    return "\n".join(out) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("timing", type=Path)
    parser.add_argument("--title", default="Gradle task timing")
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--summary", action="store_true", help="append to $GITHUB_STEP_SUMMARY when set")
    parser.add_argument("--tasks", type=Path, help="also write the sorted task paths here")
    args = parser.parse_args(argv)
    rows = read(args.timing)
    text = report(rows, args.title, args.top)
    summary = os.environ.get("GITHUB_STEP_SUMMARY") if args.summary else None
    if summary:
        with open(summary, "a") as handle:
            handle.write(text)
    print(text)
    if args.tasks:
        args.tasks.write_text("".join(f"{task}\n" for task in sorted({r["task"] for r in rows})))
    return 0


if __name__ == "__main__":
    sys.exit(main())
