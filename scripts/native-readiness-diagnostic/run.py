#!/usr/bin/env python3
"""Temporary hosted observation of the original native still-readiness tests."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import time


METHODS = (
    "aStillGetsTheVideoTapsBundleOnTheDeclaredCeiling",
    "aStillBeforeTheTapIsDueIsDropped",
    "theNextDueStillIsAcceptedAfterAnEarlyStillIsDropped",
)
SUITE = "MonitorAssistEngineStillTests"
TEST = Path("Tests/OpenCineAppleTests/MonitorAssistEngineStillTests.swift")
ORIGINAL = "082b4d4b294ec3da8689ac19f8489adbd309da49fe1c5c61b82768dfb12f7a4b"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def selection(text, methods):
    """Count actual Swift Testing starts and outcomes, including failed assertions."""
    names = "|".join(re.escape(name) for name in METHODS)
    starts = re.findall(rf"Test ({names})\(\) started", text)
    passed = re.findall(rf"Test ({names})\(\) passed after", text)
    failed = re.findall(rf"Test ({names})\(\) failed after", text)
    summaries = re.findall(r"[✔✘] Test run with (\d+) tests? in (\d+) suites? (passed|failed)", text)
    expected = sorted(methods)
    valid = (
        sorted(starts) == expected
        and sorted(passed + failed) == expected
        and len(summaries) == 1
        and int(summaries[0][0]) == len(methods)
        and int(summaries[0][1]) == 1
    )
    return {
        "expected": list(methods), "starts": starts, "passed": passed,
        "failed": failed, "summaries": summaries, "selection_valid": valid,
        "testing_versions": re.findall(r"Testing Library Version: ([^\n]+)", text),
        "phase_lines": sum(line.startswith(("PHASE ", "TEST_PHASE ")) for line in text.splitlines()),
        "hooks_ready_7": bool(re.search(r"event=hooks_ready\b[^\n]*value=7\b", text)),
    }


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--output", type=Path, required=True)
    output = args.parse_args().output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    assets = Path(__file__).resolve().parent
    root = assets.parents[1]
    os.chdir(root)
    deadline = time.monotonic() + 2350
    manifest = json.loads((assets / "source-manifest.json").read_text())
    receipt = {
        "purpose": "Diagnostic observation only; no mitigation or CI waiver",
        "source_manifest": manifest, "commands": [], "cases": [],
        "order_confounders": [
            "One hosted machine and its driver/disk caches are shared across fresh processes",
            "Original controls precede instrumentation; tracing adds work and swizzles",
            "No unrelated full-package test invocation precedes the first control",
            "Rotating bounded trace order does not establish cold-start causality",
        ],
        "phase_limits": [
            "Observed native hooks are Objective-C render and expectation fulfillment",
            "Wait and barrier timings come from the test-only trace patch",
            "Late-loaded dispatch and Metal-device interposes are not active",
            "hooks_ready7 validates setup, not invocation of every installed hook",
            "No raw queue-admission, GPU-backend or cold-start cause is established",
        ],
    }

    def save():
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")

    def command(label, argv, seconds, required=True, finalizing=False):
        remaining = int(deadline - time.monotonic())
        if remaining <= 1 and not finalizing:
            raise TimeoutError("whole diagnostic deadline reached")
        bound = seconds if finalizing else min(seconds, remaining)
        wrapped = ["perl", "-e", "alarm shift; exec @ARGV", str(bound), *argv]
        log = output / (label + ".log")
        row = {"label": label, "argv": argv, "timeout_seconds": bound,
               "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "order": len(receipt["commands"]), "load_average": os.getloadavg()}
        started = time.monotonic()
        with log.open("w") as stream:
            process = subprocess.Popen(wrapped, stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=bound + 2)
            except BaseException:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
                raise
            if code < 0:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    cleanup_deadline = time.monotonic() + 2
                    while time.monotonic() < cleanup_deadline:
                        os.killpg(process.pid, 0)
                        time.sleep(0.05)
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        row.update(exit=code, elapsed_seconds=time.monotonic() - started,
                   log=log.name)
        receipt["commands"].append(row)
        save()
        text = log.read_text(errors="replace")
        if required and code:
            raise RuntimeError(f"{label} exited {code}; see retained raw log")
        return code, text

    def hashes():
        return {row["path"]: sha((root / row["path"]).read_bytes())
                for row in manifest["paths"]}

    def cases(mode, round_number, order):
        for name in order:
            methods = METHODS if name == SUITE else (name,)
            selector = SUITE if name == SUITE else SUITE + "." + name
            label = f"{mode}-{round_number}-{name}"
            code, text = command(label, ["swift", "test", "--skip-build", "-Xswiftc",
                                        "-strict-concurrency=complete", "--filter", selector],
                                 30, required=False)
            row = selection(text, methods)
            row.update(mode=mode, round=round_number, selector=selector, exit=code,
                       log=label + ".log")
            receipt["cases"].append(row)
            save()

    original = (root / TEST).read_bytes()
    patched = None
    try:
        assert sha(original) == ORIGINAL, "original test preimage differs"
        receipt["source_before"] = hashes()
        assert all(receipt["source_before"][row["path"]] == row["sha256"]
                   for row in manifest["paths"]), "native source differs from failure"
        assert sha((assets / "Trace.m").read_bytes()) == manifest["trace_m_sha256"]
        (output / "original-test-preimage.swift").write_bytes(original)
        receipt["environment"] = {key: os.environ.get(key) for key in (
            "ImageOS", "ImageVersion", "RUNNER_OS", "RUNNER_ARCH", "GITHUB_SHA",
            "GITHUB_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "DEVELOPER_DIR",
            "CACHE_HIT", "CACHE_MATCHED_KEY", "CACHE_PRIMARY_KEY")}
        receipt["architecture"] = platform.machine()
        for label, argv in (
            ("git-head", ["git", "show", "-s", "--format=fuller", "HEAD"]),
            ("xcode-version", ["xcodebuild", "-version"]),
            ("swift-version", ["swift", "--version"]),
            ("sdk-version", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
            ("os-version", ["sw_vers"]),
            ("hardware", ["sysctl", "hw.model", "hw.machine", "hw.ncpu", "hw.memsize"]),
        ):
            command(label, argv, 15)
        command("product-source-diff-before", ["git", "diff", "--exit-code", "--", "Sources"], 15)
        command("original-build-strict", ["swift", "build", "--build-tests", "-Xswiftc",
                                           "-strict-concurrency=complete"], 1200)
        cases("original", 0, (SUITE, *METHODS))
        _, developer = command("developer-directory", ["xcode-select", "-p"], 15)
        frameworks = str(Path(developer.strip()) / "Platforms/MacOSX.platform/Developer/Library/Frameworks")
        library = output.parent / "native-readiness-library" / "libStillPhaseTrace.dylib"
        library.parent.mkdir(exist_ok=True)
        command("build-trace-library", [
            "xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-fblocks", "-target",
            platform.machine() + "-apple-macosx14.0", "-F", frameworks,
            "-framework", "Foundation", "-framework", "CoreImage", "-framework", "CoreVideo",
            "-framework", "Metal", "-framework", "XCTest", "-Wl,-rpath," + frameworks,
            "-install_name", "@rpath/libStillPhaseTrace.dylib", str(assets / "Trace.m"),
            "-o", str(library)], 60)
        patch = (assets / "test-trace.patch").read_text()
        assert patch.count("__OPENCINE_READINESS_TRACE_DYLIB__") == 1
        applied = patch.replace("__OPENCINE_READINESS_TRACE_DYLIB__", str(library))
        (output / "applied-test-trace.patch").write_text(applied)
        command("check-trace-patch", ["git", "apply", "--check",
                                      str(output / "applied-test-trace.patch")], 15)
        command("apply-trace-patch", ["git", "apply", str(output / "applied-test-trace.patch")], 15)
        patched = (root / TEST).read_bytes()
        assert patched.count(b"timeout: 0.3") == original.count(b"timeout: 0.3") == 1
        assertions = lambda data: [line.strip() for line in data.decode().splitlines()
                                   if "#expect" in line or "#require" in line]
        assert assertions(patched) == assertions(original), "original assertion lines changed"
        receipt["instrumented_test_sha256"] = sha(patched)
        (output / "instrumented-test.swift").write_bytes(patched)
        command("traced-build-strict", ["swift", "build", "--build-tests", "-Xswiftc",
                                        "-strict-concurrency=complete"], 480)
        for round_number, order in enumerate((
            (SUITE, *METHODS),
            (METHODS[1], METHODS[2], METHODS[0], SUITE),
            (METHODS[2], SUITE, METHODS[0], METHODS[1]),
        ), 1):
            cases("traced", round_number, order)
        receipt["all_selections_valid"] = all(row["selection_valid"] for row in receipt["cases"])
        receipt["all_hooks_valid"] = all(row["hooks_ready_7"] for row in receipt["cases"]
                                        if row["mode"] == "traced")
        receipt["setup_incompatibilities"] = [row["log"] for row in receipt["cases"]
                                               if row["mode"] == "traced" and not row["hooks_ready_7"]]
        receipt["original_assertion_failures"] = [row["log"] for row in receipt["cases"] if row["failed"]]
        receipt["actual_case_starts"] = sum(len(row["starts"]) for row in receipt["cases"])
        receipt["diagnostic_complete"] = (len(receipt["cases"]) == 16 and receipt["actual_case_starts"] == 24
                                          and receipt["all_selections_valid"] and receipt["all_hooks_valid"])
    except Exception as error:
        receipt["error"] = str(error)
        receipt["diagnostic_complete"] = False
    finally:
        current = (root / TEST).read_bytes()
        if current == original or (patched is not None and current == patched):
            (root / TEST).write_bytes(original)
        else:
            receipt["restoration_error"] = "unexpected test bytes retained rather than overwritten"
        receipt["source_after"] = hashes()
        receipt["source_restored"] = all(receipt["source_after"][row["path"]] == row["sha256"]
                                         for row in manifest["paths"])
        try:
            code, _ = command("product-source-diff-after", ["git", "diff", "--exit-code", "--", "Sources"],
                              15, required=False, finalizing=True)
            receipt["all_product_sources_unchanged"] = code == 0
        except Exception as error:
            receipt["source_diff_error"] = str(error)
            receipt["all_product_sources_unchanged"] = False
        receipt["instrumented_cache_saved"] = False
        save()
    return 0 if (receipt.get("diagnostic_complete") and receipt["source_restored"]
                 and receipt["all_product_sources_unchanged"]
                 and all(row["exit"] == 0 and not row["failed"] for row in receipt["cases"])) else 1


if __name__ == "__main__":
    def interrupted(number, _frame):
        raise InterruptedError(f"diagnostic interrupted by signal {number}")
    for number in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT):
        signal.signal(number, interrupted)
    raise SystemExit(main())
