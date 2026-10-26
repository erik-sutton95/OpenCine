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
                // drawHierarchy draws blank in a test window (it may still return true), so the
                // layer tree is rendered directly.
                view.layer.render(in: context.cgContext)
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

        func ring(
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
                "posing-level-looking",
                ring(.posing(step: .tiltUp, inZone: false, hold: 0), completed: 1),
                settle: GyroCopy.holdHint
            ) { host, _ in
                XCTAssertTrue(host.identified("gyro.primary").isEmpty)
                let visual = host.identified("gyro.visual").first
                XCTAssertEqual(visual?.accessibilityLabel, GyroCopy.step(.tiltUp))
            }
            await inBothOrientations(
                "posing-tiltup-holding",
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
                "retry", ring(.retrying), settle: GyroCopy.retry)
            await inBothOrientations(
                "invalidated-camera", ring(.invalidated(.cameraChanged)),
                settle: GyroCopy.done
            ) { host, _ in
                XCTAssertEqual(host.identified("gyro.primary").count, 1)
            }
            let done = try Self.calibration()
            await inBothOrientations(
                "complete", ring(.complete(done), completed: 3),
                settle: GyroCopy.done
            ) { host, _ in
                XCTAssertEqual(host.identified("gyro.primary").count, 1)
                XCTAssertTrue(host.labelled(GyroCopy.cancel).isEmpty, "Complete has no Cancel")
            }
        }

        // MARK: Arming sheet

        func sheet(_ step: GyroArmingStep, ring: GyroRingPhase? = nil) -> GyroSetupSheet {
            GyroSetupSheet(step: step, ring: ring, completedSteps: 0, actions: GyroSetupActions())
        }

        /// The accent-filled buttons on a screen: `gyro.primary`, or the stabilization step's
        /// `gyro.setup.turnOff`, which is its primary and carries its own identifier.
        func primaries(_ host: Host) -> [NSObject] {
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

        // MARK: Logs and take page

        @MainActor final class ShareLog { var ids: [[UUID]] = [] }

        static let now = Date(timeIntervalSince1970: 1_792_000_000)

        /// A finished or recording take fixture. Summaries have no public init, so they decode.
        static func entry(
            minutesAgo: Double, length: Double = 48, active: Bool = false, calibrated: Bool = true,
            gaps: Bool = false, cutShort: Bool = false, mountMoved: Bool = false,
            summary hasSummary: Bool = true
        ) throws -> GyroLogEntry {
            let descriptor = GyroLogDescriptor(
                appName: "Test", cameraLabel: "Camera",
                startDate: now.addingTimeInterval(-minutesAgo * 60), approximateStartOffset: 0.12,
                isPartial: false, mountPreset: .unconfigured,
                mountCalibration: calibrated ? try calibration() : nil)
            var summary: GyroLogSummary?
            if hasSummary && !active {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor))
                        as? [String: Any])
                let json: [String: Any] = [
                    "descriptor": object, "sampleCount": 1000, "duration": length,
                    "measuredRate": 200, "largestGap": gaps ? 0.2 : 0.01,
                    "rejectedSampleCount": 0, "termination": cutShort ? "bufferOverflow" : "normal",
                    "isPartial": false, "approximateStartOffset": 0.12,
                ]
                .merging(mountMoved ? ["mountMovedOffset": 75.0] : [:]) { $1 }
                summary = try JSONDecoder().decode(
                    GyroLogSummary.self, from: JSONSerialization.data(withJSONObject: json))
            }
            return GyroLogEntry(descriptor: descriptor, summary: summary, active: active)
        }

        static func sampleEntries() throws -> [GyroLogEntry] {
            [
                try entry(minutesAgo: 1, length: 12, active: true),
                try entry(minutesAgo: 20, length: 48),
                try entry(minutesAgo: 45, length: 130, gaps: true),
                try entry(minutesAgo: 60 * 30, length: 65),
                try entry(minutesAgo: 60 * 30 + 10, length: 40, mountMoved: true),
                try entry(minutesAgo: 60 * 30 + 20, length: 31, cutShort: true),
                try entry(minutesAgo: 60 * 31, length: 20, calibrated: false),
            ]
        }

        func logs(
            _ entries: [GyroLogEntry], tip: Bool = true, enabled: Bool = true,
            actions: GyroLogsActions = GyroLogsActions()
        ) -> GyroLogsView {
            GyroLogsView(
                entries: entries, tipVisible: tip, gyroEnabled: enabled, now: Self.now,
                actions: actions)
        }

        func testRowsShowOneBadgeEach() async throws {
            // SwiftUI vends a List's rows lazily and only a foreground scene scrolls it, so the
            // package-only runner sees the first rows; three keep every one in view.
            let entries = Array(try Self.sampleEntries().prefix(3))
            await inBothOrientations(
                "logs-list", logs(entries), settle: GyroCopy.tip
            ) { host, landscape in
                let rows = host.identified("gyro.log.row")
                XCTAssertEqual(rows.count, entries.count)
                let statuses = Set(entries.map { GyroCopy.status($0.status) })
                for row in rows {
                    let label = row.accessibilityLabel ?? ""
                    XCTAssertEqual(statuses.filter { label.hasSuffix($0) }.count, 1, label)
                }
                XCTAssertFalse(host.labelled(GyroCopy.dismissTip).isEmpty)
                XCTAssertEqual(host.identified("gyro.logs.done").count, 1)
                if landscape {
                    XCTAssertEqual(host.identified("gyro.primary").count, 1)
                }
            }
        }

        func testTipFollowsTheFlag() async throws {
            let entries = try Self.sampleEntries()
            let host = await host(logs(entries, tip: false))
            defer { host.close() }
            await waitFor(GyroCopy.logsTitle, in: host)
            XCTAssertTrue(host.labelled(GyroCopy.dismissTip).isEmpty)
            XCTAssertTrue(host.labelled(GyroCopy.tip).isEmpty)
            XCTAssertEqual(host.identified("gyro.logs.select").count, 1)
        }

        func testEmptyStateShowsOneButton() async throws {
            await inBothOrientations(
                "logs-empty", logs([], tip: false, enabled: false), settle: GyroCopy.turnOnGyro
            ) { host, _ in
                XCTAssertEqual(host.identified("gyro.primary").count, 1)
                XCTAssertFalse(host.labelled(GyroCopy.emptyBody).isEmpty)
            }
            await inBothOrientations(
                "logs-empty-gyro-on", logs([], tip: false, enabled: true), settle: GyroCopy.emptyBody
            ) { host, _ in
                XCTAssertTrue(host.identified("gyro.primary").isEmpty)
                XCTAssertTrue(host.labelled(GyroCopy.turnOnGyro).isEmpty)
            }
        }

        func testTakePageLeadsWithTheVerdictAndSharePrimary() async throws {
            let ready = try Self.entry(minutesAgo: 20)
            let view = GyroTakeView(entry: ready, now: Self.now, share: {})
            await inBothOrientations("take-ready", view, settle: GyroCopy.shareLog) { host, landscape in
                let primaries = host.identified("gyro.primary")
                XCTAssertEqual(primaries.count, 1)
                XCTAssertEqual(primaries.first?.accessibilityLabel, GyroCopy.shareLog)
                let order = host.elements.compactMap { $0.accessibilityLabel }
                let verdict = order.firstIndex(of: GyroCopy.verdict(.ready))
                let share = order.firstIndex(of: GyroCopy.shareLog)
                XCTAssertNotNil(verdict)
                XCTAssertTrue((verdict ?? Int.max) < (share ?? 0), "Verdict leads the page")
                XCTAssertTrue(host.labelled("Open in Gyroflow").isEmpty)
                XCTAssertTrue(order.contains { $0.contains(GyroCopy.calibratedMount) })
                // Portrait fits, so every row is reachable; landscape may scroll them (a scroll
                // container vends nothing in a sceneless window, see testTakeDetailsScroll...).
                if !landscape {
                    XCTAssertTrue(order.contains { $0.contains(GyroCopy.sampleRate(200)) })
                }
            }
            for (state, entry) in [
                ("take-gaps", try Self.entry(minutesAgo: 45, gaps: true)),
                ("take-cutshort", try Self.entry(minutesAgo: 45, cutShort: true)),
                ("take-uncalibrated", try Self.entry(minutesAgo: 45, calibrated: false)),
                ("take-recording", try Self.entry(minutesAgo: 1, length: 12, active: true)),
            ] {
                await inBothOrientations(
                    state, GyroTakeView(entry: entry, now: Self.now, share: {}),
                    settle: GyroCopy.shareLog
                ) { host, _ in
                    let share = host.identified("gyro.primary").first
                    XCTAssertEqual(share?.accessibilityTraits.contains(.notEnabled), !entry.canShare)
                }
            }
        }

        func testActiveTakeCannotBeSelectedOrDeleted() async throws {
            let entries = Array(try Self.sampleEntries().prefix(3))
            let ready = entries[1]
            let shared = ShareLog()
            let view = logs(
                entries, tip: false, actions: GyroLogsActions(share: { shared.ids.append($0) }))
            let host = await host(view)
            defer { host.close() }
            await waitFor(GyroCopy.logsTitle, in: host)
            let select = try XCTUnwrap(host.identified("gyro.logs.select").first)
            XCTAssertTrue(select.accessibilityActivate())
            await waitFor(GyroCopy.shareCount(0), in: host)
            func row(_ status: GyroTakeStatus) throws -> NSObject {
                try XCTUnwrap(host.identified("gyro.log.row").first {
                    ($0.accessibilityLabel ?? "").hasSuffix(GyroCopy.status(status))
                })
            }
            let activeRow = try row(.recording)
            XCTAssertFalse((activeRow.accessibilityCustomActions ?? []).contains { $0.name == GyroCopy.delete })
            _ = activeRow.accessibilityActivate()
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(host.labelled(GyroCopy.shareCount(0)).isEmpty, "A recording take cannot be picked")
            XCTAssertTrue(host.labelled(GyroCopy.shareCount(1)).isEmpty)
            _ = try row(.ready).accessibilityActivate()
            await waitFor(GyroCopy.shareCount(1), in: host)
            XCTAssertEqual(host.identified("gyro.primary").count, 1)
            _ = try XCTUnwrap(host.identified("gyro.primary").first).accessibilityActivate()
            let sent = await HostedCondition.wait { !shared.ids.isEmpty }
            XCTAssertTrue(sent)
            XCTAssertEqual(shared.ids, [[ready.id]])
            let finished = try row(.ready)
            XCTAssertTrue((finished.accessibilityCustomActions ?? []).contains { $0.name == GyroCopy.delete })
        }

        func testSelectModeSnapshotInPortrait() async throws {
            let entries = try Self.sampleEntries()
            let host = await host(logs(entries, tip: false))
            defer { host.close() }
            await waitFor(GyroCopy.logsTitle, in: host)
            _ = try XCTUnwrap(host.identified("gyro.logs.select").first).accessibilityActivate()
            await waitFor(GyroCopy.shareCount(0), in: host)
            await snapshot(host, state: "logs-select", landscape: false)
        }

        func testLandscapeShowsListAndTakeSideBySide() async throws {
            let entries = try Self.sampleEntries()
            let host = await host(logs(entries), size: Self.landscape)
            defer { host.close() }
            await waitFor(GyroCopy.shareLog, in: host)
            let rows = host.identified("gyro.log.row")
            let selectedRows = rows.filter { $0.accessibilityTraits.contains(.selected) }
            XCTAssertEqual(selectedRows.count, 1, "The default take alone is highlighted")
            XCTAssertTrue(selectedRows.first?.accessibilityLabel?.hasSuffix(GyroCopy.status(.ready)) == true)
            let share = try XCTUnwrap(host.identified("gyro.primary").first)
            let rowFrame = try XCTUnwrap(rows.first).accessibilityFrame
            let shareFrame = share.accessibilityFrame
            XCTAssertLessThan(rowFrame.maxX, shareFrame.minX, "The list sits left of the take page")
            XCTAssertLessThanOrEqual(rowFrame.maxX, Self.landscape.width * 0.4 + 1)
            await snapshot(host, state: "logs-landscape-split", landscape: true)
            // A recording take can be opened (not picked): its page shows in the right pane.
            let recording = try XCTUnwrap(rows.first {
                ($0.accessibilityLabel ?? "").hasSuffix(GyroCopy.status(.recording))
            })
            _ = recording.accessibilityActivate()
            await waitFor(GyroCopy.verdict(.recording), in: host)
            let selectedRecording = host.identified("gyro.log.row").filter {
                $0.accessibilityTraits.contains(.selected)
            }
            XCTAssertEqual(selectedRecording.count, 1)
            XCTAssertTrue(selectedRecording.first?.accessibilityLabel?.hasSuffix(GyroCopy.status(.recording)) == true)
            await snapshot(host, state: "logs-landscape-recording", landscape: true)
            // Select mode leaves exactly one accent primary, the share bar.
            _ = try XCTUnwrap(host.identified("gyro.logs.select").first).accessibilityActivate()
            await waitFor(GyroCopy.shareCount(0), in: host)
            XCTAssertTrue(host.identified("gyro.log.row").allSatisfy {
                !$0.accessibilityTraits.contains(.selected)
            }, "Entering Select removes the detail highlight")
            XCTAssertEqual(host.identified("gyro.primary").count, 1)
            XCTAssertTrue(host.labelled(GyroCopy.shareLog).isEmpty)
            await snapshot(host, state: "logs-select", landscape: true)
            let portraitHost = await self.host(logs(entries), size: Self.portrait)
            defer { portraitHost.close() }
            await waitFor(GyroCopy.tip, in: portraitHost)
            XCTAssertTrue(portraitHost.identified("gyro.primary").isEmpty, "Portrait shows the list only")
        }

        // MARK: Tones and alignment

        func testBadgeAndVerdictTones() {
            XCTAssertEqual(GyroStatusTone.badge(.ready), GyroStatusTone.badge(.ready))
            let orange = GyroStatusTone.badge(.smallGaps)
            XCTAssertEqual(GyroStatusTone.badge(.mountMoved(offsetSeconds: 3)), orange)
            XCTAssertEqual(GyroStatusTone.badge(.notCalibrated), orange)
            XCTAssertEqual(GyroStatusTone.badge(.cutShort), GyroStatusTone.badge(.recording))
            XCTAssertNotEqual(GyroStatusTone.badge(.cutShort), orange)
            XCTAssertNotEqual(GyroStatusTone.badge(.ready), orange)
            XCTAssertEqual(GyroStatusTone.verdict(.cutShort), orange, "Verdict glyph stays orange")
            XCTAssertNotEqual(GyroStatusTone.verdict(.recording), orange)
        }

        func testLandscapeTextColumnIsLeftAligned() async throws {
            let host = await host(ring(.intro), size: Self.landscape)
            defer { host.close() }
            await waitFor(GyroCopy.getStarted, in: host)
            let title = try XCTUnwrap(host.labelled(GyroCopy.calibrateTitle).first(where: {
                HostedAccessibility.identifier($0) != "gyro.visual"
            }))
            let visual = try XCTUnwrap(host.identified("gyro.visual").first)
            XCTAssertGreaterThanOrEqual(title.accessibilityFrame.minX, visual.accessibilityFrame.maxX - 1)
            XCTAssertLessThan(title.accessibilityFrame.minX, Self.landscape.width * 0.6)
        }

        // MARK: Announcements

        @MainActor final class AnnouncementLog {
            var items: [String] = []
            var haptics = 0
        }

        @MainActor @Observable final class RingProbe {
            var phase: GyroRingPhase = .intro
            var event: GyroRingEvent?
            var token = 0
            var inSheet = false
        }

        struct RingProbeView: View {
            let probe: RingProbe
            let log: AnnouncementLog

            var body: some View {
                Group {
                    if probe.inSheet {
                        GyroSetupSheet(
                            step: .calibration(hasSavedCalibration: false), ring: probe.phase,
                            completedSteps: 0, lastEvent: probe.event, eventToken: probe.token,
                            actions: GyroSetupActions())
                    } else {
                        GyroRingCalibrationView(
                            phase: probe.phase, completedSteps: 0, lastEvent: probe.event,
                            eventToken: probe.token, canUseLast: false, actions: GyroSetupActions())
                    }
                }
                .environment(
                    \.gyroAnnouncer, GyroAnnouncer { [log] text in log.items.append(text) }
                )
                .environment(
                    \.gyroHaptics,
                    .init(isEnabled: { [log] in
                        log.haptics += 1
                        return false
                    }))
            }
        }

        func testRingAnnouncesProgressAndCaptures() async throws {
            try await runAnnouncements(inSheet: false)
        }

        func testSetupSheetForwardsRingEvents() async throws {
            try await runAnnouncements(inSheet: true)
        }

        private func runAnnouncements(inSheet: Bool) async throws {
            let probe = RingProbe()
            probe.inSheet = inSheet
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
            probe.phase = .posing(step: .level, inZone: true, hold: 0.55)
            await settle(2)
            probe.phase = .posing(step: .level, inZone: true, hold: 0.8)
            await settle(3)
            XCTAssertEqual(
                log.items,
                [25, 50, 75].map(GyroCopy.holdProgressA11y))
            XCTAssertEqual(log.haptics, 0)

            probe.event = .stepCaptured(.level)
            probe.token += 1
            await settle(4)
            XCTAssertEqual(log.items.last, GyroCopy.stepDoneA11y(1))
            XCTAssertEqual(log.haptics, 1, "One haptic per capture, paired with its announcement")

            // The same event again is only a new token.
            probe.token += 1
            await settle(5)
            XCTAssertEqual(log.items.last, GyroCopy.stepDoneA11y(1))
            XCTAssertEqual(log.haptics, 2)

            probe.event = .verificationFailed
            probe.token += 1
            await settle(6)
            XCTAssertEqual(log.items.last, GyroCopy.retry)

            probe.phase = .blocked(step: .tiltUp, reason: .recording)
            await settle(7)
            XCTAssertEqual(log.items.last, GyroCopy.block(.recording))
            probe.phase = .blocked(step: .tiltUp, reason: .moving)
            await settle(8)
            XCTAssertEqual(log.items.last, GyroCopy.block(.moving))

            probe.event = .completed(try Self.calibration())
            probe.token += 1
            await settle(9)
            XCTAssertEqual(log.items.last, GyroCopy.completeTitle)
            XCTAssertEqual(log.haptics, 3)
        }
    }
#endif
