#!/usr/bin/env python3
"""Run all command-dashboard contracts in a developer-only SIMULATED iOS app.

Run through the caller's heavy-job wrapper with an outer wall-clock timeout.
The caller owns the private simulator, accessibility setup and DerivedData.
The generated application has no camera, network, telemetry or saved app data.
"""
import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
from uuid import UUID

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--simulator-id", required=True)
parser.add_argument("--derived-data", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
UUID(args.simulator_id)
sdk = Path(__file__).resolve().parents[1]
source = sdk / "Tests/MonitorUITests/MonitorCommandDashboardTests.swift"
waiting_source = sdk / "Tests/OpenCineCameraControlsHostedTests/MonitorCommandWaitingPictureTests.swift"
names = [
    "testGridTilesOpenTheirRequestAndReorderThroughTheirKind",
    "testLockedControlsKeepTheGridReorderableButOpenNothing",
    "testLandscapeShowsHealthBesideTheSideColumnAndItsCellsOpen",
    "testPortraitStacksTheGridOverTheSectionsWithoutTheHealthStrip",
    "testOverflowingSideColumnShowsItsCueAndClearsItAtTheRealBottom",
    "testSideColumnWithoutOverflowHasNoCue",
    "testHeroLeadsTheDashboardWithRecordStateAndTimecode",
    "testHeroAndNineTilesStayInsideTheLandscapeFrameWithoutClipping",
]
assert re.findall(r"\bfunc (test\w+)\(", source.read_text()) == names
waiting_names = [
    "testPortraitCommandPaintExcludesWaitingPicture",
    "testLandscapeCommandPaintExcludesWaitingPicture",
    "testLiveAndCleanKeepWaitingPresentationVisible",
    "testTheLockSlotReturnControlUsesTheSharedMultiviewLabel",
    "testModeChangesRetainTheNativePictureOwnerAndReturnItsPaint",
    "testPortraitCommandDropsTheHeaderTimecodeAndKeepsStorageAndLink",
    "testLandscapeCommandDropsTheWholeHeader",
]
assert re.findall(r"\bfunc (test\w+)\(", waiting_source.read_text()) == waiting_names
inputs = [source, waiting_source, Path(__file__).resolve(), sdk / "Package.swift"]
before = {str(path): sha256(path.read_bytes()).hexdigest() for path in inputs}
out = args.output.resolve()
assert not out.exists(), "Use a fresh owned output directory; keep previous failures"
out.mkdir(parents=True)
(out / "input-binding.json").write_text(json.dumps(before, indent=2) + "\n")
host = "CommandDashboardSimulated"
target = "CommandDashboardHostedTests"
host_source = out / "SimulatedApp.swift"
host_source.write_text("""import SwiftUI

@main
struct CommandDashboardSimulatedApp: App {
    var body: some Scene {
        WindowGroup { Text("SIMULATED command dashboard test host") }
    }
}
""")
spec = {
    "name": host,
    "options": {"deploymentTarget": {"iOS": "17.0"}},
    "settings": {"base": {"SWIFT_VERSION": "6.0", "GENERATE_INFOPLIST_FILE": "YES"}},
    "packages": {"OpenCine": {"path": str(sdk)}},
    "targets": {
        host: {
            "type": "application", "platform": "iOS", "sources": [str(host_source)],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.opencine.commanddashboard.simulated",
                "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
                "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
            }},
        },
        target: {
            "type": "bundle.unit-test", "platform": "iOS", "sources": [str(source), str(waiting_source)],
            "dependencies": [{"target": host}] + [
                {"package": "OpenCine", "product": product}
                for product in ["MonitorPresentation", "MonitorUI", "OpenCineHostedAccessibility",
                                "OpenCineAppKit", "OpenCineCameraControls", "OpenCineCore", "OpenCineMedia"]
            ],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.opencine.commanddashboard.hostedtests",
                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/" + host + ".app/" + host,
                "BUNDLE_LOADER": "$(TEST_HOST)",
            }},
        },
    },
    "schemes": {host: {
        "build": {"targets": {host: ["test"], target: ["test"]}},
        "test": {"config": "Debug", "macroExpansion": host, "targets": [{"name": target}]},
    }},
}
spec_path = out / "project.json"
spec_path.write_text(json.dumps(spec, indent=2) + "\n")
subprocess.run(["xcodegen", "generate", "--spec", str(spec_path), "--project", str(out)], check=True)
command = [
    "xcodebuild", "-project", str(out / (host + ".xcodeproj")), "-scheme", host,
    "-destination", "platform=iOS Simulator,id=" + args.simulator_id,
    "-derivedDataPath", str(args.derived_data.resolve()), "-jobs", "4",
    "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
    "-default-test-execution-time-allowance", "60", "-maximum-test-execution-time-allowance", "60",
    "-collect-test-diagnostics", "never", "-resultBundlePath", str(out / "result.xcresult"),
    "CODE_SIGNING_ALLOWED=NO", "SWIFT_STRICT_CONCURRENCY=complete", "test",
]
print(json.dumps({"command": command}), flush=True)
with (out / "xcodebuild.log").open("w") as log:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        log.write(line)
        print(line, end="", flush=True)
    code = process.wait()
after = {str(path): sha256(path.read_bytes()).hexdigest() for path in inputs}
log = (out / "xcodebuild.log").read_text(errors="replace")
outcomes = {name: re.findall(
    r"Test Case '[^\n]*\b" + re.escape(name) + r"\]' (passed|failed|skipped)", log) for name in names + waiting_names}
report = {"exit": code, "namedOutcomes": outcomes, "inputsUnchanged": before == after,
    "allFourPassed": all(outcomes[name] == ["passed"] for name in names[:4]),
    "allNamedPassed": all(outcomes[name] == ["passed"] for name in names + waiting_names),
    "scope": "SIMULATED shared dashboard activation, reorder, disabled/read-only, viewport and full-window waiting paint with native owner retention"}
(out / "outcomes.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report), flush=True)
if code:
    raise SystemExit(code)
assert report["allNamedPassed"] and report["inputsUnchanged"], report
