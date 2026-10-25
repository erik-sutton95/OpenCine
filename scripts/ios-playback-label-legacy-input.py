#!/usr/bin/env python3
"""Enroll native input in the original three hosted playback cases, with no second scenario.

The accepted public native proof is compiled verbatim from its source-bound templates.
Only observation ownership and the input reader's original-case predicates are adapted.
No product code, CI lifecycle file or accepted counterpart scenario is changed here.
"""
from pathlib import Path
from hashlib import sha256
from uuid import UUID, uuid4
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import time

NAMES = [
    'testChromeTransportScrubberAndInfoReadTheSharedCopy',
    'testCapturedDeletionConfirmationReadsTheSharedCopyAndDismissalCancelsOnlyItsRequest',
    'testUntypedDeletionConfirmationFallsBackToTheSharedTitle',
]
FROZEN = {
    'NativeCancelReceipt.swift': '748421482fd6f26e78293f9a9b1071237edd5332079169fbf52b3305bfd2af63',
    'NativeCancelUITests.swift': '890277299b071f0889acca2e5df3f1c9c9d561d74c9d397ae68cf44abb8bc112',
    'SimulatedNativeCancelHost.swift': 'ee2ed248c02d74d4dfddf52ca4a29a018d2d31fc4cb2b5aef6c80cff58dc0190',
}

OBSERVER = r'''import MonitorPresentation
import MonitorUI
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

@MainActor final class LegacyPlaybackGeometry {
    var value: MonitorPlaybackPictureGeometry?
}

// An observer of the ORIGINAL fixture. It creates no screen, window or request and sends no input.
@MainActor final class LegacyHostedNativeInput: NSObject {
    let host: UIHostingController<AnyView>!
    let window: UIWindow
    let item: MonitorPlaybackItemToken
    let geometry: LegacyPlaybackGeometry
    let requestID: UUID
    let typed: Bool
    let captured: () -> [MonitorPlaybackItemToken]
    let captures: () -> Int
    let currentRequest: () -> UUID?
    let confirmations: () -> [UUID]
    let cancellations: () -> [UUID]
    let deletions: () -> [MonitorPlaybackItemToken]
    let nonce: String
    let sourceSeal: String
    let simulatorID: String
    let receiptURL: URL
    private var observedDialog: UIAlertController?
    private var timer: Timer?
    private var sequence: UInt64 = 0
    private var observedGeometry: MonitorPlaybackPictureGeometry? { geometry.value }
    private var capturedItems: [MonitorPlaybackItemToken] { captured() }
    private var captureRequestIDs: [UUID] {
        typed && captures() == 1 && currentRequest() == requestID ? [requestID] : []
    }
    private var confirmed: [UUID] { confirmations() }
    private var cancelled: [UUID] { cancellations() }
    private var deleted: [MonitorPlaybackItemToken] { deletions() }
    // Derived ONLY from the original recorder's actual callbacks, never input or teardown.
    private var active: [UUID] {
        typed && captureRequestIDs == [requestID] && cancelled.isEmpty && confirmed.isEmpty
            ? [requestID] : []
    }
    private var retired: [UUID] {
        typed && captureRequestIDs == [requestID]
            && (cancelled == [requestID] || confirmed == [requestID]) ? [requestID] : []
    }

    init(
        host: UIHostingController<AnyView>, window: UIWindow, item: MonitorPlaybackItemToken,
        geometry: LegacyPlaybackGeometry, request: UUID?,
        capturedItems: @escaping () -> [MonitorPlaybackItemToken], captures: @escaping () -> Int,
        currentRequest: @escaping () -> UUID?, confirmed: @escaping () -> [UUID],
        cancelled: @escaping () -> [UUID], deleted: @escaping () -> [MonitorPlaybackItemToken]
    ) throws {
        self.host = host; self.window = window; self.item = item; self.geometry = geometry
        typed = request != nil
        // Untyped has NO captured request. Its item-owner token binds observation only;
        // all captured/cancelled/active/retired request arrays must remain empty.
        requestID = request ?? item.owner
        captured = capturedItems; self.captures = captures; self.currentRequest = currentRequest
        confirmations = confirmed; cancellations = cancelled; deletions = deleted
        let env = ProcessInfo.processInfo.environment
        nonce = try XCTUnwrap(env["OPENCINE_NATIVE_UI_NONCE"])
        sourceSeal = try XCTUnwrap(env["OPENCINE_NATIVE_UI_SOURCE_SEAL"])
        simulatorID = try XCTUnwrap(env["SIMULATOR_UDID"])
        _ = try XCTUnwrap(UUID(uuidString: nonce))
        _ = try XCTUnwrap(UUID(uuidString: simulatorID))
        XCTAssertEqual(env["OPENCINE_NATIVE_UI_MODE"], "legacy-hosted-native-input")
        XCTAssertEqual(env["OPENCINE_NATIVE_UI_BUNDLE_ID"], Bundle.main.bundleIdentifier)
        XCTAssertEqual(sourceSeal.count, 64)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            NativeCancelContract.receiptPrefix + nonce, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        receiptURL = directory.appendingPathComponent(typed ? "typed.json" : "untyped.json")
        super.init()
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(observe),
                          userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        observe()
    }

    func stop() { timer?.invalidate(); timer = nil }
// ACCEPTED_OBSERVATION_METHODS
}
'''

# A real application scene without a screen: the fixture owns the only window, so no later
# application window can come forward and take the reader's native tap. Mirrors the accepted
# SIMULATED native cancellation host's delegate pair (SimulatedNativeCancelHost.swift).
HOST_SOURCE = r'''import UIKit

@main
@MainActor
final class OpenCinePlaybackLabelsSimulated: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "SIMULATED playback label host", sessionRole: session.role)
        configuration.delegateClass = OpenCinePlaybackLabelsSimulatedScene.self
        return configuration
    }
}

@MainActor
final class OpenCinePlaybackLabelsSimulatedScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}
'''

UI_BODY = r'''    private var expectedTitle = ""
    private var expectedMessage: String?
    private var typed = true

    // Input only: attaches to the original hosted bundle; never launch, activate or open Delete.
    func testSupplyNativeInputToBothOriginalDeletionCases() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        nonce = try XCTUnwrap(env["OPENCINE_NATIVE_UI_NONCE"])
        sourceSeal = try XCTUnwrap(env["OPENCINE_NATIVE_UI_SOURCE_SEAL"])
        bundleID = try XCTUnwrap(env["OPENCINE_NATIVE_UI_BUNDLE_ID"])
        simulatorID = try XCTUnwrap(env["SIMULATOR_UDID"])
        try require(env["OPENCINE_NATIVE_UI_MODE"] == "legacy-hosted-native-input", "Explicit legacy mode required")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            NativeCancelContract.readerPrefix + nonce, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        FileHandle.standardOutput.write(Data(("SIMULATED_NATIVE_UI_INBOX:"
            + directory.appendingPathComponent("app-receipt.json").path + "\n").utf8))
        began = Date().timeIntervalSince1970
        let app = XCUIApplication(bundleIdentifier: bundleID)
        for phase in ["typed", "untyped"] {
            typed = phase == "typed"
            expectedTitle = typed ? NativeCancelContract.title : MonitorPlaybackCopy.deleteConfirmationTitle
            expectedMessage = typed ? NativeCancelContract.message : nil
            receiptURL = directory.appendingPathComponent(phase + ".json")
            lastReceipt = nil; lastData = nil; externalActionObservations = []
            var tapInvoked = false
            var preInputSequence: UInt64 = 0
            var preInputHash = ""
            var qualified = false
            defer {
                let record: [String: Any] = [
                    "phase": phase, "nonce": nonce, "sourceSeal": sourceSeal,
                    "tapInvoked": tapInvoked, "qualified": qualified,
                    "preInputSequence": preInputSequence, "preInputSHA256": preInputHash,
                    "finalReceiptSequence": lastReceipt?.sequence ?? 0,
                    "finalReceiptSHA256": lastData.map {
                        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
                    } ?? "", "externalObservations": externalActionObservations,
                ]
                let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                FileHandle.standardOutput.write(Data(("LEGACY_NATIVE_INPUT_OUTCOME:"
                    + String(decoding: data, as: UTF8.self) + "\n").utf8))
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.lifetime = .keepAlways; add(attachment)
            }
            let initial = try await receipt { value in
                value.mode == "legacy-" + phase + "-popover" && value.popup != nil
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            var previous: NativeCancelReceipt?
            let ready = try await receipt(deadline: deadline) { value in
                guard self.popupReady(value, initial: initial, app: app),
                    self.dismissalCoordinate(value, app: app, deadline: deadline) != nil
                else { previous = nil; return false }
                defer { previous = value }
                return previous.map {
                    value.sequence > $0.sequence && self.samePresentation(value, $0)
                        && value.systemDismissal == $0.systemDismissal
                } ?? false
            }
            let coordinate = try XCTUnwrap(dismissalCoordinate(ready, app: app, deadline: deadline))
            let foreground = app.state == .runningForeground
            let point = coordinate.screenPoint
            let current = try XCTUnwrap(readReceipt())
            try require(clock.now < deadline && foreground && current.sequence >= ready.sequence
                && samePresentation(current, ready) && sameRequest(current, initial: initial)
                && current.systemDismissal == ready.systemDismissal && nativeDismissalProof(current)
                && point == current.systemDismissal?.pointOnScreen.point
                && current.foreground && current.keyWindow && current.rootMounted
                && current.rootFillsScene && fresh(current), "Final native input proof failed; no fallback")
            preInputSequence = current.sequence
            preInputHash = SHA256.hash(data: try XCTUnwrap(lastData)).map { String(format: "%02x", $0) }.joined()
            try require(clock.now < deadline, "Original native readiness deadline expired")
            tapInvoked = true
            coordinate.tap()
            let settled = try await receipt { value in
                value.sequence > current.sequence && value.processID == initial.processID
                    && value.sceneID == initial.sceneID && value.windowIdentity == initial.windowIdentity
                    && value.requestID == initial.requestID && value.item == initial.item
                    && value.foreground && value.keyWindow && value.rootMounted && value.rootFillsScene
                    && value.captureRequestIDs == (self.typed ? [initial.requestID] : [])
                    && value.capturedItems == (self.typed ? [initial.item] : [])
                    && value.cancelled == (self.typed ? [initial.requestID] : [])
                    && value.retiredRequestIDs == (self.typed ? [initial.requestID] : [])
                    && value.confirmed.isEmpty && value.deletedCount == 0 && value.activeRequestIDs.isEmpty
                    && value.dialogWindowGone && value.presentingControllerGone && value.popup == nil
            }
            XCTAssertTrue(settled.dialogWindowGone && settled.presentingControllerGone)
            XCTAssertEqual(settled.confirmed, [])
            XCTAssertEqual(settled.deletedCount, 0)
            qualified = true
        }
    }
'''

SAME_REQUEST = r'''    private func sameRequest(_ value: NativeCancelReceipt, initial: NativeCancelReceipt) -> Bool {
        value.processID == initial.processID && value.sceneID == initial.sceneID
            && value.windowIdentity == initial.windowIdentity && value.mode == initial.mode
            && value.orientation == initial.orientation && value.windowFrame == initial.windowFrame
            && value.screenFrame == initial.screenFrame && value.requestID == initial.requestID
            && value.item == initial.item
            && value.captureRequestIDs == (typed ? [initial.requestID] : [])
            && value.capturedItems == (typed ? [initial.item] : [])
            && value.activeRequestIDs == (typed ? [initial.requestID] : [])
            && value.retiredRequestIDs.isEmpty && value.cancelled.isEmpty
            && value.confirmed.isEmpty && value.deletedCount == 0
    }

'''


def generated_sources(root, out):
    templates = root / 'scripts/ios-playback-label-native-system-dismissal'
    text = {}
    for name, digest in FROZEN.items():
        path = templates / name
        assert sha256(path.read_bytes()).hexdigest() == digest, (name, 'Accepted proof changed; review required')
        text[name] = path.read_text()
    # The observer is reused verbatim except the owner's request, typed/untyped mode and receipt
    # filename plumbing. It reads the original fixture rather than constructing another scenario.
    methods = text['SimulatedNativeCancelHost.swift'].split('    @objc private func observe() {', 1)[1]
    methods = '    @objc func observe() {' + methods
    methods = methods.rsplit('\n}', 1)[0]
    methods = methods.replace('requestID: request.id,', 'requestID: requestID,')
    methods = methods.replace('mode: "native-system-popover-dismissal",', 'mode: typed ? "legacy-typed-popover" : "legacy-untyped-popover",')
    (out / 'LegacyHostedNativeInput.swift').write_text(OBSERVER.replace('// ACCEPTED_OBSERVATION_METHODS', methods))
    (out / 'NativeCancelReceipt.swift').write_text(text['NativeCancelReceipt.swift'])
    driver = text['NativeCancelUITests.swift']
    header = driver.split('    func testCapturedDeletionConfirmation', 1)[0]
    header = header.replace('final class NativeCancelUITests:', 'final class LegacyHostedNativeInputUITests:')
    helpers = '    private func readReceipt()' + driver.split('    private func readReceipt()', 1)[1]
    helpers = helpers.replace('value.mode == "native-system-popover-dismissal",', '(value.mode == "legacy-typed-popover" || value.mode == "legacy-untyped-popover"),')
    # Input still uses the original one-second freshness guard; a final immutable pre-teardown
    # receipt may be read after the original method has already completed its assertions.
    helpers = helpers.replace('(0...1).contains(Date().timeIntervalSince1970 - value.observedAt),', '(0...30).contains(Date().timeIntervalSince1970 - value.observedAt),', 1)
    a = helpers.index('    private func sameRequest(')
    b = helpers.index('    private func samePresentation(', a)
    helpers = helpers[:a] + SAME_REQUEST + helpers[b:]
    a = helpers.index('            value.captureRequestIDs == [initial.requestID],', helpers.index('    private func popupReady('))
    b = helpers.index('            let popup = value.popup,', a)
    helpers = helpers[:a] + '            sameRequest(value, initial: initial),\n' + helpers[b:]
    helpers = helpers.replace('NativeCancelContract.title', 'expectedTitle').replace('NativeCancelContract.message', 'expectedMessage')
    helpers = helpers.replace('for label in [expectedTitle, expectedMessage] {', 'for label in [expectedTitle, expectedMessage].compactMap({ $0 }) {')
    (out / 'LegacyHostedNativeInputUITests.swift').write_text(header + UI_BODY + '\n' + helpers)


def group_members(pgid):
    return [line for line in subprocess.check_output(['ps', '-axo', 'pgid=,pid=,command='], text=True).splitlines()
            if line.strip().split(None, 1)[:1] == [str(pgid)]]


def stop_readers(readers):
    """Only recorded task-owned groups; never shut down userdata while a reader remains."""
    for row in readers.values():
        process = row['process']
        if group_members(process.pid):
            try:
                os.killpg(process.pid, signal.SIGINT)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        for row in readers.values():
            row['process'].poll()
        if not any(group_members(row['process'].pid) for row in readers.values()):
            return
        time.sleep(0.1)
    for row in readers.values():
        process = row['process']
        if group_members(process.pid):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait()


def run(args, root):
    assert args.simulator_id and args.derived_data and args.jobs is None
    UUID(args.simulator_id)
    out = args.output.resolve()
    assert not out.exists(), 'Retain all previous raw failures; use a fresh output'
    out.mkdir(parents=True)
    dd = args.derived_data.resolve()
    cache = dd.parent
    for name in ['tmp', 'modules', 'packages', 'package-cache']:
        (cache / name).mkdir(parents=True, exist_ok=True)
    # Resolve all real storage roots, including private simulator userdata, before any build/boot.
    device = (Path.home() / 'Library/Developer/CoreSimulator/Devices' / args.simulator_id).resolve()
    # CI uses its own filesystem; local qualification still requires the external backing mount.
    backing = Path('/') if os.environ.get('GITHUB_ACTIONS') == 'true' else Path('/Volumes/SuttonCap')
    for path in [out, cache, device, backing]:
        assert shutil.disk_usage(path).free >= 20 * 2**30, str(path)
    os.environ.update(TMPDIR=str(cache / 'tmp') + '/', CLANG_MODULE_CACHE_PATH=str(cache / 'modules'),
                      SWIFTPM_MODULECACHE_OVERRIDE=str(cache / 'modules'))
    fixture = root / 'Tests/MonitorUIHostedTests/MonitorPlaybackAccessibilityLabelTests.swift'
    assert re.findall(r'\bfunc (test\w+)\(', fixture.read_text()) == NAMES
    inputs = [fixture, Path(__file__), root / 'scripts/ios-playback-label-hosted-test.py', root / 'Package.swift']
    inputs += list((root / 'scripts/ios-playback-label-native-system-dismissal').glob('*.swift'))
    before = {str(p): sha256(p.read_bytes()).hexdigest() for p in inputs}
    nonce = str(uuid4())
    seal = sha256(json.dumps(before, sort_keys=True).encode()).hexdigest()
    prepared = {'bundleID': 'com.opencapture.opencine.simulated.playbacklabels',
                'runnerBundleID': 'com.opencapture.opencine.simulated.playbacklabels.inputreader.xctrunner',
                'nonce': nonce, 'sourceSeal': seal}
    (out / 'input-binding.json').write_text(json.dumps({'inputs': before, **prepared}, indent=2) + '\n')
    generated_sources(root, out)
    host, target, reader = 'OpenCinePlaybackLabelsSimulated', 'OpenCinePlaybackLabelsHostedTests', 'LegacyHostedNativeInputUITests'
    (out / 'SimulatedHost.swift').write_text(HOST_SOURCE)
    dependencies = [{'package': 'OpenCine', 'product': p} for p in ['MonitorPresentation', 'MonitorUI', 'OpenCineMedia', 'OpenCineHostedAccessibility', 'OpenCineHostedTestSupport']]
    spec = {'name': 'OpenCinePlaybackLabelsHosted', 'options': {'deploymentTarget': {'iOS': '17.0'}},
            'settings': {'base': {'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES', 'TARGETED_DEVICE_FAMILY': '1,2'}},
            'packages': {'OpenCine': {'path': str(root)}}, 'targets': {
        host: {'type': 'application', 'platform': 'iOS', 'sources': [str(out / 'SimulatedHost.swift')], 'settings': {'base': {
            'PRODUCT_BUNDLE_IDENTIFIER': prepared['bundleID'], 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES', 'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
        target: {'type': 'bundle.unit-test', 'platform': 'iOS', 'sources': [str(fixture), str(out / 'LegacyHostedNativeInput.swift'), str(out / 'NativeCancelReceipt.swift')],
                 'dependencies': [{'target': host}] + dependencies, 'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': prepared['bundleID'] + '.tests',
                 'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/' + host + '.app/' + host, 'BUNDLE_LOADER': '$(TEST_HOST)'}}},
        reader: {'type': 'bundle.ui-testing', 'platform': 'iOS', 'sources': [str(out / 'LegacyHostedNativeInputUITests.swift'), str(out / 'NativeCancelReceipt.swift')],
                 'dependencies': [{'target': host}] + dependencies, 'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': prepared['bundleID'] + '.inputreader', 'TEST_TARGET_NAME': host}}}},
        'schemes': {'OpenCinePlaybackLabelsHosted': {'build': {'targets': {host: ['test'], target: ['test'], reader: ['test']}},
        'test': {'config': 'Debug', 'macroExpansion': host, 'environmentVariables': {
            'OPENCINE_NATIVE_UI_NONCE': nonce, 'OPENCINE_NATIVE_UI_SOURCE_SEAL': seal,
            'OPENCINE_NATIVE_UI_BUNDLE_ID': prepared['bundleID'], 'OPENCINE_NATIVE_UI_MODE': 'legacy-hosted-native-input'},
            'targets': [{'name': t, 'parallelizable': False, 'randomExecutionOrder': False} for t in [target, reader]]}}}}
    (out / 'project.json').write_text(json.dumps(spec, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate', '--spec', str(out / 'project.json'), '--project', str(out)], check=True)
    generated = {str(p): sha256(p.read_bytes()).hexdigest() for p in out.glob('*.swift')}
    project = out / 'OpenCinePlaybackLabelsHosted.xcodeproj/project.pbxproj'
    generated[str(project)] = sha256(project.read_bytes()).hexdigest()
    loader = importlib.util.spec_from_file_location('original_hosted_runner', root / 'scripts/ios-playback-label-hosted-test.py')
    original = importlib.util.module_from_spec(loader)
    loader.loader.exec_module(original)
    validator = original.NativeUIReceiptBridge(args.simulator_id, prepared, out)
    bridge_records, last_sequence = [], {'typed': 0, 'untyped': 0}

    def bridge(log):
        markers = set(re.findall(r'SIMULATED_NATIVE_UI_INBOX:([^\r\n]+)', log))
        assert len(markers) <= 1
        if not markers:
            return
        inbox = Path(next(iter(markers)))
        container = validator.container_for(inbox, prepared['runnerBundleID'])
        assert inbox.resolve() == (container / 'tmp' / ('SIMULATED-native-reader-' + nonce) / 'app-receipt.json').resolve()
        assert inbox.parent.is_dir() and not inbox.is_symlink()
        hosts = []
        import plistlib
        for child in validator.private_root.iterdir():
            metadata = child / '.com.apple.mobile_container_manager.metadata.plist'
            if metadata.is_file() and plistlib.loads(metadata.read_bytes()).get('MCMMetadataIdentifier') == prepared['bundleID']:
                hosts.append(child)
        assert len(hosts) <= 1
        if not hosts:
            return
        for phase in ['typed', 'untyped']:
            source = hosts[0] / 'tmp' / ('SIMULATED-native-cancel-' + nonce) / (phase + '.json')
            if not source.is_file():
                continue
            validator.container_for(source, prepared['bundleID'])
            assert not source.is_symlink()
            data = source.read_bytes()
            value = json.loads(data)
            assert value['schema'] == 1 and value['nonce'] == nonce and value['sourceSeal'] == seal
            assert value['bundleID'] == prepared['bundleID'] and UUID(value['simulatorID']) == UUID(args.simulator_id)
            assert value['mode'] == 'legacy-' + phase + '-popover' and value['processID'] > 0
            if value['sequence'] <= last_sequence[phase]:
                continue
            archive = out / 'app-receipts' / phase / (str(value['sequence']) + '.json')
            archive.parent.mkdir(parents=True, exist_ok=True)
            archive.write_bytes(data)
            destination = inbox.with_name(phase + '.json')
            assert not destination.is_symlink()
            temporary = inbox.with_name('.bridge-' + phase + '-' + nonce)
            temporary.write_bytes(data); temporary.chmod(0o400); temporary.replace(destination)
            assert destination.read_bytes() == archive.read_bytes()
            last_sequence[phase] = value['sequence']
            bridge_records.append({'phase': phase, 'sequence': value['sequence'], 'sha256': sha256(data).hexdigest(), 'source': str(source), 'retained': str(archive), 'readerCopy': str(destination)})

    common = ['-destination', 'platform=iOS Simulator,id=' + args.simulator_id, '-parallel-testing-enabled', 'NO',
              '-collect-test-diagnostics', 'never', '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '120',
              '-maximum-test-execution-time-allowance', '170', 'CODE_SIGNING_ALLOWED=NO']
    readers, commands = {}, {}
    began = time.monotonic()

    def spawn(label, command):
        commands[label] = command
        stream = (out / (label + '.log')).open('w')
        process = subprocess.Popen(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        readers[label] = {'process': process, 'stream': stream, 'size': 0, 'last': time.monotonic()}
        return process

    def poll(label):
        row = readers[label]; process = row['process']; now = time.monotonic()
        size = (out / (label + '.log')).stat().st_size
        if size != row['size']:
            row['size'] = size; row['last'] = now
        if process.poll() is None and (now - row['last'] > 180 or now - began > 2400):
            row['watchdog'] = 'no-progress180' if now - row['last'] > 180 else 'wall2400'
            os.killpg(process.pid, signal.SIGINT)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
        return process.poll()

    execution_error = None
    try:
        build = spawn('build', ['xcodebuild', '-project', str(project.parent), '-scheme', 'OpenCinePlaybackLabelsHosted',
            '-derivedDataPath', str(dd), '-clonedSourcePackagesDirPath', str(cache / 'packages'), '-packageCachePath', str(cache / 'package-cache'),
            '-skipPackageUpdates', '-disableAutomaticPackageResolution', 'MODULE_CACHE_DIR=' + str(cache / 'modules'), *common, 'build-for-testing'])
        while poll('build') is None:
            time.sleep(1)
        if build.wait() == 0:
            runs = list((dd / 'Build/Products').glob('*.xctestrun'))
            assert len(runs) == 1
            base = ['xcodebuild', '-xctestrun', str(runs[0]), *common]
            spawn('ui-reader', [*base, '-derivedDataPath', str(cache / 'dd-ui'), '-resultBundlePath', str(out / 'ui-reader.xcresult'),
                '-only-testing:' + reader + '/' + reader + '/testSupplyNativeInputToBothOriginalDeletionCases', 'test-without-building'])
            while poll('ui-reader') is None:
                log = (out / 'ui-reader.log').read_text(errors='replace')
                bridge(log)
                if 'SIMULATED_NATIVE_UI_INBOX:' in log:
                    spawn('original-three', [*base, '-derivedDataPath', str(cache / 'dd-unit'), '-resultBundlePath', str(out / 'original-three.xcresult'),
                        '-only-testing:' + target + '/MonitorPlaybackAccessibilityLabelTests', 'test-without-building'])
                    break
                time.sleep(0.1)
            while any(poll(label) is None for label in readers):
                bridge((out / 'ui-reader.log').read_text(errors='replace'))
                time.sleep(0.1)
    except BaseException as error:
        execution_error = repr(error)
        (out / 'execution-error.json').write_text(json.dumps({'error': execution_error}, indent=2) + '\n')
    finally:
        stop_readers(readers)
    results = {}
    for label, row in readers.items():
        process = row['process']; code = process.wait(); row['stream'].close()
        remaining = group_members(process.pid)
        results[label] = {'pid': process.pid, 'pgid': process.pid, 'exit': code, 'watchdog': row.get('watchdog'), 'remainingGroup': remaining}
    assert all(not r['remainingGroup'] for r in results.values()), results
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
    device_info = next(d for group in devices.values() for d in group if d['udid'] == args.simulator_id)
    if device_info['state'] != 'Shutdown':
        subprocess.run(['xcrun', 'simctl', 'shutdown', args.simulator_id], check=True)
    after = {str(p): sha256(p.read_bytes()).hexdigest() for p in inputs}
    original_log = (out / 'original-three.log').read_text(errors='replace') if 'original-three' in readers else ''
    outcomes = {name: re.findall(r"Test Case '[^\n]*\b" + re.escape(name) + r"\]' (passed|failed|skipped)", original_log) for name in NAMES}
    ui_log = (out / 'ui-reader.log').read_text(errors='replace') if 'ui-reader' in readers else ''
    native_outcomes = [json.loads(v) for v in re.findall(r'LEGACY_NATIVE_INPUT_OUTCOME:([^\r\n]+)', ui_log)]
    receipt = {'executionError': execution_error, 'results': results, 'commands': commands, 'namedOutcomes': outcomes,
        'nativeOutcomes': native_outcomes, 'exactThreePasses': all(outcomes[n] == ['passed'] for n in NAMES),
        'inputSourcesUnchanged': before == after, 'generatedSourcesUnchanged': all(sha256(Path(p).read_bytes()).hexdigest() == h for p, h in generated.items()),
        'bridgeRecords': bridge_records, 'simulatorShutdown': True, 'userdataRetained': str(device), 'physical': 'untested'}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    passed = execution_error is None and all(r['exit'] == 0 and not r['watchdog'] for r in results.values()) and receipt['exactThreePasses']
    passed &= receipt['inputSourcesUnchanged'] and receipt['generatedSourcesUnchanged']
    passed &= [v['phase'] for v in native_outcomes] == ['typed', 'untyped'] and all(v['qualified'] and v['tapInvoked'] for v in native_outcomes)
    print(json.dumps({'passed': passed, 'results': results, 'namedOutcomes': outcomes, 'nativeOutcomes': [{k: v[k] for k in ['phase', 'tapInvoked', 'qualified']} for v in native_outcomes]}), flush=True)
    return 0 if passed else 1
