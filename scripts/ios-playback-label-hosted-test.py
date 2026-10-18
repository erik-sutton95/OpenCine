#!/usr/bin/env python3
"""Run the SIMULATED playback label contracts in a real private application scene.

The caller supplies its private, accessibility-enabled simulator and owns cleanup.
The host is generated only in the requested output directory and is never a product.
"""

import argparse
from hashlib import sha256
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import time
from uuid import UUID, uuid4


NATIVE_UI_SCHEME = "OpenCinePlaybackNativeCancel"
NATIVE_UI_TARGET = "OpenCinePlaybackNativeCancelUITests"
NATIVE_UI_METHOD = "testCapturedDeletionConfirmationReadsTheSharedCopyAndDismissalCancelsOnlyItsRequest"
NATIVE_UI_DIRECTORY = Path(__file__).resolve().with_name("ios-playback-label-native-ui")


SYSTEM_MODE = "native-system-popover-dismissal"
SYSTEM_SCHEME = "OpenCinePlaybackNativeSystemDismissal"
SYSTEM_TARGET = "OpenCinePlaybackNativeSystemDismissalUITests"
SYSTEM_DIRECTORY = Path(__file__).resolve().with_name("ios-playback-label-native-system-dismissal")
PARITY = Path(os.environ.get("OPENCINE_PARITY_ROOT", str(Path.home() / "Work/OpenCine-Parity-20261012"))).expanduser().resolve()
SYSTEM_SCRATCH = (PARITY / "scratch/testinfra-system-dismiss").resolve()


SYSTEM_SUCCESS_PREDICATES = frozenset({
    "soleNativeCasePassed", "singleDriverOutcome", "driverNonceBound", "driverSourceBound",
    "driverBundleBound", "driverSimulatorBound", "explicitSystemMode", "driverQualified",
    "openingDeleteInvoked", "systemDismissalInvoked", "noCancelInvocation", "actualAppSettlement",
    "bridgeHealthy", "preInputReceiptBound", "otherWindowInterceptionExcluded", "originalReadinessDeadlineHeld",
    "sourceUnchanged", "generatedUnchanged", "sourceFactsUnchanged", "sharedSeedUnchanged",
})
SYSTEM_WRAPPER_PREDICATES = frozenset({
    "childNativeQualified", "sourceUnchanged", "generatedUnchanged", "sourceFactsUnchanged", "sharedSeedUnchanged",
})


def system_final_verdict(child_exit: int, checks: dict, errors=(), required=SYSTEM_SUCCESS_PREDICATES) -> dict:
    """The same authoritative predicate drives durable qualification and actual process exit."""
    failures = list(errors)
    if set(checks) != set(required):
        failures.append("successPredicateShapeMismatch")
    failures.extend(key for key in sorted(required) if checks.get(key) is not True)
    if child_exit != 0:
        failures.append("childExit=" + str(child_exit))
    qualified = not failures
    return {"qualified": qualified, "exit": child_exit if child_exit != 0 else (0 if qualified else 1),
            "failureReasons": failures}


def system_deadline_held(elapsed) -> bool:
    """Monotonic pre-event elapsed time; freshness cannot extend the original thirty seconds."""
    return type(elapsed) in (int, float) and math.isfinite(elapsed) and 0 <= elapsed < 30


def system_window_failures(receipt: dict) -> list[str]:
    """Independently admit only a complete public exact-point scene-window exclusion proof."""
    proof = receipt.get("systemDismissal") or {}
    windows = receipt.get("windows", [])
    ids = proof.get("sceneWindowIDs", [])
    selected = receipt.get("windowIdentity")
    others = proof.get("otherWindowHits", [])
    failures = []
    if not selected or proof.get("window") != selected or proof.get("sceneID") != receipt.get("sceneID"):
        failures.append("selectedWindowIdentityMismatch")
    if not ids or len(ids) != len(set(ids)) or sorted(ids) != sorted(v.get("identity", "") for v in windows) \
            or ids.count(selected) != 1 or sorted(v.get("identity", "") for v in others) != sorted(v for v in ids if v != selected):
        failures.append("incompleteOrDuplicateSceneWindowInventory")
    def finite_point(value):
        return isinstance(value, dict) and all(type(value.get(k)) in (int, float)
                                              and math.isfinite(value[k]) for k in ["x", "y"])
    point = proof.get("pointOnScreen")
    if not finite_point(point):
        failures.append("invalidSelectedScreenPoint")
    for other in others:
        alpha = other.get("alpha")
        if type(alpha) not in (int, float) or not math.isfinite(alpha) \
                or type(other.get("hidden")) is not bool or type(other.get("interactive")) is not bool:
            failures.append("unknownOtherWindowEligibility:" + str(other.get("identity")))
            continue
        if not other["hidden"] and alpha >= 0.01 and other["interactive"]:
            if other.get("sceneID") != receipt.get("sceneID") or other.get("screen") != proof.get("selectedScreen") \
                    or other.get("hitTestObserved") is not True or other.get("hitIdentity") is not None \
                    or not finite_point(other.get("pointInWindow")) \
                    or not finite_point(other.get("convertedScreenPoint")) or other.get("convertedScreenPoint") != point:
                failures.append("otherWindowInterceptionNotExcluded:" + str(other.get("identity")))
    return failures


def system_seed_binding(root: Path) -> dict:
    resolved = root.parent / "OpenPocketCine/ios/Package.resolved"
    pins = json.loads(resolved.read_text())["pins"]
    key = sha256(json.dumps(sorted((v["identity"], v["state"].get("revision", "")) for v in pins)).encode()).hexdigest()[:12]
    seed = Path("/Volumes/SuttonCap/Work/BuildScratch/shared/spm-seed") / key
    return {"path": str(seed), "workspaceStateSHA256": sha256((seed / "workspace-state.json").read_bytes()).hexdigest(),
            "resolvedSHA256": sha256(resolved.read_bytes()).hexdigest()}


def system_integrity_checks(root: Path, prepared_root: Path, prepared: dict) -> tuple[dict, list[str]]:
    checks = {}
    errors = []
    probes = {
        "sourceUnchanged": lambda: prepared["inputs"] == system_source_binding(root),
        "generatedUnchanged": lambda: all(sha256((prepared_root / n).read_bytes()).hexdigest() == digest
                                           for n, digest in prepared["generated"].items()),
        "sourceFactsUnchanged": lambda: prepared["sourceFacts"] == system_source_facts(root),
        "sharedSeedUnchanged": lambda: prepared["sharedSeed"] == system_seed_binding(root),
    }
    for key, probe in probes.items():
        try:
            checks[key] = probe()
        except Exception as error:
            checks[key] = False
            errors.append(key + ":" + repr(error))
    return checks, errors


def system_source_binding(root: Path) -> dict[str, str]:
    """Bind evolved inputs and the exact original fixture; reuse sealed unaffected cohorts."""
    paths = [Path(__file__).resolve(),
             root / "Tests/MonitorUIHostedTests/MonitorPlaybackAccessibilityLabelTests.swift"]
    paths += [SYSTEM_DIRECTORY / name for name in
              ["NativeCancelReceipt.swift", "SimulatedNativeCancelHost.swift", "NativeCancelUITests.swift"]]
    result = {str(path): sha256(path.read_bytes()).hexdigest() for path in paths}
    assert result[str(paths[1])] == "824997e288e5ce8499a09be70886832a41b8f76c079cc18161e23d6dc1b17964"
    return result


def system_source_facts(root: Path) -> dict:
    """Head, identity and WIP path facts only; never resweep old source/Products manifests."""
    trees = {}
    for name in ["OpenCine", "OpenCine-a11y", "OpenPocketCine", "OpenInstaCine", "OpenZCine", "OpenZCine-a11y"]:
        def git(*args):
            return subprocess.check_output(["git", "-C", str(root.parent / name), *args]).decode().strip()
        trees[name] = {"head": git("rev-parse", "HEAD"),
                       "status": git("status", "--porcelain=v1", "--untracked-files=all"),
                       "name": git("config", "user.name"), "email": git("config", "user.email")}
        assert trees[name]["name"] == "Erik Sutton"
        assert trees[name]["email"] == "9084979+erik-sutton95@users.noreply.github.com"
    return trees


def require_system_admission(output: Path) -> dict:
    """Current shared gate provenance, actual output/backing floors; load is observed only."""
    assert not os.environ.get("HEAVY_PHYSICAL") and not os.environ.get("HEAVY_PRIORITY")
    marker = PARITY / "evidence/codex-takeover-20261017/load-throttle-0214/admission-paused"
    assert not marker.exists(), "Root emergency admission marker is active"
    os.kill(65300, 0)
    mounts = {}
    for mount, expected in [
        ("/Volumes/SuttonCap/Work/Workspace", "9DBDABAE-6E73-4AFD-82F0-E9F887CBA510"),
        ("/Volumes/SuttonCap/Work/BuildScratch", "6D9FDC68-C214-4121-8830-72606C7F3E9E"),
    ]:
        assert os.path.ismount(mount)
        info = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", mount]))
        assert info["VolumeUUID"] == expected, mount
        mounts[mount] = expected
    output = output.resolve()
    assert output.is_relative_to(Path("/Volumes/SuttonCap/Work/Workspace"))
    existing = output
    while not existing.exists():
        existing = existing.parent
    floors = {}
    for path in [existing, Path("/Volumes/SuttonCap")]:
        stat = os.statvfs(path)
        floors[str(path)] = stat.f_bavail * stat.f_frsize
        assert floors[str(path)] >= 20 * 2**30, (str(path), floors[str(path)])
    ancestors = {os.getpid()}
    current = os.getppid()
    while current > 1 and current not in ancestors:
        ancestors.add(current)
        current = int(subprocess.check_output(["ps", "-o", "ppid=", "-p", str(current)]).strip())
    owners = [(path, re.search(r"\bpid=(\d+)\b", path.read_text()))
              for path in (PARITY / "tools/.heavy-slots").glob("slot*/owner")]
    own = [str(path) for path, match in owners if match and int(match[1]) in ancestors]
    assert own, "Use current normal shared heavy.sh; no private governor"
    return {"output": str(output), "freeBytes": floors, "mounts": mounts, "watchPID": 65300,
            "observedLoad": os.getloadavg(), "sharedOwnerReceipts": own, "numericLoadAdmission": False}


def working_source_binding(root: Path) -> dict[str, str]:
    names = subprocess.check_output(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=root
    ).decode().split("\0")
    return {str(root / name): sha256((root / name).read_bytes()).hexdigest()
            for name in sorted(set(names) - {""}) if (root / name).is_file()}


def require_native_ui_admission() -> None:
    """Normal heavy queue only; source preparation does not admit native execution."""
    parity = PARITY
    assert not os.environ.get("HEAVY_PHYSICAL") and not os.environ.get("HEAVY_PRIORITY")
    assert not (parity / "evidence/codex-takeover-20261017/load-throttle-0214/admission-paused").exists()
    assert max(os.getloadavg()) < 600, os.getloadavg()
    os.kill(65300, 0)
    for mount, expected in [
        ("/Volumes/SuttonCap/Work/Workspace", "9DBDABAE-6E73-4AFD-82F0-E9F887CBA510"),
        ("/Volumes/SuttonCap/Work/BuildScratch", "6D9FDC68-C214-4121-8830-72606C7F3E9E"),
    ]:
        assert os.path.ismount(mount)
        value = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", mount]))
        assert value["VolumeUUID"] == expected, mount
        status = os.statvfs(mount)
        assert status.f_bavail * status.f_frsize >= 20 * 2**30, mount
    ancestors = {os.getpid()}
    current = os.getppid()
    while current > 1 and current not in ancestors:
        ancestors.add(current)
        current = int(subprocess.check_output(["ps", "-o", "ppid=", "-p", str(current)]).strip())
    owners = [(path, re.search(r"\bpid=(\d+)\b", path.read_text()))
              for path in (parity / "tools/.heavy-slots").glob("slot*/owner")]
    assert any(match and int(match[1]) in ancestors for _, match in owners), "Use normal heavy.sh"


def prepare_native_ui(root: Path, out: Path) -> int:
    """Generate reviewable sources/project only. Never build, boot, launch or send input."""
    require_native_ui_admission()
    assert not out.exists(), "Preserve each previous source packet and native failure"
    out.mkdir(parents=True)
    inputs = working_source_binding(root)
    source_seal = sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    nonce = str(uuid4())
    host = "OpenCinePlaybackNativeCancelSimulated"
    bundle = "com.opencapture.opencine.simulated.playbacklabels.native.run" + nonce.replace("-", "")
    for name in ["NativeCancelReceipt.swift", "SimulatedNativeCancelHost.swift", "NativeCancelUITests.swift"]:
        shutil.copy2(NATIVE_UI_DIRECTORY / name, out / name)
    common = str(out / "NativeCancelReceipt.swift")
    spec = {
        "name": NATIVE_UI_SCHEME,
        "options": {"deploymentTarget": {"iOS": "17.0"}},
        "settings": {"base": {
            "SWIFT_VERSION": "6.0", "GENERATE_INFOPLIST_FILE": "YES", "TARGETED_DEVICE_FAMILY": "1,2",
            "SUPPORTED_PLATFORMS": "iphonesimulator",
        }},
        "packages": {"OpenCine": {"path": str(root)}},
        "targets": {
            host: {
                "type": "application", "platform": "iOS",
                "sources": [common, str(out / "SimulatedNativeCancelHost.swift")],
                "dependencies": [{"package": "OpenCine", "product": name} for name in
                                 ["MonitorPresentation", "MonitorUI", "OpenCineMedia"]],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": bundle,
                    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
                    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                }},
            },
            NATIVE_UI_TARGET: {
                "type": "bundle.ui-testing", "platform": "iOS",
                "sources": [common, str(out / "NativeCancelUITests.swift")],
                "dependencies": [{"target": host}] + [{"package": "OpenCine", "product": name} for name in
                                                         ["MonitorPresentation", "OpenCineHostedTestSupport"]],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": bundle + ".uitests", "TEST_TARGET_NAME": host,
                }},
            },
        },
        "schemes": {NATIVE_UI_SCHEME: {
            "build": {"targets": {host: ["test"], NATIVE_UI_TARGET: ["test"]}},
            "test": {"config": "Debug", "macroExpansion": host,
                     "targets": [{"name": NATIVE_UI_TARGET, "parallelizable": False, "randomExecutionOrder": False}],
                     "environmentVariables": {"OPENCINE_NATIVE_UI_NONCE": nonce,
                                              "OPENCINE_NATIVE_UI_SOURCE_SEAL": source_seal,
                                              "OPENCINE_NATIVE_UI_BUNDLE_ID": bundle}},
        }},
    }
    (out / "project.json").write_text(json.dumps(spec, indent=2) + "\n")
    subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.json"), "--project", str(out)], check=True)
    generated = {str(path.relative_to(out)): sha256(path.read_bytes()).hexdigest()
                 for path in sorted(out.rglob("*")) if path.is_file()}
    prepared = {"scope": "SIMULATED source-review packet only; native execution not admitted",
                "nonce": nonce, "sourceSeal": source_seal, "bundleID": bundle,
                "runnerBundleID": bundle + ".uitests.xctrunner", "inputs": inputs, "generated": generated,
                "scheme": NATIVE_UI_SCHEME, "target": NATIVE_UI_TARGET, "method": NATIVE_UI_METHOD,
                "readinessSeconds": 30, "settlementSeconds": 30, "outsideInputImplemented": False}
    (out / "prepared.json").write_text(json.dumps(prepared, indent=2) + "\n")
    assert inputs == working_source_binding(root), "Sources changed during project generation"
    print(json.dumps({"preparedNativeUI": str(out), "sourceSeal": source_seal,
                      "preparedSHA256": sha256((out / "prepared.json").read_bytes()).hexdigest(),
                      "nativeExecution": False}), flush=True)
    return 0


class NativeUIReceiptBridge:
    """One-way byte copies from the exact app container to the exact UI runner's inbox."""

    def __init__(self, simulator: str, prepared: dict, out: Path):
        self.simulator, self.prepared, self.out = simulator, prepared, out
        self.private_root = (Path.home() / "Library/Developer/CoreSimulator/Devices" / simulator
                             / "data/Containers/Data/Application").resolve()
        self.records: list[dict] = []
        self.last_sequence = 0

    def container_for(self, path: Path, bundle: str) -> Path:
        relative = path.resolve().relative_to(self.private_root)
        container = self.private_root / relative.parts[0]
        metadata = plistlib.loads((container / ".com.apple.mobile_container_manager.metadata.plist").read_bytes())
        assert metadata["MCMMetadataIdentifier"] == bundle, (path, bundle)
        return container

    def observe(self, text: str) -> None:
        markers = set(re.findall(r"SIMULATED_NATIVE_UI_INBOX:([^\r\n]+)", text))
        assert len(markers) <= 1, "Only one native method/inbox is allowed"
        if not markers:
            return
        destination = Path(next(iter(markers)))
        reader = self.container_for(destination, self.prepared["runnerBundleID"])
        assert destination.resolve() == (reader / "tmp" / ("SIMULATED-native-reader-" + self.prepared["nonce"])
                                          / "app-receipt.json").resolve()
        assert destination.parent.is_dir() and not destination.is_symlink()
        hosts = []
        for container in self.private_root.iterdir():
            metadata = container / ".com.apple.mobile_container_manager.metadata.plist"
            if metadata.is_file() and plistlib.loads(metadata.read_bytes()).get("MCMMetadataIdentifier") == self.prepared["bundleID"]:
                hosts.append(container)
        assert len(hosts) <= 1, "Ambiguous private host container"
        if not hosts:
            return
        source = hosts[0] / "tmp" / ("SIMULATED-native-cancel-" + self.prepared["nonce"]) / "app-receipt.json"
        if not source.is_file():
            return
        self.container_for(source, self.prepared["bundleID"])
        assert not source.is_symlink()
        data = source.read_bytes()
        receipt = json.loads(data)
        assert receipt["schema"] == 1 and receipt["nonce"] == self.prepared["nonce"]
        assert receipt["sourceSeal"] == self.prepared["sourceSeal"] and receipt["bundleID"] == self.prepared["bundleID"]
        assert UUID(receipt["simulatorID"]) == UUID(self.simulator) and receipt["processID"] > 0
        if receipt["sequence"] <= self.last_sequence:
            return
        archive = self.out / "app-receipts" / (str(receipt["sequence"]) + ".json")
        archive.parent.mkdir(exist_ok=True)
        archive.write_bytes(data)
        temporary = destination.with_name(".app-receipt-bridge-" + self.prepared["nonce"])
        temporary.write_bytes(data)
        temporary.chmod(0o400)
        temporary.replace(destination)
        assert destination.read_bytes() == archive.read_bytes()
        self.last_sequence = receipt["sequence"]
        self.records.append({"sequence": receipt["sequence"], "sha256": sha256(data).hexdigest(),
                             "source": str(source), "readerCopy": str(destination), "retained": str(archive)})


def qualify_native_ui(args: argparse.Namespace, root: Path, out: Path) -> int:
    """Explicitly invoked only after Root reviews this exact prepared source/project packet."""
    require_native_ui_admission()
    assert args.jobs == 4 and args.simulator_id and args.derived_data and args.source_packages
    UUID(args.simulator_id)
    prepared_root = args.prepared_native_ui.resolve()
    manifest = prepared_root / "prepared.json"
    assert sha256(manifest.read_bytes()).hexdigest() == args.reviewed_packet_sha256
    prepared = json.loads(manifest.read_text())
    assert prepared["inputs"] == working_source_binding(root), "Review a fresh packet after any source change"
    def generated_binding():
        return {name: sha256((prepared_root / name).read_bytes()).hexdigest() for name in prepared["generated"]}
    assert generated_binding() == prepared["generated"]
    assert not out.exists() and not args.derived_data.exists(), "Use fresh evidence and scratch; preserve all prior Products"
    out.mkdir(parents=True)
    device = Path.home() / "Library/Developer/CoreSimulator/Devices" / args.simulator_id / "device.plist"
    private_device = plistlib.loads(device.read_bytes())
    assert private_device["name"] == "opc-testinfra3-native-ui-cancel-" + prepared["nonce"], "Exact task-private simulator required"
    assert private_device["deviceType"] == "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
    assert private_device["runtime"] == "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
    assert args.derived_data.resolve().is_relative_to(Path("/Volumes/SuttonCap/Work/BuildScratch/testinfra3-parent"))
    assert args.source_packages.is_dir(), "Use the standard shared-SPM seed/clone, never a private download"
    command = [
        "xcodebuild", "-project", str(prepared_root / (NATIVE_UI_SCHEME + ".xcodeproj")),
        "-scheme", NATIVE_UI_SCHEME, "-destination", "platform=iOS Simulator,id=" + args.simulator_id,
        "-derivedDataPath", str(args.derived_data.resolve()), "-jobs", "4", "-parallel-testing-enabled", "NO",
        "-clonedSourcePackagesDirPath", str(args.source_packages.resolve()), "-skipPackageUpdates",
        "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
        "-default-test-execution-time-allowance", "120", "-maximum-test-execution-time-allowance", "170",
        "-resultBundlePath", str(out / "result.xcresult"), "CODE_SIGNING_ALLOWED=NO",
        "-only-testing:" + NATIVE_UI_TARGET + "/NativeCancelUITests/" + NATIVE_UI_METHOD, "test",
    ]
    (out / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    bridge = NativeUIReceiptBridge(args.simulator_id, prepared, out)
    log_path = out / "xcodebuild.log"
    start = last_progress = time.monotonic()
    size = 0
    interruption = None
    bridge_error = None
    require_native_ui_admission()
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        while process.poll() is None:
            time.sleep(0.1)
            now = time.monotonic()
            current = log_path.stat().st_size
            if current != size:
                size, last_progress = current, now
            if bridge_error is None:
                try:
                    bridge.observe(log_path.read_text(errors="replace"))
                except Exception as error:
                    bridge_error = repr(error)  # A stale/absent receipt cannot pass the no-input guard.
            if now - last_progress > 180 or now - start > 2400:
                interruption = "no-progress180" if now - last_progress > 180 else "wall2400"
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                break
        code = process.wait()
    text = log_path.read_text(errors="replace")
    outcomes = re.findall(r"Test Case '[^\n]*\b" + NATIVE_UI_METHOD + r"\]' (passed|failed|skipped)", text)
    driver_values = [json.loads(value) for value in re.findall(r"SIMULATED_NATIVE_UI_OUTCOME:({[^\r\n]+})", text)]
    driver = driver_values[0] if len(driver_values) == 1 else {}
    app_records = [record for record in bridge.records if record["sequence"] == driver.get("sequence")
                   and record["sha256"] == driver.get("appReceiptSHA256")]
    app = json.loads(Path(app_records[0]["retained"]).read_text()) if len(app_records) == 1 else {}
    actual_settlement = bool(app) and app["cancelled"] == [app["requestID"]] and not app["confirmed"] \
        and app["captureRequestIDs"] == [app["requestID"]] and app["capturedItems"] == [app["item"]] \
        and app["deletedCount"] == 0 and not app["activeRequestIDs"] and app["retiredRequestIDs"] == [app["requestID"]] \
        and app["dialogWindowGone"] and app["presentingControllerGone"] and app["popup"] is None
    qualified = code == 0 and outcomes == ["passed"] and len(driver_values) == 1 \
        and driver.get("nonce") == prepared["nonce"] and driver.get("sourceSeal") == prepared["sourceSeal"] \
        and driver.get("bundleID") == prepared["bundleID"] \
        and driver.get("simulatorID", "").upper() == args.simulator_id.upper() \
        and driver.get("outsideInputImplemented") is False \
        and driver.get("qualified") is True and driver.get("deleteTapInvoked") is True \
        and driver.get("cancelTapInvoked") is True and actual_settlement and bridge_error is None
    receipt = {"scope": "SIMULATED one native UI method; physical untested", "processExit": code,
               "watchdog": interruption, "nativeOutcomes": outcomes, "driver": driver,
               "bridgeError": bridge_error, "bridgeRecords": bridge.records,
               "actualAppSettlement": actual_settlement, "qualified": qualified,
               "sourceUnchanged": prepared["inputs"] == working_source_binding(root),
               "generatedUnchanged": prepared["generated"] == generated_binding(),
               "logSHA256": sha256(log_path.read_bytes()).hexdigest()}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt), flush=True)
    return 0 if qualified and receipt["sourceUnchanged"] and receipt["generatedUnchanged"] else (code or 1)



def prepare_system_dismissal(root: Path, out: Path) -> int:
    """Generate reviewable sources/project only. Never build, boot, launch or send input."""
    admission = require_system_admission(out)
    assert not out.exists(), "Preserve each previous source packet and native failure"
    out.mkdir(parents=True)
    inputs = system_source_binding(root)
    facts = system_source_facts(root)
    source_seal = sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    nonce = str(uuid4())
    host = "OpenCinePlaybackNativeSystemDismissalSimulated"
    bundle = "com.opencapture.opencine.simulated.playbacklabels.systemdismiss.run" + nonce.replace("-", "")
    for name in ["NativeCancelReceipt.swift", "SimulatedNativeCancelHost.swift", "NativeCancelUITests.swift"]:
        shutil.copy2(SYSTEM_DIRECTORY / name, out / name)
    common = str(out / "NativeCancelReceipt.swift")
    spec = {
        "name": SYSTEM_SCHEME,
        "options": {"deploymentTarget": {"iOS": "17.0"}},
        "settings": {"base": {
            "SWIFT_VERSION": "6.0", "GENERATE_INFOPLIST_FILE": "YES", "TARGETED_DEVICE_FAMILY": "1,2",
            "SUPPORTED_PLATFORMS": "iphonesimulator",
        }},
        "packages": {"OpenCine": {"path": str(root)}},
        "targets": {
            host: {
                "type": "application", "platform": "iOS",
                "sources": [common, str(out / "SimulatedNativeCancelHost.swift")],
                "dependencies": [{"package": "OpenCine", "product": name} for name in
                                 ["MonitorPresentation", "MonitorUI", "OpenCineMedia"]],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": bundle,
                    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
                    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                }},
            },
            SYSTEM_TARGET: {
                "type": "bundle.ui-testing", "platform": "iOS",
                "sources": [common, str(out / "NativeCancelUITests.swift")],
                "dependencies": [{"target": host}] + [{"package": "OpenCine", "product": name} for name in
                                                         ["MonitorPresentation", "OpenCineHostedTestSupport"]],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": bundle + ".uitests", "TEST_TARGET_NAME": host,
                }},
            },
        },
        "schemes": {SYSTEM_SCHEME: {
            "build": {"targets": {host: ["test"], SYSTEM_TARGET: ["test"]}},
            "test": {"config": "Debug", "macroExpansion": host,
                     "targets": [{"name": SYSTEM_TARGET, "parallelizable": False, "randomExecutionOrder": False}],
                     "environmentVariables": {"OPENCINE_NATIVE_UI_NONCE": nonce,
                                              "OPENCINE_NATIVE_UI_SOURCE_SEAL": source_seal,
                                              "OPENCINE_NATIVE_UI_BUNDLE_ID": bundle,
                                              "OPENCINE_NATIVE_UI_MODE": SYSTEM_MODE}},
        }},
    }
    (out / "project.json").write_text(json.dumps(spec, indent=2) + "\n")
    subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.json"), "--project", str(out)], check=True)
    generated = {str(path.relative_to(out)): sha256(path.read_bytes()).hexdigest()
                 for path in sorted(out.rglob("*")) if path.is_file()}
    prepared = {"scope": "SIMULATED source-review packet only; native execution not admitted",
                "nonce": nonce, "sourceSeal": source_seal, "bundleID": bundle,
                "runnerBundleID": bundle + ".uitests.xctrunner", "inputs": inputs, "generated": generated,
                "scheme": SYSTEM_SCHEME, "target": SYSTEM_TARGET, "method": NATIVE_UI_METHOD,
                "readinessSeconds": 30, "settlementSeconds": 30, "outsideInputImplemented": True,
                "mode": SYSTEM_MODE, "sourceFacts": facts, "admission": admission,
                "sharedSeed": system_seed_binding(root),
                "bindingReuse": {"priorPreparedSHA256": "33259217d7733446aa3a8eb1a1efab3f2e2a1b8687ef91982436c2cab06f5992",
                                 "priorFullBinding": str(PARITY / "evidence/codex-takeover-20261017/testinfra3-parent/native-ui-source-packet/source-custody.json"),
                                 "fullCohortReswept": False}}
    (out / "prepared.json").write_text(json.dumps(prepared, indent=2) + "\n")
    assert inputs == system_source_binding(root) and facts == system_source_facts(root), "Sources changed during project generation"
    print(json.dumps({"preparedNativeUI": str(out), "sourceSeal": source_seal,
                      "preparedSHA256": sha256((out / "prepared.json").read_bytes()).hexdigest(),
                      "nativeExecution": False}), flush=True)
    return 0


def qualify_system_dismissal(args: argparse.Namespace, root: Path, out: Path) -> int:
    """Explicitly invoked only after Root reviews this exact prepared source/project packet."""
    require_system_admission(out)
    assert args.jobs is None and args.simulator_id and args.derived_data and args.source_packages
    UUID(args.simulator_id)
    prepared_root = args.prepared_system_dismissal.resolve()
    manifest = prepared_root / "prepared.json"
    assert sha256(manifest.read_bytes()).hexdigest() == args.reviewed_packet_sha256
    prepared = json.loads(manifest.read_text())
    assert prepared["sharedSeed"] == system_seed_binding(root)
    assert prepared["mode"] == SYSTEM_MODE and prepared["sourceFacts"] == system_source_facts(root)
    assert prepared["inputs"] == system_source_binding(root), "Review a fresh packet after any source change"
    def generated_binding():
        return {name: sha256((prepared_root / name).read_bytes()).hexdigest() for name in prepared["generated"]}
    assert generated_binding() == prepared["generated"]
    assert not out.exists(), "Use a unique raw result path; preserve all prior failures"
    out.mkdir(parents=True)
    device = Path.home() / "Library/Developer/CoreSimulator/Devices" / args.simulator_id / "device.plist"
    private_device = plistlib.loads(device.read_bytes())
    assert private_device["name"] == "opc-testinfra3-system-dismiss-" + prepared["nonce"], "Exact task-private simulator required"
    assert private_device["deviceType"] == "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
    assert private_device["runtime"] == "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
    assert args.derived_data.resolve().is_relative_to(SYSTEM_SCRATCH)
    assert args.source_packages.resolve() == SYSTEM_SCRATCH / "source-packages"
    assert args.source_packages.is_dir(), "Use the owned reusable clone of the read-only shared seed"
    command = [
        "xcodebuild", "-project", str(prepared_root / (SYSTEM_SCHEME + ".xcodeproj")),
        "-scheme", SYSTEM_SCHEME, "-destination", "platform=iOS Simulator,id=" + args.simulator_id,
        "-derivedDataPath", str(args.derived_data.resolve()), "-parallel-testing-enabled", "NO",
        "-clonedSourcePackagesDirPath", str(args.source_packages.resolve()), "-skipPackageUpdates",
        "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
        "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
        "-default-test-execution-time-allowance", "120", "-maximum-test-execution-time-allowance", "170",
        "-resultBundlePath", str(out / "result.xcresult"), "CODE_SIGNING_ALLOWED=NO",
        "-only-testing:" + SYSTEM_TARGET + "/NativeCancelUITests/" + NATIVE_UI_METHOD, "test",
    ]
    (out / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    bridge = NativeUIReceiptBridge(args.simulator_id, prepared, out)
    log_path = out / "xcodebuild.log"
    start = last_progress = time.monotonic()
    size = 0
    interruption = None
    bridge_error = None
    require_system_admission(out)
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        ownership = {"pid": process.pid, "pgid": process.pid, "nonce": prepared["nonce"],
                     "sourceSeal": prepared["sourceSeal"], "command": command, "state": "running"}
        (out / "owned-reader.json").write_text(json.dumps(ownership, indent=2) + "\n")
        while process.poll() is None:
            time.sleep(0.1)
            now = time.monotonic()
            current = log_path.stat().st_size
            if current != size:
                size, last_progress = current, now
            if bridge_error is None:
                try:
                    bridge.observe(log_path.read_text(errors="replace"))
                except Exception as error:
                    bridge_error = repr(error)  # A stale/absent receipt cannot pass the no-input guard.
            emergency = (PARITY / "evidence/codex-takeover-20261017/load-throttle-0214/admission-paused").exists()
            if emergency or now - last_progress > 180 or now - start > 2400:
                interruption = "Root-emergency-marker" if emergency else ("no-progress180" if now - last_progress > 180 else "wall2400")
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                break
        code = process.wait(timeout=20)
        ownership.update(state="exited", processExit=code)
        (out / "owned-reader.json").write_text(json.dumps(ownership, indent=2) + "\n")
    text = log_path.read_text(errors="replace")
    outcomes = re.findall(r"Test Case '[^\n]*\b" + NATIVE_UI_METHOD + r"\]' (passed|failed|skipped)", text)
    all_native = re.findall(r"Test Case '([^\n]+)\' (passed|failed|skipped)", text)
    exact_native = all_native == [("-[" + SYSTEM_TARGET + ".NativeCancelUITests " + NATIVE_UI_METHOD + "]", "passed")]
    driver_values = [json.loads(value) for value in re.findall(r"SIMULATED_NATIVE_UI_OUTCOME:({[^\r\n]+})", text)]
    driver = driver_values[0] if len(driver_values) == 1 else {}
    app_records = [record for record in bridge.records if record["sequence"] == driver.get("sequence")
                   and record["sha256"] == driver.get("appReceiptSHA256")]
    app = json.loads(Path(app_records[0]["retained"]).read_text()) if len(app_records) == 1 else {}
    actual_settlement = bool(app) and app["cancelled"] == [app["requestID"]] and not app["confirmed"] \
        and app["captureRequestIDs"] == [app["requestID"]] and app["capturedItems"] == [app["item"]] \
        and app["deletedCount"] == 0 and not app["activeRequestIDs"] and app["retiredRequestIDs"] == [app["requestID"]] \
        and app["dialogWindowGone"] and app["presentingControllerGone"] and app.get("popup") is None
    pre_records = [record for record in bridge.records if record["sequence"] == driver.get("preInputAppSequence")
                   and record["sha256"] == driver.get("preInputAppSHA256")]
    pre_input = json.loads(Path(pre_records[0]["retained"]).read_text()) if len(pre_records) == 1 else {}
    window_failures = system_window_failures(pre_input)
    checks = {
        "soleNativeCasePassed": outcomes == ["passed"] and exact_native,
        "singleDriverOutcome": len(driver_values) == 1,
        "driverNonceBound": driver.get("nonce") == prepared["nonce"],
        "driverSourceBound": driver.get("sourceSeal") == prepared["sourceSeal"],
        "driverBundleBound": driver.get("bundleID") == prepared["bundleID"],
        "driverSimulatorBound": driver.get("simulatorID", "").upper() == args.simulator_id.upper(),
        "explicitSystemMode": driver.get("outsideInputImplemented") is True and driver.get("mode") == SYSTEM_MODE,
        "driverQualified": driver.get("qualified") is True,
        "openingDeleteInvoked": driver.get("deleteTapInvoked") is True,
        "systemDismissalInvoked": driver.get("systemDismissalTapInvoked") is True,
        "noCancelInvocation": driver.get("cancelTapInvoked") is False,
        "actualAppSettlement": bool(actual_settlement), "bridgeHealthy": bridge_error is None,
        "preInputReceiptBound": len(pre_records) == 1,
        "otherWindowInterceptionExcluded": not window_failures,
        "originalReadinessDeadlineHeld": system_deadline_held(driver.get("eventReadinessElapsedSeconds")),
    }
    integrity, integrity_errors = system_integrity_checks(root, prepared_root, prepared)
    checks.update(integrity)
    verdict = system_final_verdict(code, checks, integrity_errors + window_failures)
    receipt = {"scope": "SIMULATED one native UI method; physical untested", "processExit": code,
               "watchdog": interruption, "nativeOutcomes": outcomes, "allNativeOutcomes": all_native,
               "driver": driver, "bridgeError": bridge_error, "bridgeRecords": bridge.records,
               "actualAppSettlement": bool(actual_settlement), "successPredicates": checks,
               **integrity, **verdict, "logSHA256": sha256(log_path.read_bytes()).hexdigest()}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt), flush=True)
    return verdict["exit"]



def observe_typed_request(text: str, nonce: str, simulator: str, out: Path, qualifier: bool = False) -> bool:
    """Observe the held native stage; never activate/focus a window or send input."""
    paths = re.findall(r"SIMULATED_TYPED_CANCEL_REQUEST:([^\r\n]+)", text)
    if not paths:
        return False
    request = Path(paths[-1])
    private_root = Path.home() / "Library/Developer/CoreSimulator/Devices" / simulator / "data/Containers/Data/Application"
    assert request.resolve().is_relative_to(private_root.resolve()), request
    data = json.loads(request.read_text())
    assert data["nonce"] == nonce and "SIMULATED-typed-cancel-" + nonce in str(request)
    (out / "native-request.json").write_text(json.dumps(data, indent=2) + "\n")
    observation = {"request": str(request), "nonce": nonce, "inputSent": False,
                   "requestAgeAtObservation": time.time() - data["createdAt"], "commands": []}

    def observe(command: list[str], name: str) -> subprocess.CompletedProcess:
        marker = PARITY / "evidence/codex-takeover-20261017/load-throttle-0214/admission-paused"
        assert not marker.exists() and max(os.getloadavg()) < 600, "Stop new diagnostic probes during admission pause"
        os.kill(65300, 0)
        start = time.time()
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        (out / name).write_text(result.stdout + result.stderr)
        observation["commands"].append({"command": command, "start": start, "end": time.time(), "exit": result.returncode})
        return result

    try:
        screenshot = observe(["xcrun", "simctl", "io", simulator, "screenshot", str(out / "native-stage.png")], "native-screenshot.log")
        observation["stageScreenshotCaptured"] = screenshot.returncode == 0
        if qualifier:
            observation["desktopProbeRequested"] = False
            observation["OSInputSent"] = False
            observation["stopReason"] = "Native AX input is gated and recorded in-process; no desktop/coordinate event"
            if screenshot.returncode == 0:
                receipt = {"nonce": nonce, "capturedAt": time.time(),
                           "screenshotSHA256": sha256((out / "native-stage.png").read_bytes()).hexdigest()}
                # Only an observed screenshot receipt, never an action/state/cancellation acknowledgement.
                (request.parent / "screenshot-captured.json").write_text(json.dumps(receipt) + "\n")
        else:
            windows = observe(["orca", "computer", "list-windows", "--app", "com.apple.iphonesimulator", "--json"], "simulator-windows.json")
            # This fresh public response must prove the exact owned visible/focused window.
            # A generic/default simulator or an absent focus/occlusion/transform fact permits no input.
            window_data = json.loads(windows.stdout) if windows.stdout.strip() else {}
            observation["windowResponseOK"] = window_data.get("ok", False)
            observation["nativeCandidateEligible"] = data["nativeCandidateEligible"]
            observation["cancelAXCount"] = len(data["cancelAXNodes"])
            observation["visibleNativeCancelCount"] = len(data["visibleNativeCancelViews"])
            if data["cancelAXNodes"]:
                observation["stopReason"] = "Cancel exists in the retained full lookup; stop before any input and classify its source-bound scope"
            elif data["visibleNativeCancelViews"]:
                observation["stopReason"] = "A native Cancel view candidate exists; stop before any alternate input"
            elif not data["nativeCandidateEligible"]:
                observation["stopReason"] = "Actual native dimming-region/point preconditions not established"
            else:
                observation["stopReason"] = "Exact private Simulator visible/unobscured/focused window and coordinate transform not yet proved; no input"
            observation["privateSimulatorName"] = "opc-testinfra3-typed-native-diagnostic"
            observation["userFocusChanged"] = False
            observation["focusOrRestoreAttempted"] = False
    except Exception as error:
        observation["stopReason"] = "Read-only observation precondition failed: " + repr(error)
    finally:
        observation["completedAt"] = time.time()
        (out / "native-observation.json").write_text(json.dumps(observation, indent=2) + "\n")
        print(json.dumps({"SIMULATEDTypedNativeObservation": observation}), flush=True)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-id")
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jobs", type=int)
    parser.add_argument("--diagnose-typed-cancel", action="store_true",
                        help="Run only the original typed method and capture its held native stage; never steal focus")
    parser.add_argument("--qualify-typed-native-scene", action="store_true",
                        help="Only original typed method; real-scene fixture and one visible Cancel AX activation")
    parser.add_argument("--prepare-native-ui", action="store_true", help="Generate source/project packet only; never run native commands")
    parser.add_argument("--qualify-native-ui", action="store_true", help="One UI method, only after Root's exact source/project review")
    parser.add_argument("--prepared-native-ui", type=Path)
    parser.add_argument("--reviewed-packet-sha256")
    parser.add_argument("--source-packages", type=Path)
    parser.add_argument("--prepare-native-system-popover-dismissal", action="store_true")
    parser.add_argument("--qualify-native-system-popover-dismissal", action="store_true")
    parser.add_argument("--prepared-system-dismissal", type=Path)
    args = parser.parse_args()
    assert sum([args.diagnose_typed_cancel, args.qualify_typed_native_scene,
                args.prepare_native_ui, args.qualify_native_ui,
                args.prepare_native_system_popover_dismissal, args.qualify_native_system_popover_dismissal]) <= 1
    root = Path(__file__).resolve().parents[1]
    if args.prepare_native_system_popover_dismissal:
        assert args.jobs is None
        return prepare_system_dismissal(root, args.output.resolve())
    if args.qualify_native_system_popover_dismissal:
        assert args.prepared_system_dismissal and args.reviewed_packet_sha256 and args.jobs is None
        return qualify_system_dismissal(args, root, args.output.resolve())
    if not any([args.prepare_native_ui, args.qualify_native_ui,
                args.diagnose_typed_cancel, args.qualify_typed_native_scene]):
        import importlib.util
        loader = importlib.util.spec_from_file_location(
            "legacy_hosted_input", root / "scripts/ios-playback-label-legacy-input.py")
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        return module.run(args, root)
    args.jobs = args.jobs if args.jobs is not None else 4
    if args.prepare_native_ui:
        return prepare_native_ui(root, args.output.resolve())
    if args.qualify_native_ui:
        assert args.prepared_native_ui and args.reviewed_packet_sha256
        return qualify_native_ui(args, root, args.output.resolve())
    assert args.simulator_id and args.derived_data
    UUID(args.simulator_id)
    source = root / "Tests/MonitorUIHostedTests/MonitorPlaybackAccessibilityLabelTests.swift"
    names = [
        "testChromeTransportScrubberAndInfoReadTheSharedCopy",
        "testCapturedDeletionConfirmationReadsTheSharedCopyAndDismissalCancelsOnlyItsRequest",
        "testUntypedDeletionConfirmationFallsBackToTheSharedTitle",
    ]
    assert re.findall(r"\bfunc (test\w+)\(", source.read_text()) == names
    selected = [names[1]] if (args.diagnose_typed_cancel or args.qualify_typed_native_scene) else names
    nonce = str(uuid4()) if (args.diagnose_typed_cancel or args.qualify_typed_native_scene) else None
    inputs = [source, root / "Package.swift", Path(__file__).resolve()]
    before = {str(path): sha256(path.read_bytes()).hexdigest() for path in inputs}
    out = args.output.resolve()
    assert not out.exists(), "Use a fresh output directory; preserve previous failures"
    out.mkdir(parents=True)
    (out / "input-binding.json").write_text(json.dumps(before, indent=2) + "\n")
    host = "OpenCinePlaybackLabelsSimulated"
    target = "OpenCinePlaybackLabelsHostedTests"
    scheme = "OpenCinePlaybackLabelsHosted"
    host_source = out / "SimulatedHost.swift"
    host_source.write_text(
        "import SwiftUI\n"
        "@main struct OpenCinePlaybackLabelsSimulated: App {\n"
        "    var body: some Scene { WindowGroup { Text(\"SIMULATED playback label host\") } }\n"
        "}\n"
    )
    spec = {
        "name": scheme,
        "options": {"deploymentTarget": {"iOS": "17.0"}},
        "settings": {"base": {
            "SWIFT_VERSION": "6.0", "GENERATE_INFOPLIST_FILE": "YES",
            "TARGETED_DEVICE_FAMILY": "1,2",
        }},
        "packages": {"OpenCine": {"path": str(root)}},
        "targets": {
            host: {
                "type": "application", "platform": "iOS", "sources": [str(host_source)],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.opencine.simulated.playbacklabels",
                    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
                    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                }},
            },
            target: {
                "type": "bundle.unit-test", "platform": "iOS", "sources": [str(source)],
                "dependencies": [{"target": host}] + [
                    {"package": "OpenCine", "product": name} for name in [
                        "MonitorPresentation", "MonitorUI", "OpenCineMedia",
                        "OpenCineHostedAccessibility", "OpenCineHostedTestSupport",
                    ]
                ],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.opencine.simulated.playbacklabels.tests",
                    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/" + host + ".app/" + host,
                    "BUNDLE_LOADER": "$(TEST_HOST)",
                }},
            },
        },
        "schemes": {scheme: {
            "build": {"targets": {host: ["test"], target: ["test"]}},
            "test": {"config": "Debug", "macroExpansion": host, "targets": [{
                "name": target, "parallelizable": False, "randomExecutionOrder": False,
            }]},
        }},
    }
    spec_path = out / "project.json"
    if nonce:
        import importlib.util
        loader = importlib.util.spec_from_file_location(
            "legacy_hosted_input", root / "scripts/ios-playback-label-legacy-input.py")
        module = importlib.util.module_from_spec(loader)
        loader.loader.exec_module(module)
        module.generated_sources(root, out)
        spec["targets"][target]["sources"] += [
            str(out / "LegacyHostedNativeInput.swift"), str(out / "NativeCancelReceipt.swift")]
        key = "OPENCINE_TYPED_CANCEL_QUALIFIER" if args.qualify_typed_native_scene else "OPENCINE_TYPED_CANCEL_DIAGNOSTIC"
        spec["schemes"][scheme]["test"]["environmentVariables"] = {key: nonce}
    spec_path.write_text(json.dumps(spec, indent=2) + "\n")
    subprocess.run([
        "xcodegen", "generate", "--spec", str(spec_path), "--project", str(out),
    ], check=True)
    project = out / (scheme + ".xcodeproj/project.pbxproj")
    if nonce:
        scheme_text = (project.parent / "xcshareddata/xcschemes" / (scheme + ".xcscheme")).read_text()
        assert key in scheme_text and nonce in scheme_text
    project_hash = sha256(project.read_bytes()).hexdigest()
    command = [
        "xcodebuild", "-project", str(project.parent), "-scheme", scheme,
        "-destination", "platform=iOS Simulator,id=" + args.simulator_id,
        "-derivedDataPath", str(args.derived_data.resolve()), "-jobs", str(args.jobs),
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
        "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120",
        "-maximum-test-execution-time-allowance", "170",
        "-resultBundlePath", str(out / "result.xcresult"), "CODE_SIGNING_ALLOWED=NO",
        "-only-testing:" + target + "/MonitorPlaybackAccessibilityLabelTests"
        + ("/" + selected[0] if nonce else ""), "test",
    ]
    (out / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    print(json.dumps({"SIMULATEDApplicationHostedCommand": command}), flush=True)
    log_path = out / "xcodebuild.log"
    start = last_progress = time.monotonic()
    size = 0
    interruption = None
    observed = False
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        while process.poll() is None:
            time.sleep(1)
            now = time.monotonic()
            current = log_path.stat().st_size
            if current != size:
                size = current
                last_progress = now
            if nonce and not observed:
                try:
                    observed = observe_typed_request(log_path.read_text(errors="replace"), nonce, args.simulator_id, out,
                                                     qualifier=args.qualify_typed_native_scene)
                except Exception as error:
                    observed = True
                    (out / "native-observation.json").write_text(json.dumps({
                        "inputSent": False, "stopReason": "Read-only observation failed: " + repr(error),
                    }, indent=2) + "\n")
            if now - last_progress > 180 or now - start > 2400:
                interruption = "no-progress180" if now - last_progress > 180 else "wall2400"
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                break
        code = process.wait()
    after = {str(path): sha256(path.read_bytes()).hexdigest() for path in inputs}
    text = log_path.read_text(errors="replace")
    outcomes = {
        name: re.findall(r"Test Case '[^\n]*\b" + re.escape(name) + r"\]' (passed|failed|skipped)", text)
        for name in names
    }
    receipt = {
        "processExit": code, "watchdog": interruption, "namedOutcomes": outcomes,
        "exactThreePasses": all(outcomes[name] == ["passed"] for name in names),
        "selectedMethods": selected,
        "exactSelectedPasses": all(outcomes[name] == ["passed"] for name in selected)
        and all(not outcomes[name] for name in names if name not in selected),
        "typedDiagnostic": args.diagnose_typed_cancel,
        "nativeSceneQualifier": args.qualify_typed_native_scene, "nativeStageObserved": observed,
        "inputSourcesUnchanged": before == after,
        "projectUnchanged": sha256(project.read_bytes()).hexdigest() == project_hash,
        "logSHA256": sha256(log_path.read_bytes()).hexdigest(),
        "scope": "SIMULATED shared rendered labels and actual native confirmation input; physical untested",
    }
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt), flush=True)
    if code:
        return code
    assert receipt["exactSelectedPasses"] and receipt["inputSourcesUnchanged"] and receipt["projectUnchanged"], receipt
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
