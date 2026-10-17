#if os(iOS)
import MonitorPresentation
import Observation
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

@testable import OpenCineAppKit

/// SIMULATED hosted tests invoke the real public accessibility default action.
/// A missing tree fails the test; it cannot count as proof of a disabled action.
@MainActor
final class MonitorCaptureReadoutInspectionTests: XCTestCase {
    func testReadOnlySettingCanBeInspectedWithoutSendingACommand() async throws {
        try await exerciseInspection(camera: MonitorContractCameraFixture.camera(access: .readOnly))
    }

    func testSettingWithoutADomainCanBeInspectedWithoutInventingAWrite() async throws {
        try await exerciseInspection(camera: MonitorContractCameraFixture.camera(domain: nil))
    }

    func testHostDisabledReadOnlySettingDoesNotOpen() async throws {
        try await exerciseInspection(
            camera: MonitorContractCameraFixture.camera(access: .readOnly), enabled: false)
    }

    private func exerciseInspection(camera: FakeCameraSession, enabled: Bool = true) async throws {
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        defer { control.unbind() }
        let loaded = await eventually { control.captureField(.iso) != nil }
        XCTAssertTrue(loaded)
        let field = try XCTUnwrap(control.captureField(.iso))
        XCTAssertFalse(field.isEditable)
        let probe = InspectionProbe(control: control, field: field, enabled: enabled)
        let host = UIHostingController(rootView: InspectionReadout(probe: probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        let element = try await readoutElement(in: host.view)
        XCTAssertTrue(probe.opened.isEmpty, "Mounting must not act as an operator tap")
        XCTAssertEqual(element.accessibilityValue, "200")
        let activated = element.accessibilityActivate()
        if enabled {
            XCTAssertTrue(activated)
            let opened = await eventually { probe.opened == [field] }
            XCTAssertTrue(opened, "The actual default action must reach the captured field")
            XCTAssertEqual(probe.opened, [field], "Inspection must reach the captured field")
        } else {
            XCTAssertTrue(probe.opened.isEmpty, "Host admission must still block presentation")
        }
        XCTAssertEqual(probe.previews, 0)
        XCTAssertEqual(probe.commits, 0)
        XCTAssertNil(probe.ownership.owner)
        XCTAssertTrue(control.pending.isEmpty)
        let wire = await camera.wire
        XCTAssertTrue(wire.isEmpty, "Opening a setting must never dispatch a camera write")
    }

    private func readoutElement(in view: UIView) async throws -> NSObject {
        for _ in 0..<200 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            if let node = HostedAccessibility.leaves(in: view).first(where: { HostedAccessibility.identifier($0) == "contract.capture.iso" }) {
                return node
            }
            await Task.yield()
        }
        return try XCTUnwrap(HostedAccessibility.leaves(in: view).first { HostedAccessibility.identifier($0) == "contract.capture.iso" },
            "The real readout accessibility element must be mounted")
    }
}

@MainActor
@Observable
private final class InspectionProbe {
    let control: MonitorControlModel
    let field: MonitorCaptureField
    let enabled: Bool
    var ownership = MonitorReadoutOwnership()
    var opened: [MonitorCaptureField] = []
    var previews = 0
    var commits = 0

    init(control: MonitorControlModel, field: MonitorCaptureField, enabled: Bool) {
        self.control = control; self.field = field; self.enabled = enabled
    }
}

private struct InspectionReadout: View {
    @Bindable var probe: InspectionProbe
    var body: some View {
        MonitorCaptureReadout(control: probe.control, field: probe.field, enabled: probe.enabled,
            active: false, ownership: $probe.ownership, presentationOwner: { nil }) { event in
            switch event {
            case .open(let field): probe.opened.append(field)
            case .preview: probe.previews += 1
            case .commit: probe.commits += 1
            case .cancel: break
            }
        }.accessibilityIdentifier("contract.capture.iso")
            .environment(\.scenePhase, .active)
    }
}
#endif
