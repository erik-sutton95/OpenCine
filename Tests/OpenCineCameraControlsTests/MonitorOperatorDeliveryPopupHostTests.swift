#if os(iOS)
import Observation
import OpenCineAppKit
import OpenCineCameraControls
import SwiftUI
import UIKit
import XCTest

private typealias Preparation = MonitorDeliveryPreparationModel<Int, Int, String, Int, Int>
private typealias Host = MonitorOperatorDeliveryPopupHost<Int, Int, String, Int, Int, Color>

@MainActor @Observable private final class PopupHostInputs {
    var selection = "A"
    /// Bumped to re-render the parent, as gallery download progress does.
    var tick = 0
    @ObservationIgnored var made: [(selection: String, model: Preparation)] = []
}

private struct PopupHostParent: View {
    let inputs: PopupHostInputs
    var body: some View {
        let selection = inputs.selection
        ZStack {
            Text("tick \(inputs.tick)")
            Host(
                selectionID: selection,
                make: {
                    var configuration = MonitorDeliveryExportConfiguration(logTransform: 0, exportFormat: 0)
                    configuration.bakeLUT = false
                    let model = Preparation(
                        selection: {
                            .init(files: [.init(filename: selection + ".mov", sizeBytes: nil)], cachedCount: 1,
                                connected: nil)
                        }, configuration: configuration, exportOptions: nil, preferredDestination: .nativeShare,
                        sourceCurrent: { true })
                    inputs.made.append((selection, model))
                    return (model, { _ in })
                }, onDismiss: {}, remoteArtwork: { Color.gray })
        }
    }
}

/// A2-74: the shared popup host makes one preparation per selection identity.
@MainActor final class MonitorOperatorDeliveryPopupHostTests: XCTestCase {
    private func settle(_ host: UIViewController, until condition: () -> Bool) async throws -> Bool {
        for _ in 0..<60 {
            host.view.layoutIfNeeded()
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        host.view.layoutIfNeeded()
        return condition()
    }

    func testParentRerendersMakeOnePreparationAndANewSelectionReplacesIt() async throws {
        let inputs = PopupHostInputs()
        let host = UIHostingController(rootView: PopupHostParent(inputs: inputs))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let shown = try await settle(host) { !inputs.made.isEmpty }
        XCTAssertTrue(shown, "The popup must make its preparation on first display")
        for tick in 1...8 {
            inputs.tick = tick
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutIfNeeded()
        }
        XCTAssertEqual(inputs.made.map(\.selection), ["A"], "Parent re-renders must not remake the preparation")
        let first = try XCTUnwrap(inputs.made.first?.model)
        XCTAssertTrue(first.canContinue)

        inputs.selection = "B"
        let replaced = try await settle(host) { inputs.made.count == 2 && !first.canContinue }
        XCTAssertTrue(replaced, "A new selection makes a new preparation and closes the old one")
        XCTAssertEqual(inputs.made.map(\.selection), ["A", "B"])
        XCTAssertEqual(inputs.made.last?.model.selection.files.map(\.filename), ["B.mov"])
        XCTAssertTrue(try XCTUnwrap(inputs.made.last?.model).canContinue)
    }
}
#endif
