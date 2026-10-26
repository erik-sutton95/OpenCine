#if os(iOS)
    import Foundation
    import Observation
    import OpenCineCameraControls
    import OpenCineCoreTestSupport
    import OpenCineGyro
    import OpenCineGyroApple
    import OpenCineHostedAccessibility
    import OpenCineHostedTestSupport
    import SwiftUI
    import UIKit
    import XCTest

    /// A scripted motion driver for hosted tests: device-motion readings are pushed by the test.
    @MainActor final class HostedGyroDriver: GyroMotionDriving {
        private var consumers: [UUID: (GyroDriftReading) -> Void] = [:]

        func startGyro(into buffer: GyroSampleBuffer) throws {}
        func stopGyro() {}
        func startMotion(_ receive: @escaping (GyroDriftReading) -> Void) throws -> UUID {
            let id = UUID()
            consumers[id] = receive
            return id
        }
        func stopMotion(_ id: UUID) { consumers.removeValue(forKey: id) }
        func startLevel(_ receive: @escaping (Double, Double, Double) -> Void) -> UUID { UUID() }
        func stopLevel(_ id: UUID) {}
        func push(_ reading: GyroDriftReading) {
            for receive in Array(consumers.values) { receive(reading) }
        }
    }

    final class HostedKeyValues: GyroKeyValueStore {
        var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func setData(_ data: Data?, forKey key: String) { values[key] = data }
    }

    /// A log store that serves fixed takes and records what was shared.
    actor HostedLogStore: GyroLogStoring {
        private let entries: [GyroLogEntry]
        private(set) var shared: [[UUID]] = []

        init(entries: [GyroLogEntry]) { self.entries = entries }

        func sharedIDs() -> [[UUID]] { shared }
        func load() -> GyroLogRecoveryResult { .init(entries: entries, warning: nil) }
        func apply(_ updates: [GyroLogUpdate], at time: Double) throws -> [GyroLogEntry] { entries }
        func abort() -> GyroLogRecoveryResult { .init(entries: entries, warning: nil) }
        func share(_ ids: [UUID]) throws -> [URL] {
            shared.append(ids)
            return ids.map { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\($0).gcsv") }
        }
        func delete(_ id: UUID) -> [GyroLogEntry] { entries.filter { $0.id != id } }
    }

    /// Hosted tests for the drift sheet, the feature host, settings, and the orientation and
    /// VoiceOver sweep over every gyro state.
    extension GyroScreensTests {
        // MARK: Fixtures

        struct Rig {
            let coordinator: GyroCaptureCoordinator
            let camera: FakeGyroCameraAdapter
            let driver: HostedGyroDriver
            let directory: URL
            var clock: ClockBox

            func cleanup() { try? FileManager.default.removeItem(at: directory) }
        }

        @MainActor final class ClockBox { var time: Double = 10 }

        func rig(store: (any GyroLogStoring)? = nil) async -> Rig {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("gyro-hosted-\(UUID().uuidString)")
            let driver = HostedGyroDriver()
            let camera = FakeGyroCameraAdapter()
            let clock = ClockBox()
            let coordinator = GyroCaptureCoordinator(
                host: GyroHostConfiguration(
                    appName: "Test app", logDirectory: directory,
                    preferenceKeys: .namespaced("hosted.gyro.")),
                driver: driver, store: store, keyValueStore: HostedKeyValues(),
                now: { clock.time }, automaticProcessing: false)
            coordinator.attach(camera)
            coordinator.setHostEligible(true)
            await coordinator.waitUntilLoaded()
            return Rig(
                coordinator: coordinator, camera: camera, driver: driver, directory: directory,
                clock: clock)
        }

        func connect(_ rig: Rig, ibis: String = "SPORT") {
            rig.camera.connect(
                stabilization: .init(values: ["ibis": ibis], lensHasVRSwitch: true), recording: false,
                at: rig.clock.time)
        }

        /// Holds one still pose at 30 Hz: a fresh camera level, then the matching phone reading.
        func hold(_ rig: Rig, _ down: GyroVector3, seconds: Double) {
            for _ in 0..<Int((seconds * 30).rounded()) {
                rig.clock.time += 1.0 / 30
                rig.camera.send(.level(down, at: rig.clock.time))
                rig.driver.push(
                    GyroDriftReading(
                        timestamp: rig.clock.time, phoneDown: down, rotationRate: 0,
                        accelerationG: 1))
            }
        }

        static let levelDown = GyroVector3(x: -1, y: 0, z: 0)
        static let tiltUpDown = GyroVector3(x: -0.8191520442889918, y: 0, z: 0.573576436351046)

        /// All leaves under the window, so presented covers and sheets count.
        func windowLeaves(_ host: Host) -> [NSObject] {
            var leaves = HostedAccessibility.leaves(in: host.controller.view)
            var presented = host.controller.presentedViewController
            while let controller = presented {
                leaves += HostedAccessibility.leaves(in: controller.view)
                presented = controller.presentedViewController
            }
            return leaves
        }

        func waitForWindow(_ label: String, in host: Host) async -> Bool {
            await HostedCondition.wait {
                host.controller.view.layoutIfNeeded()
                return windowLeaves(host).contains { $0.accessibilityLabel == label }
            }
        }

        // MARK: Drift sheet

        func testDriftSheetHasOnePrimaryButton() async throws {
            await inBothOrientations(
                "drift-sheet", GyroDriftSheet(recalibrate: {}, notNow: {}),
                settle: GyroCopy.recalibrate
            ) { host, _ in
                XCTAssertEqual(host.identified("gyro.primary").count, 1)
                XCTAssertFalse(host.labelled(GyroCopy.notNow).isEmpty)
                XCTAssertFalse(host.labelled(GyroCopy.driftTitle).isEmpty)
            }
        }

        // MARK: Feature host

        /// UIKit presentations of a sceneless test window expose no accessibility tree, so the
        /// host's presentation is proven by the presented controller, and the content views the
        /// host presents are hosted directly.
        func testFeatureHostPresentsTheSetupSheetForANewSession() async throws {
            let rig = await rig()
            defer { rig.cleanup() }
            let haptics = OperatorHaptics(isEnabled: { false })
            let host = await host(Color.black.ignoresSafeArea().gyroFeature(rig.coordinator, haptics: haptics))
            defer { host.close() }
            XCTAssertNil(host.controller.presentedViewController)
            rig.coordinator.enabled = true
            connect(rig)
            await rig.coordinator.waitForCameraWrites()
            XCTAssertEqual(rig.coordinator.setupSteps.first, .stabilization(lensHasVRSwitch: true))
            let presented = await HostedCondition.wait { host.controller.presentedViewController != nil }
            XCTAssertTrue(presented, "A new session presents the setup cover")
            let cover = host.controller.presentedViewController
            // One cover for the whole flow: moving to calibration does not re-present.
            rig.coordinator.setupKeepStabilization()
            XCTAssertEqual(rig.coordinator.setupSteps.first, .calibration(hasSavedCalibration: false))
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(host.controller.presentedViewController === cover)
            // The presented content, hosted directly, follows the coordinator's step.
            let flow = await self.host(GyroSetupFlow(coordinator: rig.coordinator, haptics: haptics))
            defer { flow.close() }
            await waitFor(GyroCopy.getStarted, in: flow)
            XCTAssertEqual(flow.identified("gyro.primary").count, 1)
            flow.labelled(GyroCopy.getStarted).first.map { _ = $0.accessibilityActivate() }
            await waitFor(GyroCopy.stepCounter(1), in: flow)
            XCTAssertNotNil(rig.coordinator.ring)
            rig.coordinator.cancelCalibration()
            // Dismissal itself is not observable here: a sceneless test window never completes
            // UIKit dismissals, so the cover going away is left to the device pass.
            XCTAssertNil(rig.coordinator.ring)
            XCTAssertTrue(rig.coordinator.setupSteps.isEmpty)
            rig.coordinator.enabled = false
            await rig.coordinator.processPending()
        }

        func testFeatureHostSharesSelectedTakes() async throws {
            let entries = Array(try Self.sampleEntries().prefix(3))
            let store = HostedLogStore(entries: entries)
            let rig = await rig(store: store)
            defer { rig.cleanup() }
            let haptics = OperatorHaptics(isEnabled: { false })
            let presenting = await host(Color.black.ignoresSafeArea().gyroFeature(rig.coordinator, haptics: haptics))
            defer { presenting.close() }
            rig.coordinator.logsPresented = true
            let sheet = await HostedCondition.wait { presenting.controller.presentedViewController != nil }
            XCTAssertTrue(sheet, "logsPresented presents the logs sheet")
            let host = await self.host(GyroLogsFlow(coordinator: rig.coordinator, haptics: haptics))
            defer { host.close() }
            await waitFor(GyroCopy.logsTitle, in: host)
            let select = host.identified("gyro.logs.select").first
            XCTAssertTrue(try XCTUnwrap(select).accessibilityActivate())
            await waitFor(GyroCopy.shareCount(0), in: host)
            let ready = host.identified("gyro.log.row").first {
                ($0.accessibilityLabel ?? "").hasSuffix(GyroCopy.status(.ready))
            }
            _ = try XCTUnwrap(ready).accessibilityActivate()
            await waitFor(GyroCopy.shareCount(1), in: host)
            _ = try XCTUnwrap(host.identified("gyro.primary").first).accessibilityActivate()
            var ids: [[UUID]] = []
            for _ in 0..<200 where ids.isEmpty {
                ids = await store.sharedIDs()
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(ids, [[entries[1].id]])
        }

        func testNoticeBannerShowsAndClears() async throws {
            let rig = await rig()
            defer { rig.cleanup() }
            rig.camera.acceptsWrites = false
            let host = await host(
                Color.black.ignoresSafeArea().gyroFeature(
                    rig.coordinator, haptics: OperatorHaptics(isEnabled: { false })))
            defer { host.close() }
            rig.coordinator.enabled = true
            connect(rig)
            await rig.coordinator.waitForCameraWrites()
            rig.coordinator.setupTurnOffStabilization()
            await rig.coordinator.waitForCameraWrites()
            XCTAssertEqual(rig.coordinator.notice, .turnOffFailed)
            let shown = await waitForWindow(GyroCopy.notice(.turnOffFailed), in: host)
            XCTAssertTrue(shown)
            await snapshot(host, state: "notice-banner", landscape: false)
            host.window.frame = CGRect(origin: .zero, size: Self.landscape)
            host.controller.view.frame = host.window.bounds
            host.controller.view.layoutIfNeeded()
            await snapshot(host, state: "notice-banner", landscape: true)
            rig.coordinator.enabled = false
            await rig.coordinator.processPending()
        }

        // MARK: Rotation

        func testRotationKeepsCalibrationProgress() async throws {
            let rig = await rig()
            defer { rig.cleanup() }
            connect(rig, ibis: "OFF")
            let probe = RingProbe()
            rig.coordinator.beginCalibration()
            rig.coordinator.startRing()
            hold(rig, Self.levelDown, seconds: 3)
            hold(rig, Self.tiltUpDown, seconds: 1)
            guard case .posing(.tiltUp, _, _) = rig.coordinator.ring else {
                return XCTFail("Expected posing tiltUp, got \(String(describing: rig.coordinator.ring))")
            }
            _ = probe
            let phase = try XCTUnwrap(rig.coordinator.ring)
            let host = await host(
                GyroRingCalibrationView(
                    phase: phase, completedSteps: rig.coordinator.ringCompletedSteps,
                    lastEvent: rig.coordinator.lastRingEvent,
                    eventToken: rig.coordinator.ringEventToken, canUseLast: false,
                    actions: GyroSetupActions()))
            defer { host.close() }
            await waitFor(GyroCopy.stepCounter(2), in: host)
            host.window.frame = CGRect(origin: .zero, size: Self.landscape)
            host.controller.view.frame = host.window.bounds
            host.controller.view.layoutIfNeeded()
            await waitFor(GyroCopy.stepCounter(2), in: host)
            XCTAssertEqual(rig.coordinator.ring, phase, "Rotation does not touch the calibration")
            XCTAssertEqual(rig.coordinator.ringCompletedSteps, 1)
            rig.coordinator.cancelCalibration()
        }

        // MARK: Sweep

        struct SweepState {
            let name: String
            let view: AnyView
            let labelPrimary: Bool
        }

        func sweepStates() throws -> [SweepState] {
            let calibration = try Self.calibration()
            let entries = try Self.sampleEntries()
            func ring(_ name: String, _ phase: GyroRingPhase, completed: Int = 0, canUseLast: Bool = false) -> SweepState {
                SweepState(
                    name: name,
                    view: AnyView(
                        self.ring(phase, completed: completed, canUseLast: canUseLast)),
                    labelPrimary: false)
            }
            var states: [SweepState] = [
                SweepState(
                    name: "setup-ibis",
                    view: AnyView(sheet(.stabilization(lensHasVRSwitch: false))), labelPrimary: false),
                SweepState(
                    name: "setup-ibis-lens",
                    view: AnyView(sheet(.stabilization(lensHasVRSwitch: true))), labelPrimary: false),
                ring("calibration-intro", .intro),
                ring("calibration-intro-uselast", .intro, canUseLast: true),
                ring("posing-level-looking", .posing(step: .level, inZone: false, hold: 0)),
                ring("posing-tiltup-holding", .posing(step: .tiltUp, inZone: true, hold: 0.6), completed: 1),
                ring("posing-lean-holding", .posing(step: .tiltAndLean, inZone: true, hold: 0.4), completed: 2),
                ring("blocked-disconnected", .blocked(step: .level, reason: .cameraDisconnected)),
                ring("blocked-recording", .blocked(step: .level, reason: .recording)),
                ring("blocked-moving", .blocked(step: .tiltUp, reason: .moving), completed: 1),
                ring("blocked-waiting", .blocked(step: .tiltUp, reason: .waitingForCamera), completed: 1),
                ring("retry", .retrying),
                ring("invalidated-camera", .invalidated(.cameraChanged)),
                ring("invalidated-recording", .invalidated(.recordingStarted)),
                ring("invalidated-connection", .invalidated(.connectionEnded)),
                ring("complete", .complete(calibration), completed: 3),
                SweepState(
                    name: "drift-sheet",
                    view: AnyView(GyroDriftSheet(recalibrate: {}, notNow: {})), labelPrimary: false),
                SweepState(
                    name: "logs-list", view: AnyView(logs(entries)), labelPrimary: false),
                SweepState(
                    name: "logs-empty",
                    view: AnyView(logs([], tip: false, enabled: false)), labelPrimary: false),
                SweepState(
                    name: "logs-empty-gyro-on",
                    view: AnyView(logs([], tip: false, enabled: true)), labelPrimary: false),
            ]
            let takes: [(String, GyroLogEntry)] = [
                ("take-ready", try Self.entry(minutesAgo: 20)),
                ("take-gaps", try Self.entry(minutesAgo: 45, gaps: true)),
                ("take-cutshort", try Self.entry(minutesAgo: 45, cutShort: true)),
                ("take-uncalibrated", try Self.entry(minutesAgo: 45, calibrated: false)),
                ("take-mountmoved", try Self.entry(minutesAgo: 45, mountMoved: true)),
                ("take-recording", try Self.entry(minutesAgo: 1, length: 12, active: true)),
            ]
            for (name, entry) in takes {
                states.append(
                    SweepState(
                        name: name, view: AnyView(GyroTakeView(entry: entry, now: Self.now, share: {})),
                        labelPrimary: false))
            }
            return states
        }

        func testEveryScreenRendersInBothOrientations() async throws {
            for state in try sweepStates() {
                for landscape in [false, true] {
                    let size = landscape ? Self.landscape : Self.portrait
                    let host = await host(state.view, size: size)
                    let settled = await HostedCondition.wait {
                        host.controller.view.layoutIfNeeded()
                        return !host.elements.isEmpty
                    }
                    XCTAssertTrue(settled, "\(state.name) \(landscape)")
                    let primaries = primaries(host)
                    XCTAssertLessThanOrEqual(primaries.count, 1, "\(state.name): one accent primary")
                    let safe = host.window.safeAreaLayoutGuide.layoutFrame
                    let visual = host.identified("gyro.visual").first?.accessibilityFrame
                    for primary in primaries {
                        let frame = primary.accessibilityFrame
                        XCTAssertTrue(
                            safe.insetBy(dx: -1, dy: -1).contains(frame),
                            "\(state.name) \(landscape): primary \(frame) inside \(safe)")
                        if let visual {
                            XCTAssertFalse(
                                frame.intersects(visual),
                                "\(state.name) \(landscape): primary overlaps the visual")
                        }
                    }
                    await snapshot(host, state: state.name, landscape: landscape)
                    host.close()
                }
            }
        }

        func testEveryStateHasAVoiceOverLabel() async throws {
            for state in try sweepStates() {
                let host = await host(state.view)
                let settled = await HostedCondition.wait {
                    host.controller.view.layoutIfNeeded()
                    return !host.elements.isEmpty
                }
                XCTAssertTrue(settled, state.name)
                for element in host.elements {
                    let label = element.accessibilityLabel ?? ""
                    XCTAssertFalse(
                        label.isEmpty,
                        "\(state.name): unlabelled \(type(of: element)) \(HostedAccessibility.identifier(element) ?? "-")")
                }
                host.close()
            }
        }

        // MARK: Pill

        func testPillLabelsMatchTheCopyForEveryKind() async throws {
            for kind in GyroPillKind.allCases where kind != .hidden {
                for warning in [false, true] {
                    let host = await host(
                        GyroPillView(
                            state: GyroPillState(kind: kind, stabilizationWarning: warning), action: {}
                        ).padding(),
                        size: CGSize(width: 393, height: 120))
                    let pill = await HostedCondition.wait {
                        host.controller.view.layoutIfNeeded()
                        return !host.identified("gyro.pill").isEmpty
                    }
                    XCTAssertTrue(pill, "\(kind)")
                    XCTAssertEqual(
                        host.identified("gyro.pill").first?.accessibilityLabel,
                        GyroCopy.pillA11y(kind, warning: warning))
                    host.close()
                }
            }
            // One board of every pill on a dark monitor-like backdrop, for the review sheet.
            let board = VStack(spacing: 14) {
                ForEach(GyroPillKind.allCases.filter { $0 != .hidden }, id: \.self) { kind in
                    HStack(spacing: 12) {
                        GyroPillView(state: GyroPillState(kind: kind, stabilizationWarning: false), action: {})
                        GyroPillView(state: GyroPillState(kind: kind, stabilizationWarning: true), action: {})
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.05, green: 0.06, blue: 0.07))
            for landscape in [false, true] {
                let host = await host(board, size: landscape ? Self.landscape : Self.portrait)
                _ = await HostedCondition.wait { !host.identified("gyro.pill").isEmpty }
                await snapshot(host, state: "pill-all", landscape: landscape)
                host.close()
            }
        }
    }
#endif
