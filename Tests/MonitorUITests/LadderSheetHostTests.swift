#if os(iOS)
import Observation
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

/// SIMULATED native input drives the production ladder, including its actual drum actions.
@MainActor
final class LadderSheetHostTests: XCTestCase {
    func testObservationsPreviewAndDismissalDoNotWriteWhileExplicitInputWritesOnce() async throws {
        let runtimeReady = await HostedAccessibility.awaitRuntime()
        XCTAssertTrue(runtimeReady)
        let probe = LadderHostProbe()
        let controller = UIHostingController(rootView: ControlledLadder(probe: probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 400))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil }

        _ = try await value("Not set", in: controller.view)
        XCTAssertTrue(probe.writes.isEmpty, "An unknown observation cannot write the first detent")
        probe.selection = "800"
        _ = try await value("800", in: controller.view)
        XCTAssertTrue(probe.writes.isEmpty, "External observations repaint without echoing a command")

        probe.previewPosition = 0
        probe.selection = "400"
        let preview = try await value("400", in: controller.view)
        preview.accessibilityIncrement()
        XCTAssertTrue(probe.writes.isEmpty, "Highlighting a readout preview is not an operator commit")
        probe.presented = false
        await Task.yield()
        controller.view.layoutIfNeeded()
        XCTAssertTrue(probe.writes.isEmpty, "Cancel/dismiss sends no command")

        probe.previewPosition = nil
        probe.presented = true
        let editable = try await value("400", in: controller.view)
        editable.accessibilityIncrement()
        _ = try await value("800", in: controller.view)
        XCTAssertEqual(probe.writes, [LadderWrite(key: "iso", value: "800")])
        probe.selection = "400"
        _ = try await value("400", in: controller.view)
        XCTAssertEqual(probe.writes.count, 1, "A later camera report must not replay an edit")
    }

    private func value(_ expected: String, in view: UIView) async throws -> NSObject {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            view.setNeedsLayout(); view.layoutIfNeeded()
            if let element = HostedAccessibility.leaves(in: view).first(where: {
                $0.accessibilityLabel == "Value" && $0.accessibilityValue == expected
            }) { return element }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(HostedAccessibility.leaves(in: view).first {
            $0.accessibilityLabel == "Value" && $0.accessibilityValue == expected
        }, "The actual ladder must present \(expected)")
    }
}

@MainActor @Observable
private final class LadderHostProbe {
    var selection: String?
    var previewPosition: Double?
    var presented = true
    var writes: [LadderWrite<String>] = []
}

private struct ControlledLadder: View {
    let probe: LadderHostProbe

    var body: some View {
        if probe.presented {
            LadderSheet(
                presentation: LadderSheetPresentation(title: "ISO", subtitle: "Sensitivity", tabs: [
                    LadderTab(label: "ISO", key: "iso", ladder: CaptureLadder(
                        current: probe.selection, values: ["400", "800"]), applyOnActivate: false)
                ]), enabled: true,
                onWrite: { write in probe.writes.append(write); probe.selection = write.value },
                host: LadderSheetHost(selectedTab: 0, selection: probe.selection, drum: .labels,
                    previewPosition: probe.previewPosition, onSelectTab: { _ in }))
        }
    }
}
#endif
