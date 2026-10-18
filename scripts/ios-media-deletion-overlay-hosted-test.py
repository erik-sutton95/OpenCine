#!/usr/bin/env python3
"""Run the SIMULATED media deletion overlay UI tests with genuine coordinate taps.

Generates a throwaway host app (MonitorMediaDeletionOverlayHost.swift) and UI-test bundle
(MonitorMediaDeletionOverlayTests.swift) around the shipped catalog and deletion owner. The
caller owns the private simulator and the DerivedData directory; this script never creates or
deletes a simulator and never changes package sources.
"""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
from uuid import UUID

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--simulator-id", required=True)
parser.add_argument("--derived-data", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--jobs", type=int, choices=range(1, 5), default=4)
args = parser.parse_args()
UUID(args.simulator_id)
# Real paths: XcodeGen relativizes sources against the spec directory, which a symlink breaks.
sdk = Path(__file__).resolve().parents[1]
tests = sdk / "Tests/OpenCineCameraControlsHostedTests"
host = tests / "MonitorMediaDeletionOverlayHost.swift"
source = tests / "MonitorMediaDeletionOverlayTests.swift"
assert (sdk / "Package.swift").is_file() and host.is_file() and source.is_file()
xcodegen = shutil.which("xcodegen")
assert xcodegen, "Use the existing XcodeGen installation; this runner never installs tools"
out = args.output.resolve()
assert not out.exists(), "Use a fresh owned output directory"
out.mkdir(parents=True)
host_target, test_target = "MediaDeletionSimulated", "MediaDeletionUITests"
spec = {
    "name": "MediaDeletionHosted",
    "packages": {"OpenCine": {"path": str(sdk)}},
    "options": {"deploymentTarget": {"iOS": "17.0"}},
    "settings": {"base": {"SWIFT_VERSION": "6.0", "CODE_SIGNING_ALLOWED": "NO"}},
    "targets": {
        host_target: {
            "type": "application", "platform": "iOS", "sources": [str(host)],
            "dependencies": [{"package": "OpenCine", "product": p} for p in
                ["OpenCineAppKit", "OpenCineCameraControls", "OpenCineCore", "OpenCineMedia"]],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.simulated.mediadeletion",
                "GENERATE_INFOPLIST_FILE": "YES",
                "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                "INFOPLIST_KEY_UISupportedInterfaceOrientations":
                    "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"}}},
        test_target: {
            "type": "bundle.ui-testing", "platform": "iOS", "sources": [str(source)],
            "dependencies": [{"target": host_target}],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.simulated.mediadeletion.uitests",
                "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": host_target}}},
    },
    "schemes": {"MediaDeletionHosted": {
        "build": {"targets": {host_target: ["test"], test_target: ["test"]}},
        "test": {"targets": [{"name": test_target, "parallelizable": False, "randomExecutionOrder": False}]}}},
}
spec_path = out / "project.json"
spec_path.write_text(json.dumps(spec, indent=2) + "\n")
subprocess.run([xcodegen, "generate", "--spec", str(spec_path), "--project", str(out)], check=True)
build = ["xcodebuild", "-project", str(out / "MediaDeletionHosted.xcodeproj"), "-scheme", "MediaDeletionHosted",
    "-jobs", str(args.jobs), "-parallel-testing-enabled", "NO",
    "-destination", f"platform=iOS Simulator,id={args.simulator_id}",
    "-derivedDataPath", str(args.derived_data.resolve()), "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=YES"]
result = out / "result.xcresult"
raise SystemExit(subprocess.call(build + ["-test-timeouts-enabled", "YES",
    "-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "180",
    "-resultBundlePath", str(result), "test"]))
