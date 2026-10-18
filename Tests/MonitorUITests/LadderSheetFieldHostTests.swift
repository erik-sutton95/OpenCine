#if os(iOS)
import Observation
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

/// SIMULATED camera, real retained editor, production field ladder and native drum input.
@MainActor
final class LadderSheetFieldHostTests: XCTestCase {
    func testObservationsPreviewAndDismissalDoNotWriteWhileFilteredNativeInputCommitsOnce() async throws {
        let camera = FakeCameraSession.lunaLike()
        let probe = try await fixture(camera: camera)
        defer { probe.control.unbind() }
        XCTAssertTrue(probe.field.choices.contains { $0.label == "400" })
        XCTAssertEqual(probe.choices.map(\.label), ["200", "800"])
        let (controller, window) = mount(probe)
        defer { window.isHidden = true; window.rootViewController = nil }
        _ = try await value("200", in: controller.view)
        try await assertNoWrites(probe, camera: camera)

        let report = CameraTimecode(hours: 1, minutes: 2, seconds: 3, frames: 0)
        await camera.cameraReportsTimecode(report)
        let observed = await waitUntil { probe.control.timecode.value == report }
        XCTAssertTrue(observed, "The real control must consume the camera's external report")
        _ = try await value("200", in: controller.view)
        try await assertNoWrites(probe, camera: camera)

        probe.previewPosition = 1
        probe.previewSelection = "800"
        let preview = try await value("800", in: controller.view)
        preview.accessibilityIncrement()
        try await assertNoWrites(probe, camera: camera)
        probe.presented = false
        let dismissed = await waitUntil {
            controller.view.layoutIfNeeded()
            return !HostedAccessibility.leaves(in: controller.view).contains { $0.accessibilityLabel == "Value" }
        }
        XCTAssertTrue(dismissed, "The actual field ladder must leave the native tree")
        try await assertNoWrites(probe, camera: camera)

        probe.previewPosition = nil
        probe.previewSelection = nil
        probe.presented = true
        let editable = try await value("200", in: controller.view)
        editable.accessibilityIncrement()
        let dispatched = await waitUntil { await camera.wire.count == 1 }
        XCTAssertTrue(dispatched, "A real native action must reach the admitted camera backend")
        let wire = await camera.wire
        XCTAssertEqual(wire, ["set \(SettingValue.iso(.manual(800)))"])
        XCTAssertEqual(probe.commits, [.iso(.manual(800))], "Exactly one typed callback follows admission")
        XCTAssertTrue(probe.labelWrites.isEmpty, "Typed fields cannot fall through the label-write route")
        XCTAssertEqual(probe.control.shown(.iso), .iso(.manual(800)))
        XCTAssertEqual(probe.control.captureValue(.iso, selection: .reported), .iso(.manual(200)))
        _ = try await value("800", in: controller.view)
        await camera.cameraReportsStatus()
        await Task.yield()
        let finalWire = await camera.wire
        XCTAssertEqual(finalWire.count, 1, "Later reports cannot replay the native edit")
        XCTAssertEqual(probe.commits.count, 1)
    }

    func testReplacingTheSourceRejectsTheRetainedEditorAndCallback() async throws {
        let camera = FakeCameraSession.lunaLike()
        let probe = try await fixture(camera: camera)
        defer { probe.control.unbind() }
        let (controller, window) = mount(probe)
        defer { window.isHidden = true; window.rootViewController = nil }
        _ = try await value("200", in: controller.view)
        let successor = FakeCameraSession.lunaLike()
        await successor.cameraReportsStatus()
        probe.control.bind(successor)
        let rebound = await waitUntil { probe.control.captureField(.iso)?.editor != probe.field.editor }
        XCTAssertTrue(rebound)
        _ = try await element(label: "Editor state", value: "Retired", in: controller.view)
        let retired = try await value("200", in: controller.view)
        retired.accessibilityIncrement()
        try await assertNoWrites(probe, camera: camera)
        let successorWire = await successor.wire
        XCTAssertTrue(successorWire.isEmpty, "A stale ladder cannot target the newly bound camera")
        XCTAssertNotEqual(probe.control.captureField(.iso)?.editor, probe.field.editor)
    }

    func testEmptyCapturedChoicesDoNotWidenToTheCameraOrPresentationDomain() async throws {
        let camera = FakeCameraSession.lunaLike()
        let probe = try await fixture(camera: camera)
        defer { probe.control.unbind() }
        XCTAssertGreaterThan(probe.field.choices.count, 2)
        probe.choices = []
        let (controller, window) = mount(probe)
        defer { window.isHidden = true; window.rootViewController = nil }
        let empty = try await value("200", in: controller.view)
        empty.accessibilityIncrement()
        try await assertNoWrites(probe, camera: camera)
        XCTAssertEqual(probe.control.shown(.iso), .iso(.manual(200)))
    }

    private func fixture(camera: FakeCameraSession) async throws -> FieldLadderProbe {
        let runtimeReady = await HostedAccessibility.awaitRuntime()
        XCTAssertTrue(runtimeReady)
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        let loaded = await waitUntil { control.captureField(.iso)?.isEditable == true }
        XCTAssertTrue(loaded)
        let field = try XCTUnwrap(control.captureField(.iso))
        return FieldLadderProbe(control: control, field: field,
            choices: field.choices.filter { ["200", "800"].contains($0.label) })
    }

    private func mount(_ probe: FieldLadderProbe) -> (UIViewController, UIWindow) {
        let controller = UIHostingController(rootView: FieldLadder(probe: probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 400))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        return (controller, window)
    }

    private func assertNoWrites(_ probe: FieldLadderProbe, camera: FakeCameraSession) async throws {
        await Task.yield()
        let wire = await camera.wire
        XCTAssertTrue(wire.isEmpty)
        XCTAssertTrue(probe.commits.isEmpty)
        XCTAssertTrue(probe.labelWrites.isEmpty)
        XCTAssertTrue(probe.control.pending.isEmpty)
    }

    private func value(_ expected: String, in view: UIView) async throws -> NSObject {
        try await element(label: "Value", value: expected, in: view)
    }

    private func element(label: String, value: String, in view: UIView) async throws -> NSObject {
        let published = await waitUntil {
            view.setNeedsLayout(); view.layoutIfNeeded()
            return HostedAccessibility.leaves(in: view).contains {
                $0.accessibilityLabel == label && $0.accessibilityValue == value
            }
        }
        XCTAssertTrue(published)
        return try XCTUnwrap(HostedAccessibility.leaves(in: view).first {
            $0.accessibilityLabel == label && $0.accessibilityValue == value
        }, "The actual field ladder must publish \(label): \(value)")
    }

    private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }
}

@MainActor @Observable
private final class FieldLadderProbe {
    let control: MonitorControlModel
    let field: MonitorCaptureField
    var choices: [MonitorCaptureChoice]
    var previewPosition: Double?
    var previewSelection: String?
    var presented = true
    var commits: [SettingValue] = []
    var labelWrites: [LadderWrite<SettingKey>] = []

    init(control: MonitorControlModel, field: MonitorCaptureField, choices: [MonitorCaptureChoice]) {
        self.control = control; self.field = field; self.choices = choices
    }
}

private struct FieldLadder: View {
    let probe: FieldLadderProbe

    var body: some View {
        if probe.presented {
            VStack {
                Text("Editor state").accessibilityLabel("Editor state")
                    .accessibilityValue(probe.control.captureField(.iso)?.editor == probe.field.editor ? "Current" : "Retired")
                LadderSheet(
                    presentation: LadderSheetPresentation(title: "ISO field", subtitle: "Sensitivity", tabs: [
                        LadderTab(label: "ISO", key: SettingKey.iso,
                            ladder: CaptureLadder(current: probe.field.label,
                                values: probe.field.choices.map(\.label)), applyOnActivate: false)
                    ]), enabled: true, onWrite: { probe.labelWrites.append($0) },
                    control: probe.control,
                    host: LadderSheetHost(selectedTab: 0,
                        selection: probe.previewSelection ?? probe.control.shown(.iso).map(MonitorCapturePresentation.label),
                        drum: .field(probe.field, choices: probe.choices), previewPosition: probe.previewPosition,
                        onSelectTab: { _ in }, onCommitted: { probe.commits.append($0) }))
            }
        }
    }
}
#endif
