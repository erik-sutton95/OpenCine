#if os(iOS)
    import Foundation
    import Observation
    import OpenCineCameraControls
    import OpenCineGyro
    import OpenCineHostedAccessibility
    import OpenCineHostedTestSupport
    import SwiftUI
    import UIKit
    import XCTest

    /// SIMULATED hosted renders of the shared gyro screens. Each state is hosted in a window of
    /// the phone size for its orientation; when `GYRO_SNAPSHOT_DIR` is set (xcodebuild passes it
    /// through `TEST_RUNNER_GYRO_SNAPSHOT_DIR`) the window is written to
    /// `<dir>/<state>-<portrait|landscape>.png`.
    @MainActor
    final class GyroScreensTests: XCTestCase {
        static let portrait = CGSize(width: 393, height: 852)
        static let landscape = CGSize(width: 852, height: 393)

        // MARK: Hosting

        @MainActor struct Host {
            let window: UIWindow
            let controller: UIViewController
            var elements: [NSObject] { HostedAccessibility.leaves(in: controller.view) }
            var all: [NSObject] { HostedAccessibility.reachable(in: controller.view) }

            func identified(_ id: String) -> [NSObject] {
                all.filter { HostedAccessibility.identifier($0) == id }
            }

            func labelled(_ label: String) -> [NSObject] {
                elements.filter { $0.accessibilityLabel == label }
            }

            func close() {
                window.isHidden = true
                window.rootViewController = nil
            }
        }

        func host<V: View>(_ view: V, size: CGSize = GyroScreensTests.portrait) async -> Host {
            _ = await HostedAccessibility.awaitRuntime()
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return Host(window: window, controller: controller)
        }

        /// Waits until the host exposes an element with the label.
        func waitFor(_ label: String, in host: Host, file: StaticString = #filePath, line: UInt = #line)
            async
        {
            let found = await HostedCondition.wait {
                host.controller.view.layoutIfNeeded()
                return !host.labelled(label).isEmpty
            }
            XCTAssertTrue(found, "No element labelled \(label); saw \(host.elements.map { ($0.accessibilityLabel ?? "-") + "|" + (HostedAccessibility.identifier($0) ?? "-") })", file: file, line: line)
        }

        /// Hosts the view in both orientations, runs the check on each and snapshots it.
        func inBothOrientations<V: View>(
            _ state: String, _ view: @autoclosure () -> V, settle label: String,
            check: (Host, Bool) -> Void = { _, _ in }
        ) async {
            for landscape in [false, true] {
                let host = await host(view(), size: landscape ? Self.landscape : Self.portrait)
                await waitFor(label, in: host)
                check(host, landscape)
                await snapshot(host, state: state, landscape: landscape)
                host.close()
            }
        }

        func snapshot(_ host: Host, state: String, landscape: Bool) async {
            guard let dir = ProcessInfo.processInfo.environment["GYRO_SNAPSHOT_DIR"], !dir.isEmpty
            else { return }
            try? await Task.sleep(for: .milliseconds(250))
            host.controller.view.layoutIfNeeded()
            let view: UIView = host.controller.view
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            let image = renderer.image { context in
                if !view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) {
                    view.layer.render(in: context.cgContext)
                }
            }
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let name = "\(state)-\(landscape ? "landscape" : "portrait").png"
            try? image.pngData()?.write(to: url.appendingPathComponent(name))
        }

        static func calibration() throws -> GyroMountCalibration {
            let json = """
                {"rotation":[{"x":1,"y":0,"z":0},{"x":0,"y":1,"z":0},{"x":0,"y":0,"z":1}],\
                "validationErrorDegrees":0.5,"separationDegrees":30}
                """
            return try JSONDecoder().decode(GyroMountCalibration.self, from: Data(json.utf8))
        }

        // MARK: Calibration (ring)

        private func ring(
            _ phase: GyroRingPhase, completed: Int = 0, canUseLast: Bool = false
        ) -> GyroRingCalibrationView {
            GyroRingCalibrationView(
                phase: phase, completedSteps: completed, lastEvent: nil, canUseLast: canUseLast,
                actions: GyroSetupActions())
        }

        func testIntroShowsGetStartedAndNoCaptureButton() async throws {
            await inBothOrientations(
                "calibration-intro", ring(.intro), settle: GyroCopy.getStarted
            ) { host, _ in
                XCTAssertEqual(host.identified("gyro.primary").count, 1)
                for forbidden in ["Capture", "Verify", "Start again"] {
                    XCTAssertTrue(host.labelled(forbidden).isEmpty, forbidden)
                }
                XCTAssertTrue(host.labelled(GyroCopy.useLastCalibration).isEmpty)
                XCTAssertEqual(host.identified("gyro.visual").count, 1)
                XCTAssertFalse(host.labelled(GyroCopy.cancel).isEmpty)
            }
            await inBothOrientations(
                "calibration-intro-uselast", ring(.intro, canUseLast: true),
                settle: GyroCopy.useLastCalibration
            ) { host, _ in
                XCTAssertEqual(host.identified("gyro.primary").count, 1)
            }
        }

        func testPosingScreensShowTheStepCounterAndNoButton() async throws {
            await inBothOrientations(
                "posing-looking",
                ring(.posing(step: .tiltUp, inZone: false, hold: 0), completed: 1),
                settle: GyroCopy.holdHint
            ) { host, _ in
                XCTAssertTrue(host.identified("gyro.primary").isEmpty)
                let visual = host.identified("gyro.visual").first
                XCTAssertEqual(visual?.accessibilityLabel, GyroCopy.step(.tiltUp))
            }
            await inBothOrientations(
                "posing-holding",
                ring(.posing(step: .tiltUp, inZone: true, hold: 0.6), completed: 1),
                settle: GyroCopy.holdHint
            ) { host, _ in
                let visual = host.identified("gyro.visual").first
                XCTAssertEqual(visual?.accessibilityValue, GyroCopy.holdProgressA11y(60))
            }
        }

        func testBlockedStateShowsOneLine() async throws {
            await inBothOrientations(
                "blocked-moving", ring(.blocked(step: .level, reason: .moving)),
                settle: GyroCopy.block(.moving)
            ) { host, _ in
                XCTAssertEqual(host.identified("gyro.hint").count, 1)
                XCTAssertTrue(host.identified("gyro.primary").isEmpty)
                XCTAssertTrue(host.labelled(GyroCopy.holdHint).isEmpty)
            }
            await inBothOrientations(
                "blocked-recording", ring(.blocked(step: .tiltUp, reason: .recording), completed: 1),
                settle: GyroCopy.block(.recording))
        }

        func testRetryInvalidatedAndCompleteScreens() async throws {
            await inBothOrientations(
                "calibration-retry", ring(.retrying), settle: GyroCopy.retry)
            await inBothOrientations(
                "calibration-invalidated", ring(.invalidated(.cameraChanged)),
                settle: GyroCopy.done
            ) { host, _ in
                XCTAssertEqual(host.identified("gyro.primary").count, 1)
            }
            let done = try Self.calibration()
            await inBothOrientations(
                "calibration-complete", ring(.complete(done), completed: 3),
                settle: GyroCopy.done
            ) { host, _ in
                XCTAssertEqual(host.identified("gyro.primary").count, 1)
                XCTAssertTrue(host.labelled(GyroCopy.cancel).isEmpty, "Complete has no Cancel")
            }
        }

        // MARK: Arming sheet

        private func sheet(_ step: GyroArmingStep, ring: GyroRingPhase? = nil) -> GyroSetupSheet {
            GyroSetupSheet(step: step, ring: ring, completedSteps: 0, actions: GyroSetupActions())
        }

        /// The accent-filled buttons on a screen: `gyro.primary`, or the stabilization step's
        /// `gyro.setup.turnOff`, which is its primary and carries its own identifier.
        private func primaries(_ host: Host) -> [NSObject] {
            host.all.filter {
                ["gyro.primary", "gyro.setup.turnOff"].contains(HostedAccessibility.identifier($0) ?? "")
            }
        }

        func testStabilizationStepShowsOnePrimaryButton() async throws {
            await inBothOrientations(
                "setup-ibis", sheet(.stabilization(lensHasVRSwitch: false)),
                settle: GyroCopy.ibisTurnOff
            ) { host, _ in
                XCTAssertEqual(primaries(host).count, 1)
                XCTAssertEqual(host.identified("gyro.setup.turnOff").count, 1)
                XCTAssertEqual(host.identified("gyro.setup.keepOn").count, 1)
                XCTAssertEqual(host.identified("gyro.visual").count, 1)
                XCTAssertFalse(host.labelled(GyroCopy.ibisKeep).isEmpty)
            }
        }

        func testLensLineOnlyWhenTheLensHasAVRSwitch() async throws {
            await inBothOrientations(
                "setup-ibis-lens", sheet(.stabilization(lensHasVRSwitch: true)),
                settle: GyroCopy.ibisTurnOff
            ) { host, _ in
                XCTAssertFalse(host.labelled(GyroCopy.ibisLens).isEmpty)
            }
            for known in [false as Bool?, nil] {
                let host = await host(sheet(.stabilization(lensHasVRSwitch: known)))
                await waitFor(GyroCopy.ibisTurnOff, in: host)
                XCTAssertTrue(host.labelled(GyroCopy.ibisLens).isEmpty, "\(String(describing: known))")
                host.close()
            }
        }

        func testCalibrationStepOffersUseLastOnlyWithASavedCalibration() async throws {
            let withSaved = await host(sheet(.calibration(hasSavedCalibration: true)))
            await waitFor(GyroCopy.getStarted, in: withSaved)
            XCTAssertFalse(withSaved.labelled(GyroCopy.useLastCalibration).isEmpty)
            XCTAssertEqual(primaries(withSaved).count, 1)
            withSaved.close()
            let without = await host(sheet(.calibration(hasSavedCalibration: false)))
            await waitFor(GyroCopy.getStarted, in: without)
            XCTAssertTrue(without.labelled(GyroCopy.useLastCalibration).isEmpty)
            without.close()
            await inBothOrientations(
                "setup-calibration-posing",
                sheet(
                    .calibration(hasSavedCalibration: false),
                    ring: .posing(step: .level, inZone: true, hold: 0.4)),
                settle: GyroCopy.holdHint)
        }

        // MARK: Announcements

        @MainActor final class AnnouncementLog {
            var items: [String] = []
        }

        @MainActor @Observable final class RingProbe {
            var phase: GyroRingPhase = .intro
            var event: GyroRingEvent?
        }

        struct RingProbeView: View {
            let probe: RingProbe
            let log: AnnouncementLog

            var body: some View {
                GyroRingCalibrationView(
                    phase: probe.phase, completedSteps: 0, lastEvent: probe.event,
                    canUseLast: false, actions: GyroSetupActions()
                )
                .environment(
                    \.gyroAnnouncer, GyroAnnouncer { [log] text in log.items.append(text) })
                .environment(\.gyroHaptics, .init(isEnabled: { false }))
            }
        }

        func testRingAnnouncesProgressAndCaptures() async throws {
            let probe = RingProbe()
            let log = AnnouncementLog()
            let host = await host(RingProbeView(probe: probe, log: log))
            defer { host.close() }
            await waitFor(GyroCopy.getStarted, in: host)

            func settle(_ expected: Int) async {
                let reached = await HostedCondition.wait { log.items.count >= expected }
                XCTAssertTrue(reached, "Expected \(expected) announcements, got \(log.items)")
            }

            probe.phase = .posing(step: .level, inZone: true, hold: 0.1)
            await waitFor(GyroCopy.holdHint, in: host)
            XCTAssertTrue(log.items.isEmpty)
            probe.phase = .posing(step: .level, inZone: true, hold: 0.3)
            await settle(1)
            probe.phase = .posing(step: .level, inZone: true, hold: 0.35)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(log.items, [GyroCopy.holdProgressA11y(25)])
            probe.phase = .posing(step: .level, inZone: true, hold: 0.8)
            await settle(2)
            XCTAssertEqual(log.items.last, GyroCopy.holdProgressA11y(75))

            probe.event = .stepCaptured(.level)
            await settle(3)
            XCTAssertEqual(log.items.last, GyroCopy.stepDoneA11y(1))

            probe.event = .completed(try Self.calibration())
            await settle(4)
            XCTAssertEqual(log.items.last, GyroCopy.completeTitle)
        }
    }
#endif
