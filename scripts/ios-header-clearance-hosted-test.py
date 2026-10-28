#!/usr/bin/env python3
"""Run every portrait header clearance case in a developer-only SIMULATED iOS app.

`MonitorPortraitHeaderClearanceTests` renders the shared native header in a real foreground
`UIWindowScene`. A package test bundle has no application scene, so there every case waited for
one and skipped (33 skips, about 16.5 minutes, in each nightly until 2026-10-28). This runner
builds a throwaway application host once, then runs the phone cases on the caller's private
iPhone and the tablet witnesses on the caller's private native 2x iPad.

Every case named in the source is classified as phone or tablet here, and every selected case
must run exactly once and pass: a skipped, failed, missing or unclassified case fails the run.
The test source, its assertions and the package are never changed.

Run through the caller's heavy-job wrapper with an outer wall-clock timeout. The caller owns
the private simulators, accessibility setup and DerivedData. The generated application has no
camera, network, telemetry or saved app data.
"""
import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
from uuid import UUID

EXPECTED_CASES = 33
# The cases that prove a tablet canvas: each skips (or, for the 2x storage oracle, fails) on a
# phone by design. They run on a private native 2x iPad; every other case runs on the iPhone.
TABLET_CASES = [
    "testLowSafeTopPortraitTargetsStayInsideViewportWithoutMovingPictureOrTelemetry",
    "testProductionCompactTabletTelemetryUsesOccupiedNativeBounds",
    "testOriginalPaddingOnlyCounterexampleNowMeetsNativeClearance",
    "testCompactDeclaredGaugesKeepFullFontAndOccupiedClearance",
    "testCompactDeclaredGaugeRetainsClearanceWhenSafeTopChanges",
    "testProductionCompactTabletTogglePreservesOriginalStorageAndFPSGlyphs",
]
SUITE = "MonitorPortraitHeaderClearanceTests"
HOST = "HeaderClearanceSimulated"
TARGET = "HeaderClearanceHostedTests"
OUTCOME = re.compile(
    r"Test Case '-\[\S+\.(?P<suite>\w+) (?P<name>test\w+)\]' (?P<result>passed|failed|skipped)"
    r"(?: \((?P<seconds>[0-9.]+) seconds\))?")


def source_cases(source: Path) -> list[str]:
    """Every XCTest case the suite's source declares, in source order."""
    return re.findall(r"\bfunc (test\w+)\(", source.read_text())


def classify(names: list[str]) -> dict[str, list[str]]:
    """Split the source cases into the phone and tablet runs; reject drift from this runner."""
    problems = []
    if len(names) != len(set(names)):
        problems.append("duplicate case names in the source")
    if len(names) != EXPECTED_CASES:
        problems.append(f"the source declares {len(names)} cases, this runner expects {EXPECTED_CASES}; "
                        "classify the change in TABLET_CASES and EXPECTED_CASES")
    missing = [name for name in TABLET_CASES if name not in names]
    if missing:
        problems.append(f"tablet cases absent from the source: {missing}")
    if problems:
        raise SystemExit("header clearance inventory changed: " + "; ".join(problems))
    return {"phone": [name for name in names if name not in TABLET_CASES], "tablet": list(TABLET_CASES)}


def outcomes(log: str, names: list[str]) -> dict[str, list[dict]]:
    """Every reported result of each named case in an xcodebuild log."""
    found: dict[str, list[dict]] = {name: [] for name in names}
    for match in OUTCOME.finditer(log):
        if match["suite"] == SUITE and match["name"] in found:
            seconds = float(match["seconds"]) if match["seconds"] else None
            found[match["name"]].append({"result": match["result"], "seconds": seconds})
    return found


def verdict(found: dict[str, list[dict]]) -> dict:
    """Counts and the cases that did not run exactly once and pass."""
    results = [entry["result"] for entries in found.values() for entry in entries]
    unexpected = {name: [entry["result"] for entry in entries]
                  for name, entries in found.items() if [entry["result"] for entry in entries] != ["passed"]}
    return {
        "selected": len(found),
        "executed": sum(1 for result in results if result != "skipped"),
        "passed": results.count("passed"),
        "failed": results.count("failed"),
        "skipped": results.count("skipped"),
        "seconds": round(sum(entry["seconds"] or 0 for entries in found.values() for entry in entries), 3),
        "unexpected": unexpected,
    }


def project_spec(sdk: Path, source: Path, host_source: Path) -> dict:
    products = ["MonitorPresentation", "MonitorUI", "OpenCineAppKit", "OpenCineCameraControls", "OpenCineCore",
                "OpenCineHostedAccessibility", "OpenCineHostedTestSupport", "OpenCineMedia"]
    return {
        "name": HOST,
        "options": {"deploymentTarget": {"iOS": "17.0"}},
        "settings": {"base": {"SWIFT_VERSION": "6.0", "GENERATE_INFOPLIST_FILE": "YES"}},
        "packages": {"OpenCine": {"path": str(sdk)}},
        "targets": {
            HOST: {
                "type": "application", "platform": "iOS", "sources": [str(host_source)],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.opencine.headerclearance.simulated",
                    # A native iPad host: an iPhone-only app would run in compatibility mode.
                    "TARGETED_DEVICE_FAMILY": "1,2",
                    # Dark, like every app host that runs this suite: an unstyled readout paints
                    # the primary label color, white only in dark mode, and the paint oracles
                    # count white ink (testCodecSpaceControlsDecideTheRecordedR3DNEArtifact).
                    "INFOPLIST_KEY_UIUserInterfaceStyle": "Dark",
                    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
                    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                }},
            },
            TARGET: {
                "type": "bundle.unit-test", "platform": "iOS", "sources": [str(source)],
                "dependencies": [{"target": HOST}] + [{"package": "OpenCine", "product": p} for p in products],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.opencine.headerclearance.hostedtests",
                    "TARGETED_DEVICE_FAMILY": "1,2",
                    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/" + HOST + ".app/" + HOST,
                    "BUNDLE_LOADER": "$(TEST_HOST)",
                }},
            },
        },
        "schemes": {HOST: {
            "build": {"targets": {HOST: ["test"], TARGET: ["test"]}},
            "test": {"config": "Debug", "macroExpansion": HOST, "targets": [{"name": TARGET}]},
        }},
    }


def run_logged(command: list[str], log_path: Path) -> tuple[int, float]:
    print(json.dumps({"command": command}), flush=True)
    start = time.monotonic()
    with log_path.open("w") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            log.write(line)
            log.flush()
            print(line, end="", flush=True)
        code = process.wait()
    return code, round(time.monotonic() - start, 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--simulator-id", required=True, help="private iPhone for the phone cases")
    parser.add_argument("--ipad-simulator-id", required=True, help="private native 2x iPad for the tablet cases")
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    UUID(args.simulator_id)
    UUID(args.ipad_simulator_id)
    # Real paths: XcodeGen relativizes sources against the spec directory, which a symlink breaks.
    sdk = Path(__file__).resolve().parents[1]
    source = sdk / "Tests/MonitorUITests/MonitorPortraitHeaderClearanceTests.swift"
    groups = classify(source_cases(source))
    assert shutil.which("xcodegen"), "Use the existing XcodeGen installation; this runner never installs tools"
    inputs = [source, Path(__file__).resolve(), sdk / "Package.swift"]
    before = {str(path): sha256(path.read_bytes()).hexdigest() for path in inputs}
    out = args.output.resolve()
    assert not out.exists(), "Use a fresh owned output directory; keep previous failures"
    out.mkdir(parents=True)
    (out / "input-binding.json").write_text(json.dumps(before, indent=2) + "\n")
    host_source = out / "SimulatedApp.swift"
    host_source.write_text("""import SwiftUI

@main
struct HeaderClearanceSimulatedApp: App {
    var body: some Scene {
        WindowGroup { Text("SIMULATED portrait header clearance test host") }
    }
}
""")
    spec_path = out / "project.json"
    spec_path.write_text(json.dumps(project_spec(sdk, source, host_source), indent=2) + "\n")
    subprocess.run(["xcodegen", "generate", "--spec", str(spec_path), "--project", str(out)], check=True)
    base = ["xcodebuild", "-project", str(out / (HOST + ".xcodeproj")), "-scheme", HOST,
            "-derivedDataPath", str(args.derived_data.resolve())]
    # One build for both simulators (same platform and architecture); each run reuses it.
    code, build_seconds = run_logged(base + [
        "-destination", "platform=iOS Simulator,id=" + args.simulator_id, "-jobs", "4",
        "CODE_SIGNING_ALLOWED=NO", "SWIFT_STRICT_CONCURRENCY=complete", "build-for-testing"], out / "build.log")
    report = {"buildExit": code, "buildSeconds": build_seconds, "runs": {}}
    if code:
        (out / "outcomes.json").write_text(json.dumps(report, indent=2) + "\n")
        raise SystemExit(code)
    destinations = {"phone": args.simulator_id, "tablet": args.ipad_simulator_id}
    for group, names in groups.items():
        selection = ["-only-testing:" + TARGET + "/" + SUITE] if group == "phone" else []
        selection += [("-skip-testing:" if group == "phone" else "-only-testing:") + TARGET + "/" + SUITE + "/" + name
                      for name in TABLET_CASES]
        code, seconds = run_logged(base + [
            "-destination", "platform=iOS Simulator,id=" + destinations[group],
            "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
            "-default-test-execution-time-allowance", "300", "-maximum-test-execution-time-allowance", "600",
            "-collect-test-diagnostics", "never", "-resultBundlePath", str(out / (group + ".xcresult")),
            *selection, "test-without-building"], out / (group + ".log"))
        found = outcomes((out / (group + ".log")).read_text(errors="replace"), names)
        report["runs"][group] = dict(verdict(found), exit=code, wallSeconds=seconds,
                                     destination=destinations[group], cases=found)
    after = {str(path): sha256(path.read_bytes()).hexdigest() for path in inputs}
    runs = report["runs"].values()
    report.update({
        "inputsUnchanged": before == after,
        "expectedCases": EXPECTED_CASES,
        "executed": sum(run["executed"] for run in runs),
        "passed": sum(run["passed"] for run in runs),
        "skipped": sum(run["skipped"] for run in runs),
        "allPassedOnce": all(not run["unexpected"] and not run["exit"] for run in runs),
        "scope": "SIMULATED shared portrait header geometry, paint and accessibility in a real application scene",
    })
    (out / "outcomes.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "runs"}), flush=True)
    for group, run in report["runs"].items():
        print(f"{group}: {run['passed']} of {run['selected']} passed, {run['skipped']} skipped, "
              f"{run['failed']} failed; unexpected {run['unexpected']}", flush=True)
    if not report["allPassedOnce"] or report["passed"] != EXPECTED_CASES or not report["inputsUnchanged"]:
        raise SystemExit("every header clearance case must run once and pass; see outcomes.json")


if __name__ == "__main__":
    main()
