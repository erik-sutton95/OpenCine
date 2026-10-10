#!/usr/bin/env python3
"""Run developer-only playback and status geometry contracts in an existing SIMULATED app.

The caller owns a private simulator, accessibility setup/restoration, compiler
serialization and the DerivedData directory. This script never creates or
deletes a simulator, clears app data, or changes the app/package input sources.
"""
from hashlib import sha256
from pathlib import Path
import argparse
import json
import re
import shutil
import subprocess
from uuid import UUID

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--project-spec", type=Path, required=True)
parser.add_argument("--host-target", required=True)
parser.add_argument("--host-entitlements", type=Path, required=True)
parser.add_argument("--simulator-id", required=True)
parser.add_argument("--derived-data", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--jobs", type=int, choices=range(1, 5), default=4)
args = parser.parse_args()
assert re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*Simulated", args.host_target)
UUID(args.simulator_id)
sdk = Path(__file__).resolve().parents[1]
source = sdk / "Tests/OpenCineCameraControlsHostedTests/MonitorOperatorPlaybackOptionsTests.swift"
geometry_source = sdk / "Tests/OpenCineCameraControlsHostedTests/MonitorPortraitStatusGeometryTests.swift"
project_spec = args.project_spec.resolve(strict=True)
entitlements = args.host_entitlements.resolve(strict=True)
assert (sdk / "Package.swift").is_file() and source.is_file() and geometry_source.is_file()
assert shutil.disk_usage(sdk).free >= 40 * 2**30, "Retain the 40GiB compiler reserve"
xcodegen = shutil.which("xcodegen")
assert xcodegen, "Use the existing XcodeGen installation; this runner never installs tools"
out = args.output.resolve()
assert not out.exists(), "Use a fresh owned output directory"
out.mkdir(parents=True)
names = [
    "testSupportedOptionsChangeTheSuppliedAssistWithoutReplacingThePlayer",
    "testAbsentStoresAndPlaybackSuppliersOmitUnavailableControls",
    "testActualMenuActionsReadTheSavedHapticsPreferenceEachTime",
]
assert re.findall(r"\bfunc (test\w+)\(", source.read_text()) == names
geometry_names = [
    "testObservedSeparateReadoutsKeepTheirFullValuesAndEightPointClearance",
    "testCompactReadoutPreservesThePreferredCenteredClock",
    "testNarrowViewportUsesAnIntrinsicSecondRowWithoutMovingTheScreenTopAnchor",
    "testRightToLeftKeepsTheSameValuesAndLogicalSideSeparation",
]
assert re.findall(r"\bfunc (test\w+)\(", geometry_source.read_text()) == geometry_names
all_names = names + geometry_names
inputs = [source, geometry_source, Path(__file__).resolve(), sdk / "Package.swift", project_spec, entitlements]
before = {str(path): sha256(path.read_bytes()).hexdigest() for path in inputs}
(out / "input-binding.json").write_text(json.dumps(before, indent=2) + "\n")
target = "OpenCinePlaybackOptionsHostedTests"
scheme = "OpenCinePlaybackOptionsHosted"
spec = {
    "name": scheme,
    "include": [{"path": str(project_spec), "relativePaths": True}],
    "packages": {"OpenCine": {"path": str(sdk)}},
    "targets": {
        args.host_target: {"settings": {"base": {"CODE_SIGN_ENTITLEMENTS": str(entitlements)}}},
        target: {
            "type": "bundle.unit-test", "platform": "iOS", "sources": [str(source), str(geometry_source)],
            "dependencies": [{"target": args.host_target}] + [
                {"package": "OpenCine", "product": product} for product in [
                    "MonitorPresentation", "MonitorUI", "OpenCineAppKit",
                    "OpenCineCameraControls", "OpenCineMedia",
                ]
            ],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.opencine.playbackoptions.hostedtests",
                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/" + args.host_target + ".app/" + args.host_target,
                "BUNDLE_LOADER": "$(TEST_HOST)",
            }},
        },
    },
    "schemes": {scheme: {
        "build": {"targets": {args.host_target: ["test"], target: ["test"]}},
        "test": {"config": "Debug", "macroExpansion": args.host_target,
            "targets": [{"name": target, "parallelizable": False, "randomExecutionOrder": False}]},
    }},
}
spec_path = out / "project-hosted.json"
spec_path.write_text(json.dumps(spec, indent=2) + "\n")
subprocess.run([
    xcodegen, "generate", "--spec", str(spec_path), "--project", str(out),
    "--project-root", str(project_spec.parent),
], check=True)
project = out / (scheme + ".xcodeproj")
pbx = project / "project.pbxproj"
project_before = pbx.read_bytes()
assert spec["targets"][target]["settings"]["base"]["TEST_HOST"] in project_before.decode()
command = [
    "xcodebuild", "-project", str(project), "-scheme", scheme, "-configuration", "Debug",
    "-destination", "platform=iOS Simulator,id=" + args.simulator_id,
    "-derivedDataPath", str(args.derived_data.resolve()), "-jobs", str(args.jobs),
    "-parallel-testing-enabled", "NO", "-resultBundlePath", str(out / "result.xcresult"),
    "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=YES", "SWIFT_STRICT_CONCURRENCY=complete",
    "-only-testing:" + target + "/MonitorOperatorPlaybackOptionsTests",
    "-only-testing:" + target + "/MonitorPortraitStatusGeometryTests", "test",
]
print(json.dumps({"applicationHostedCommand": command}), flush=True)
with (out / "xcodebuild.log").open("w") as log:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert process.stdout is not None
    for line in process.stdout:
        log.write(line)
        print(line, end="", flush=True)
    code = process.wait()
after = {str(path): sha256(path.read_bytes()).hexdigest() for path in inputs}
log = (out / "xcodebuild.log").read_text(errors="replace")
outcomes = {
    name: re.findall(r"Test Case '[^\n]*\b" + re.escape(name) + r"\]' (passed|failed|skipped)", log)
    for name in all_names
}
report = {
    "processExit": code, "namedOutcomes": outcomes,
    "exactThreePasses": all(outcomes[name] == ["passed"] for name in names),
    "exactFourGeometryPasses": all(outcomes[name] == ["passed"] for name in geometry_names),
    "exactSevenPasses": all(outcomes[name] == ["passed"] for name in all_names),
    "inputSourcesUnchanged": before == after, "projectUnchanged": pbx.read_bytes() == project_before,
    "sourceSHA256": before[str(source)], "geometrySourceSHA256": before[str(geometry_source)],
    "host": args.host_target,
    "scope": "SIMULATED rendered menu actions/state/token, preference reads and portrait-header native geometry; no physical picture/haptics claim",
}
(out / "named-seven-outcomes.json").write_text(json.dumps(report, indent=2) + "\n")
# Retain the original three-case result shape for existing developer consumers.
original_report = dict(report, namedOutcomes={name: outcomes[name] for name in names})
(out / "named-three-outcomes.json").write_text(json.dumps(original_report, indent=2) + "\n")
print(json.dumps(report), flush=True)
if code:
    raise SystemExit(code)
assert report["exactSevenPasses"] and report["inputSourcesUnchanged"] and report["projectUnchanged"], report
