#!/usr/bin/env python3
"""Attach accepted native input proof to the original richer-owner hosted whole gate.

The proof root is a read-only, explicitly selected checkout of the accepted a11y
machinery. Its three templates are hash-bound before generation. No counterpart
screen is launched: the original hosted fixture owns its gallery, player and request.
Invoke through the program heavy.sh wrapper with a task-private simulator.
"""
from hashlib import sha256
from pathlib import Path
from uuid import UUID, uuid4
import argparse
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True

RICH = "testActualCapturedDeleteDialogKeepsRelatedCopyMessageAndCancelSendsNoIO"
SUITES = ["MonitorOperatorPlaybackOptionsTests", "MonitorPortraitStatusGeometryTests", "MonitorMediaOpeningAdmissionTests"]
LEGACY_SHA = "fb19a66526b781017e95cd31b640c1caefc67a7d7e0a7d6588dfe0717e27afbf"

# Exact original named-method enrollment, in source order, carried from the
# preserved baseline WIP runner. Count checks alone would admit renamed,
# swapped or missing-and-replaced methods that keep the same per-suite totals.
ENROLLMENT = {
    "MonitorOperatorPlaybackOptionsTests": [
        "testGalleryDefaultActivationOpensWhileSelectionAndFavoriteRemainIndependent",
        "testRatingAnchorAlignsWithPlaybackActionsInLandscapeAndPortrait",
        "testActualCapturedDeleteDialogKeepsRelatedCopyMessageAndCancelSendsNoIO",
        "testSupportedOptionsChangeTheSuppliedAssistWithoutReplacingThePlayer",
        "testAbsentStoresAndPlaybackSuppliersOmitUnavailableControls",
        "testExplicitUnknownItemDoesNotBorrowThePlayerOrEffectSignal",
        "testActualMenuActionsReadTheSavedHapticsPreferenceEachTime",
    ],
    "MonitorPortraitStatusGeometryTests": [
        "testObservedSeparateReadoutsKeepTheirFullValuesAndEightPointClearance",
        "testCompactReadoutPreservesThePreferredCenteredClock",
        "testNarrowViewportUsesAnIntrinsicSecondRowWithoutMovingTheScreenTopAnchor",
        "testRightToLeftKeepsTheSameValuesAndLogicalSideSeparation",
    ],
    "MonitorMediaOpeningAdmissionTests": [
        "testRefusedVideoKeepsUnavailableCloseAndReturnsToGallery",
        "testRefusedPhotoKeepsUnavailableCloseAndReturnsToGallery",
        "testRetiredVideoKeepsUnavailableCloseAndReturnsToGallery",
        "testRetiredPhotoKeepsUnavailableCloseAndReturnsToGallery",
        "testReplacedVideoSourceKeepsUnavailableCloseAndReturnsToGallery",
        "testReplacedPhotoSourceKeepsUnavailableCloseAndReturnsToGallery",
        "testRefreshPreservesCapturedVideoRecordPlaylistAndAdmission",
        "testRefreshPreservesCapturedPhotoRecordAndAdmission",
        "testCapturedDeletionRetainsEnteredWorkAndShowsAdmittedSuccessor",
        "testAdmittedSuccessorStaysVisibleAfterGalleryRelist",
    ],
}


def assert_enrollment(names):
    for suite in SUITES:
        assert names.get(suite) == ENROLLMENT[suite], (suite, names.get(suite))

OWNER = r'''
struct RicherOwnerObservation: Codable, Equatable {
    let requestID: UUID?
    let authorityID: UUID?
    let captures: Int
    let authorityCurrent: Bool?
    let requestCurrent: Bool?
    let sameOwner: Bool
    let itemCurrent: Bool
    let galleryCurrent: Bool
    let sameDirectory: Bool
    let sameGeneration: Bool
    let performerCalls: Int

    var retainedOwner: Bool {
        requestID != nil && authorityID != nil && captures == 1 && sameOwner && itemCurrent
            && galleryCurrent && sameDirectory && sameGeneration && performerCalls == 0
    }
    var admitted: Bool { retainedOwner && authorityCurrent == true && requestCurrent == true }
    var retired: Bool { retainedOwner && authorityCurrent == false && requestCurrent == false }
}
'''



PASSIVE = r"""
// The richer screen has one decorative compositor, deliberately excluded from AX and touch.
// Unknown hidden semantic subtrees remain opaque; only this complete public certificate admits it.
struct RicherPassiveBackground: Codable, Equatable {
    let identity: String
    let frame: NativeCancelRect
    let interactive: Bool
    let accessibilityHidden: Bool
    let accessibilityElement: Bool
    let nativeViews: Int
    let controls: Int
    let accessibilityNodes: Int
    let customActions: Int
    let enabledGestures: Int
    let nonFiniteAlpha: Int
    let walkAtLimit: Bool
    let hitIdentity: String?

    func admitted(window: NativeCancelRect, point: NativeSystemPoint) -> Bool {
        !interactive && accessibilityHidden && !accessibilityElement && nativeViews > 0
            && controls == 0 && accessibilityNodes == 0 && customActions == 0
            && enabledGestures == 0 && nonFiniteAlpha == 0 && !walkAtLimit && hitIdentity == nil
            && frame.finite && window.contains(frame) && !frame.contains(point, margin: 1)
    }
}
"""

PASSIVE_OBSERVER = r"""        func passiveBackground(_ object: NSObject) -> RicherPassiveBackground? {
            guard let root = object as? UIVisualEffectView else { return nil }
            var views = 0, controls = 0, nodes = 0, custom = 0, gestures = 0, badAlpha = 0
            var limit = false
            func walk(_ view: UIView) {
                guard views < 5_000 else { limit = true; return }
                views += 1
                if view is UIControl { controls += 1 }
                if view.isAccessibilityElement { nodes += 1 }
                nodes += (view.automationElements ?? []).count + (view.accessibilityElements ?? []).count
                let count = view.accessibilityElementCount()
                if count != NSNotFound && count != 0 { nodes += 1 }
                custom += view.accessibilityCustomActions?.count ?? 0
                gestures += (view.gestureRecognizers ?? []).filter(\.isEnabled).count
                if !view.alpha.isFinite { badAlpha += 1 }
                for child in view.subviews { walk(child) }
            }
            walk(root)
            let local = root.convert(point, from: window)
            let hit = root.hitTest(local, with: nil)
            return RicherPassiveBackground(
                identity: identity(root),
                frame: NativeCancelRect(root.convert(root.bounds, to: window.screen.coordinateSpace)),
                interactive: root.isUserInteractionEnabled,
                accessibilityHidden: root.accessibilityElementsHidden,
                accessibilityElement: root.isAccessibilityElement, nativeViews: views,
                controls: controls, accessibilityNodes: nodes, customActions: custom,
                enabledGestures: gestures, nonFiniteAlpha: badAlpha, walkAtLimit: limit,
                hitIdentity: hit.map(identity))
        }"""



def load_module(name, path):
    loader = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(loader)
    loader.loader.exec_module(module)
    return module


def replace_once(text, old, new):
    assert text.count(old) == 1, (old[:100], text.count(old))
    return text.replace(old, new, 1)


def generate(proof_root, out):
    path = proof_root / "scripts/ios-playback-label-legacy-input.py"
    assert sha256(path.read_bytes()).hexdigest() == LEGACY_SHA
    legacy = load_module("accepted_legacy_input", path)
    legacy.generated_sources(proof_root, out)
    # Keep all native ownership, hit routing, feed exclusion and fixed-point predicates.
    # Only the actual richer fixture's declared content and public owner observations differ.
    p = out / "NativeCancelReceipt.swift"
    text = p.read_text().replace("Its camera master and backup copies", "The camera master and backup copies")
    text = replace_once(text, '        "Forward 15 seconds", "Conform preview", "Mute", "Loop playback", "Hide playback controls",',
                        '        "Forward 15 seconds", "Conform preview", "Mute", "Loop playback", "Hide playback controls",\n        "Peaking", "Show all View Assist tools",')
    text = text.replace('"Previous clip", "Next clip", ', '').replace('"Back 15 seconds", "Play",', '"Back 15 seconds", "Pause",')
    text = replace_once(text, "    let customActions: Int\n", "    let customActions: Int\n    let customActionNames: [String]\n")
    text = replace_once(text, "    let mode: String\n", "    let mode: String\n    let richerOwner: RicherOwnerObservation\n")
    text = replace_once(text, "$0.customActions != 0 || !$0.frame.finite || !windowFrame.contains($0.frame)",
                        '($0.customActions != ($0.label == "Peaking" ? 1 : 0))\n                || $0.customActionNames != ($0.label == "Peaking" ? ["Options"] : [])\n                || !$0.frame.finite || !windowFrame.contains($0.frame)')
    text = replace_once(text, "    let opaqueObjects: Int\n", "    let opaqueObjects: Int\n    let passiveBackgrounds: [RicherPassiveBackground]\n")
    marker = '    let buttons = background.actionables.filter { $0.kind == "button" }'
    text = replace_once(text, marker, '    if background.passiveBackgrounds.count != 1\n        || background.passiveBackgrounds.contains(where: {\n            !$0.admitted(window: windowFrame, point: proof.pointOnScreen)\n        }) {\n        reasons.append("The richer compositor backdrop lacks complete public passive-input proof")\n    }\n' + "\n" + marker)
    p.write_text(text + OWNER + PASSIVE)

    p = out / "LegacyHostedNativeInput.swift"
    text = p.read_text().replace("UIHostingController<AnyView>", "UIViewController")
    text = replace_once(text, "    let nonce: String\n", "    let ownership: () -> RicherOwnerObservation\n    let nonce: String\n")
    text = replace_once(text, "        cancelled: @escaping () -> [UUID], deleted: @escaping () -> [MonitorPlaybackItemToken]\n",
                        "        cancelled: @escaping () -> [UUID], deleted: @escaping () -> [MonitorPlaybackItemToken],\n        ownership: @escaping () -> RicherOwnerObservation\n")
    text = replace_once(text, "        confirmations = confirmed; cancellations = cancelled; deletions = deleted\n",
                        "        confirmations = confirmed; cancellations = cancelled; deletions = deleted\n        self.ownership = ownership\n")
    text = replace_once(text, '        XCTAssertEqual(env["OPENCINE_NATIVE_UI_MODE"], "legacy-hosted-native-input")',
                        '        XCTAssertEqual(env["OPENCINE_NATIVE_UI_MODE"], "richer-hosted-native-input")')
    start = text.index("    // Derived ONLY")
    end = text.index("\n    init(", start)
    text = text[:start] + '''    // Actual public owner/authority queries, not fabricated cancellation callbacks.
    private var active: [UUID] { ownership().admitted ? [requestID] : [] }
    private var retired: [UUID] { ownership().retired ? [requestID] : [] }
''' + text[end:]
    text = replace_once(text, '            mode: typed ? "legacy-typed-popover" : "legacy-untyped-popover",',
                        '            mode: typed ? "legacy-typed-popover" : "legacy-untyped-popover",\n            richerOwner: ownership(),')
    text = replace_once(text, "frame: NativeCancelRect(object.accessibilityFrame), customActions: custom))",
                        "frame: NativeCancelRect(object.accessibilityFrame), customActions: custom,\n                    customActionNames: (object.accessibilityCustomActions ?? []).map(\\.name)))")
    text = replace_once(text, "        var opaque = 0\n", "        var opaque = 0\n        var passiveBackgrounds: [RicherPassiveBackground] = []\n")
    text = replace_once(text, "        func children(_ object: NSObject) -> [NSObject] {", PASSIVE_OBSERVER + "\n        func children(_ object: NSObject) -> [NSObject] {")
    text = replace_once(text, "            guard !object.accessibilityElementsHidden else {\n                opaque += 1", "            guard !object.accessibilityElementsHidden else {\n                if let passive = passiveBackground(object) {\n                    passiveBackgrounds.append(passive)\n                    if passive.admitted(window: NativeCancelRect(window.convert(window.bounds, to: window.screen.coordinateSpace)), point: NativeSystemPoint(window.convert(point, to: window.screen.coordinateSpace))) { return }\n                }\n                opaque += 1")
    text = replace_once(text, "publicWalkAtLimit: atLimit, opaqueObjects: opaque)", "publicWalkAtLimit: atLimit, opaqueObjects: opaque, passiveBackgrounds: passiveBackgrounds)")
    p.write_text(text)
    p = out / "LegacyHostedNativeInputUITests.swift"
    text = p.read_text().replace("import OpenCineHostedTestSupport\n", "")
    text = text.replace("testSupplyNativeInputToBothOriginalDeletionCases", "testSupplyNativeInputToOriginalRicherOwner")
    text = text.replace('== "legacy-hosted-native-input"', '== "richer-hosted-native-input"')
    text = text.replace('for phase in ["typed", "untyped"]', 'for phase in ["typed"]')
    text = text.replace('MonitorPlaybackCopy.deleteConfirmationTitle', '"Delete this clip from the camera?"')
    text = text.replace('MonitorPlaybackCopy.deleteConfirm', '"Delete"').replace('MonitorPlaybackCopy.deleteCancel', '"Cancel"')
    text = text.replace(').label == "SIMULATED clip"', ').label == "SIMULATED-options.mov"')
    text = text.replace('&& value.cancelled == (self.typed ? [initial.requestID] : [])',
                        '&& value.cancelled.isEmpty && self.ownerReady(value, initial: initial, retired: true)')
    text = replace_once(text, "            && value.item == initial.item\n",
                        "            && value.item == initial.item && ownerReady(value, initial: initial, retired: false)\n")
    marker = "    private func samePresentation("
    helpers = '''    private func ownerReady(_ value: NativeCancelReceipt, initial: NativeCancelReceipt, retired: Bool) -> Bool {
        value.richerOwner.requestID == value.requestID
            && value.richerOwner.requestID == initial.richerOwner.requestID
            && value.richerOwner.authorityID == initial.richerOwner.authorityID
            && (retired ? value.richerOwner.retired : value.richerOwner.admitted)
    }

'''
    assert marker in text
    text = text.replace(marker, helpers + marker, 1)
    text = replace_once(text, '            popovers.element(boundBy: 0).frame == proof.presentationFrameOnScreen.rect,',
        '            nativeExternalControlFrameMatches(NativeCancelRect(popovers.element(boundBy: 0).frame), proof.presentationFrameOnScreen, scale: proof.screenScale),\n            !popovers.element(boundBy: 0).frame.insetBy(dx: -1, dy: -1).contains(proof.pointOnScreen.point),')
    p.write_text(text)
    support = proof_root / "Sources/OpenCineHostedTestSupport/HostedCondition.swift"
    (out / "HostedCondition.swift").write_bytes(support.read_bytes())
    return legacy


def run(args):
    root = Path(__file__).resolve().parents[1]
    proof = args.proof_root.resolve(strict=True)
    out = args.output.resolve()
    assert not out.exists(), "Preserve previous raw results; select a fresh output directory"
    out.mkdir(parents=True)
    legacy = generate(proof, out)
    sources = [root / "Tests/OpenCineCameraControlsHostedTests" / (suite + ".swift") for suite in SUITES]
    names = {p.stem: re.findall(r"\bfunc (test\w+)\(", p.read_text()) for p in sources}
    assert_enrollment(names)
    assert RICH in names[SUITES[0]]
    inputs = sources + [Path(__file__), root / "scripts/ios-playback-options-hosted-test.py", root / "Package.swift",
        args.project_spec.resolve(strict=True), args.host_entitlements.resolve(strict=True),
        proof / "scripts/ios-playback-label-legacy-input.py", proof / "scripts/ios-playback-label-hosted-test.py",
        proof / "Sources/OpenCineHostedTestSupport/HostedCondition.swift"]
    inputs += list((proof / "scripts/ios-playback-label-native-system-dismissal").glob("*.swift"))
    before = {str(p): sha256(p.read_bytes()).hexdigest() for p in inputs}
    nonce = str(uuid4())
    prepared = {"bundleID": "com.opencapture.openpfhhost.simulated",
        "runnerBundleID": "com.opencapture.opencine.playbackoptions.inputreader.xctrunner",
        "nonce": nonce, "sourceSeal": sha256(json.dumps(before, sort_keys=True).encode()).hexdigest()}
    (out / "input-binding.json").write_text(json.dumps({"inputs": before, **prepared}, indent=2) + "\n")
    if args.generate_only:
        return 0
    UUID(args.simulator_id)
    dd = args.derived_data.resolve()
    cache = dd.parent
    for name in ["tmp", "modules", "packages", "package-cache"]:
        (cache / name).mkdir(parents=True, exist_ok=True)
    device = (Path.home() / "Library/Developer/CoreSimulator/Devices" / args.simulator_id).resolve(strict=True)
    for p in [root, out, cache, device, Path("/Volumes/SuttonCap")]:
        assert shutil.disk_usage(p).free >= 20 * 2**30, str(p)
    os.environ.update(TMPDIR=str(cache / "tmp") + "/", CLANG_MODULE_CACHE_PATH=str(cache / "modules"),
        SWIFTPM_MODULECACHE_OVERRIDE=str(cache / "modules"), PYTHONDONTWRITEBYTECODE="1")
    target, reader, scheme = "OpenCinePlaybackOptionsHostedTests", "LegacyHostedNativeInputUITests", "OpenCinePlaybackOptionsHosted"
    dependencies = [{"package": "OpenCine", "product": p} for p in ["MonitorPresentation", "MonitorUI", "OpenCineAppKit", "OpenCineHostedAccessibility", "OpenCineCameraControls", "OpenCineMedia"]]
    # Stable owned compiler paths avoid recompiling every unchanged package for each receipt.
    # Every attempt retains exact generated bytes beside its immutable raw results.
    build_root = cache / "generated"
    build_root.mkdir(exist_ok=True)
    for generated_source in out.glob("*.swift"):
        shutil.copy2(generated_source, build_root / generated_source.name)
    support = [str(build_root / name) for name in ["NativeCancelReceipt.swift", "HostedCondition.swift"]]
    spec = {"name": scheme, "include": [{"path": str(args.project_spec.resolve()), "relativePaths": True}],
        "packages": {"OpenCine": {"path": str(root)}}, "targets": {
            args.host_target: {"settings": {"base": {"CODE_SIGN_ENTITLEMENTS": str(args.host_entitlements.resolve())}}},
            target: {"type": "bundle.unit-test", "platform": "iOS", "sources": [str(p) for p in sources] + support + [str(build_root / "LegacyHostedNativeInput.swift")],
                "dependencies": [{"target": args.host_target}] + dependencies,
                "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.opencine.playbackoptions.hostedtests", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/" + args.host_target + ".app/" + args.host_target, "BUNDLE_LOADER": "$(TEST_HOST)"}}},
            reader: {"type": "bundle.ui-testing", "platform": "iOS", "sources": support + [str(build_root / "LegacyHostedNativeInputUITests.swift")],
                "dependencies": [{"target": args.host_target}] + dependencies,
                "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.opencapture.opencine.playbackoptions.inputreader", "TEST_TARGET_NAME": args.host_target}}}},
        "schemes": {scheme: {"build": {"targets": {t: ["test"] for t in [args.host_target, target, reader]}},
            "test": {"config": "Debug", "macroExpansion": args.host_target,
                "environmentVariables": {"OPENCINE_NATIVE_UI_NONCE": nonce, "OPENCINE_NATIVE_UI_SOURCE_SEAL": prepared["sourceSeal"], "OPENCINE_NATIVE_UI_BUNDLE_ID": prepared["bundleID"], "OPENCINE_NATIVE_UI_MODE": "richer-hosted-native-input"},
                "targets": [{"name": t, "parallelizable": False, "randomExecutionOrder": False} for t in [target, reader]]}}}}
    (out / "project.json").write_text(json.dumps(spec, indent=2) + "\n")
    subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.json"), "--project", str(build_root)], check=True)
    project = build_root / (scheme + ".xcodeproj")
    generated = {str(p): sha256(p.read_bytes()).hexdigest() for p in out.glob("*.swift")}
    for source in build_root.glob("*.swift"):
        generated[str(source)] = sha256(source.read_bytes()).hexdigest()
    shutil.copy2(project / "project.pbxproj", out / "compiled-project.pbxproj")
    generated[str(project / "project.pbxproj")] = sha256((project / "project.pbxproj").read_bytes()).hexdigest()
    original = load_module("accepted_hosted_runner", proof / "scripts/ios-playback-label-hosted-test.py")
    validator = original.NativeUIReceiptBridge(args.simulator_id, prepared, out)
    bridge_records = []
    last_sequence = 0

    def bridge(log):
        nonlocal last_sequence
        markers = set(re.findall(r"SIMULATED_NATIVE_UI_INBOX:([^\r\n]+)", log))
        assert len(markers) <= 1
        if not markers:
            return
        inbox = Path(next(iter(markers)))
        container = validator.container_for(inbox, prepared["runnerBundleID"])
        assert inbox.resolve() == (container / "tmp" / ("SIMULATED-native-reader-" + nonce) / "app-receipt.json").resolve()
        assert inbox.parent.is_dir() and not inbox.is_symlink()
        hosts = []
        for child in validator.private_root.iterdir():
            metadata = child / ".com.apple.mobile_container_manager.metadata.plist"
            if metadata.is_file() and plistlib.loads(metadata.read_bytes()).get("MCMMetadataIdentifier") == prepared["bundleID"]:
                hosts.append(child)
        assert len(hosts) <= 1
        if not hosts:
            return
        source = hosts[0] / "tmp" / ("SIMULATED-native-cancel-" + nonce) / "typed.json"
        if not source.is_file():
            return
        validator.container_for(source, prepared["bundleID"])
        assert not source.is_symlink()
        data = source.read_bytes()
        value = json.loads(data)
        assert value["schema"] == 1 and value["nonce"] == nonce and value["sourceSeal"] == prepared["sourceSeal"]
        assert value["bundleID"] == prepared["bundleID"] and UUID(value["simulatorID"]) == UUID(args.simulator_id)
        assert value["mode"] == "legacy-typed-popover" and value["processID"] > 0
        if value["sequence"] <= last_sequence:
            return
        archive = out / "app-receipts" / (str(value["sequence"]) + ".json")
        archive.parent.mkdir(exist_ok=True)
        archive.write_bytes(data)
        destination = inbox.with_name("typed.json")
        assert not destination.is_symlink()
        temporary = inbox.with_name(".bridge-typed-" + nonce)
        temporary.write_bytes(data); temporary.chmod(0o400); temporary.replace(destination)
        assert destination.read_bytes() == archive.read_bytes()
        last_sequence = value["sequence"]
        bridge_records.append({"sequence": last_sequence, "sha256": sha256(data).hexdigest(), "source": str(source), "retained": str(archive), "readerCopy": str(destination)})

    common = ["-jobs", str(args.jobs), "-destination", "platform=iOS Simulator,id=" + args.simulator_id, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "300", "CODE_SIGNING_ALLOWED=NO", "SWIFT_STRICT_CONCURRENCY=complete"]
    readers, commands = {}, {}
    began = time.monotonic()

    def spawn(label, command):
        commands[label] = command
        stream = (out / (label + ".log")).open("w")
        process = subprocess.Popen(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        readers[label] = {"process": process, "stream": stream, "size": 0, "last": time.monotonic(), "began": time.monotonic()}
        return process

    def poll(label):
        row = readers[label]
        process = row["process"]
        now = time.monotonic()
        size = (out / (label + ".log")).stat().st_size
        if size != row["size"]:
            row["size"] = size; row["last"] = now
        if process.poll() is None and (now - row["last"] > 180 or now - began > 2400 or (label == "accessibility-boot" and now - row["began"] > 180)):
            row["watchdog"] = "boot180" if label == "accessibility-boot" and now - row["began"] > 180 else "no-progress180" if now - row["last"] > 180 else "wall2400"
            legacy.stop_readers({label: row})
        return process.poll()

    execution_error = None
    try:
        build = spawn("build", ["xcodebuild", "-project", str(project), "-scheme", scheme, "-derivedDataPath", str(dd), "-clonedSourcePackagesDirPath", str(cache / "packages"), "-packageCachePath", str(cache / "package-cache"), "-skipPackageUpdates", "-disableAutomaticPackageResolution", "MODULE_CACHE_DIR=" + str(cache / "modules"), *common, "build-for-testing"])
        while poll("build") is None:
            time.sleep(1)
        if build.wait() == 0:
            # UI-test teardown resets the private store. Bootstrap immediately before this
            # original unit host starts, using the repository's shutdown/write/boot recipe.
            assert not legacy.group_members(build.pid)
            devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))["devices"]
            current = next(d for group in devices.values() for d in group if d["udid"] == args.simulator_id)
            if current["state"] != "Shutdown":
                subprocess.run(["xcrun", "simctl", "shutdown", args.simulator_id], check=True, timeout=180)
            preference = device / "data/Library/Preferences/com.apple.Accessibility.plist"
            original = preference.read_bytes()
            (out / "accessibility-before.plist").write_bytes(original)
            enabled = dict(plistlib.loads(original), ApplicationAccessibilityEnabled=True, AccessibilityEnabled=True)
            preference.write_bytes(plistlib.dumps(enabled, fmt=plistlib.FMT_BINARY))
            (out / "accessibility-enabled.plist").write_bytes(preference.read_bytes())
            boot = spawn("accessibility-boot", ["xcrun", "simctl", "bootstatus", args.simulator_id, "-b"])
            while poll("accessibility-boot") is None:
                time.sleep(0.1)
            assert boot.wait() == 0, "Original private accessibility boot must succeed before unit launch"
            assert not legacy.group_members(boot.pid)
            runs = list((dd / "Build/Products").glob("*.xctestrun"))
            assert len(runs) == 1
            base = ["xcodebuild", "-xctestrun", str(runs[0]), *common]
            spawn("original-whole", [*base, "-derivedDataPath", str(cache / "dd-unit"), "-resultBundlePath", str(out / "original-whole.xcresult"), *["-only-testing:" + target + "/" + suite for suite in SUITES], "test-without-building"])
            # The original media-opening suite precedes playback. Attach during the actual
            # playback-suite entry so its thirty-second receipt wait is not spent on other cases.
            while poll("original-whole") is None:
                original_log = (out / "original-whole.log").read_text(errors="replace")
                if "Test Suite 'MonitorOperatorPlaybackOptionsTests' started" in original_log:
                    spawn("ui-reader", [*base, "-derivedDataPath", str(cache / "dd-ui"), "-resultBundlePath", str(out / "ui-reader.xcresult"), "-only-testing:" + reader + "/" + reader + "/testSupplyNativeInputToOriginalRicherOwner", "test-without-building"])
                    break
                time.sleep(0.1)
            while any(poll(label) is None for label in readers):
                if "ui-reader" in readers:
                    bridge((out / "ui-reader.log").read_text(errors="replace"))
                time.sleep(0.1)
    except BaseException as error:
        execution_error = repr(error)
        (out / "execution-error.json").write_text(json.dumps({"error": execution_error}, indent=2) + "\n")
    finally:
        legacy.stop_readers(readers)
    results = {}
    for label, row in readers.items():
        process = row["process"]
        code = process.wait(); row["stream"].close()
        results[label] = {"pid": process.pid, "pgid": process.pid, "exit": code, "watchdog": row.get("watchdog"), "remainingGroup": legacy.group_members(process.pid)}
    assert all(not r["remainingGroup"] for r in results.values()), results
    # Record inner outcomes even if device settlement later encounters an external state change.
    (out / "process-outcomes.json").write_text(json.dumps(results, indent=2) + "\n")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))["devices"]
    device_info = next(d for group in devices.values() for d in group if d["udid"] == args.simulator_id)
    if device_info["state"] != "Shutdown":
        subprocess.run(["xcrun", "simctl", "shutdown", args.simulator_id], check=True)
    after = {str(p): sha256(p.read_bytes()).hexdigest() for p in inputs}
    log = (out / "original-whole.log").read_text(errors="replace") if "original-whole" in readers else ""
    outcomes = {name: re.findall(r"Test Case '[^\n]*\b" + re.escape(name) + r"\]' (passed|failed|skipped)", log) for suite in SUITES for name in names[suite]}
    ui_log = (out / "ui-reader.log").read_text(errors="replace") if "ui-reader" in readers else ""
    native = [json.loads(v) for v in re.findall(r"LEGACY_NATIVE_INPUT_OUTCOME:([^\r\n]+)", ui_log)]
    receipt = {"executionError": execution_error, "results": results, "commands": commands, "namedOutcomes": outcomes, "nativeOutcomes": native, "exactOriginal21Passes": len(outcomes) == 21 and all(v == ["passed"] for v in outcomes.values()), "inputSourcesUnchanged": before == after, "generatedSourcesUnchanged": all(sha256(Path(p).read_bytes()).hexdigest() == h for p, h in generated.items()), "bridgeRecords": bridge_records, "simulatorShutdown": True, "userdataRetained": str(device), "physical": "untested"}
    passed = execution_error is None and set(results) == {"build", "accessibility-boot", "ui-reader", "original-whole"} and all(r["exit"] == 0 and not r["watchdog"] for r in results.values())
    passed &= receipt["exactOriginal21Passes"] and receipt["inputSourcesUnchanged"] and receipt["generatedSourcesUnchanged"]
    passed &= len(native) == 1 and native[0]["qualified"] and native[0]["tapInvoked"]
    receipt["passed"] = bool(passed)
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"passed": bool(passed), "results": results, "namedOutcomes": outcomes, "nativeOutcomes": [{k: v[k] for k in ["phase", "tapInvoked", "qualified"]} for v in native]}), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--proof-root", type=Path, required=True)
    parser.add_argument("--project-spec", type=Path, required=True)
    parser.add_argument("--host-target", default="OpenPfhHostSimulated")
    parser.add_argument("--host-entitlements", type=Path, required=True)
    parser.add_argument("--simulator-id")
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--generate-only", action="store_true")
    parsed = parser.parse_args()
    assert parsed.jobs > 0
    raise SystemExit(run(parsed))
