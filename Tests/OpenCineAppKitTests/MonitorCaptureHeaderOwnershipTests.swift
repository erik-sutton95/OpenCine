#if os(iOS)
import Foundation
import MonitorPresentation
import Observation
import OpenCineCore
import OpenCineCoreTestSupport
import OpenCineHostedAccessibility
import SwiftUI
import UIKit
import XCTest

@testable import OpenCineAppKit

/// SIMULATED public actions use the same real modifier and ownership in the header and row.
/// Pointer hold/drag is deliberately not synthesized through private UIKit touch APIs.
@MainActor
final class MonitorCaptureHeaderOwnershipTests: XCTestCase {
    func testReadOnlyHeaderOpensTheReportedFieldWithoutDispatchingAWrite() async throws {
        let fixture = try await HeaderFixture.make(camera: MonitorContractCameraFixture.camera(access: .readOnly),
            commandEnabled: false)
        defer { fixture.close() }
        let header = try await fixture.element("contract.header.iso")
        XCTAssertEqual(header.accessibilityValue, "200")
        await fixture.activate(header, expecting: [.iso])
        XCTAssertEqual(fixture.probe.opened, [.iso])
        XCTAssertNil(fixture.probe.state.preview)
        XCTAssertNil(fixture.probe.state.ownership.owner)
        XCTAssertEqual(fixture.probe.previewNotifications, 0)
        XCTAssertEqual(fixture.probe.nativeCommits, 0)
        let wire = await fixture.camera.wire
        XCTAssertTrue(wire.isEmpty)
    }

    func testHostDisabledHeaderCannotOpenTheReportedField() async throws {
        let fixture = try await HeaderFixture.make(camera: MonitorContractCameraFixture.camera(), enabled: false)
        defer { fixture.close() }
        let header = try await fixture.element("contract.header.iso")
        _ = header.accessibilityActivate()
        await fixture.settleActions()
        XCTAssertTrue(fixture.probe.opened.isEmpty)
        let wire = await fixture.camera.wire
        XCTAssertTrue(wire.isEmpty)
    }

    func testHeaderAndRowRespectTheSameActivePointerOwner() async throws {
        let fixture = try await HeaderFixture.make(camera: MonitorContractCameraFixture.camera())
        defer { fixture.close() }
        let header = try await fixture.element("contract.header.iso")
        let row = try await fixture.element("contract.row.iso")
        let owner = UUID()
        let revision = fixture.probe.state.ownership.acquire(owner)
        XCTAssertNotNil(revision)
        _ = header.accessibilityActivate()
        _ = row.accessibilityActivate()
        await fixture.settleActions()
        XCTAssertTrue(fixture.probe.opened.isEmpty)
        XCTAssertEqual(fixture.probe.state.ownership.owner, owner)
        fixture.probe.state.ownership.release(owner)
        await fixture.activate(row, expecting: [.iso])
        await fixture.activate(header, expecting: [.iso, .iso])
        XCTAssertEqual(fixture.probe.opened, [.iso, .iso])
        XCTAssertEqual(fixture.probe.previewNotifications, 0)
        let wire = await fixture.camera.wire
        XCTAssertTrue(wire.isEmpty)
    }

    func testNativePresentationOwnerExcludesBothHeaderAndRowInspection() async throws {
        let fixture = try await HeaderFixture.make(camera: MonitorContractCameraFixture.camera())
        defer { fixture.close() }
        let header = try await fixture.element("contract.header.iso")
        let row = try await fixture.element("contract.row.iso")
        fixture.probe.presentationOwner = UUID()
        _ = header.accessibilityActivate()
        _ = row.accessibilityActivate()
        await fixture.settleActions()
        XCTAssertTrue(fixture.probe.opened.isEmpty)
        fixture.probe.presentationOwner = nil
        await fixture.activate(header, expecting: [.iso])
        XCTAssertEqual(fixture.probe.opened, [.iso])
    }

    func testRetirementInvalidatesTheDeferredRevisionAndPreservesInspection() async throws {
        let fixture = try await HeaderFixture.make(camera: MonitorContractCameraFixture.camera())
        defer { fixture.close() }
        let header = try await fixture.element("contract.header.iso")
        let owner = UUID()
        let revision = try XCTUnwrap(fixture.probe.state.ownership.acquire(owner))
        fixture.probe.state.ownership.release(owner)
        XCTAssertTrue(fixture.probe.state.ownership.permitsDeferredCommit(revision))
        fixture.probe.state.retire()
        XCTAssertFalse(fixture.probe.state.ownership.permitsDeferredCommit(revision))
        XCTAssertNil(fixture.probe.state.ownership.owner)
        await fixture.activate(header, expecting: [.iso])
        XCTAssertEqual(fixture.probe.opened, [.iso])
        let wire = await fixture.camera.wire
        XCTAssertTrue(wire.isEmpty)
    }

    func testRecoveredEpochRejectsTheHeaderCapturedUnderTheOldSource() async throws {
        let fixture = try await HeaderFixture.make(camera: MonitorContractCameraFixture.camera())
        defer { fixture.close() }
        let header = try await fixture.element("contract.header.iso")
        let before = fixture.probe.field
        let attempt = await fixture.camera.loseLink()
        let recovering = await eventually { fixture.probe.control.captureField(.iso)?.isEditable == false }
        XCTAssertTrue(recovering)
        await fixture.camera.completeAttempt(attempt)
        let recovered = await eventually {
            fixture.probe.control.captureField(.iso)?.isEditable == true
                && fixture.probe.control.snapshot?.epoch != fixture.probe.source.epoch
        }
        XCTAssertTrue(recovered)
        let after = try XCTUnwrap(fixture.probe.control.captureField(.iso))
        XCTAssertEqual(after.selection, before.selection)
        XCTAssertEqual(after.choices, before.choices)
        XCTAssertNotEqual(after.editor, before.editor)
        _ = header.accessibilityActivate()
        await fixture.settleActions()
        XCTAssertTrue(fixture.probe.opened.isEmpty)
        XCTAssertNil(fixture.probe.state.ownership.owner)
        let wire = await fixture.camera.wire
        XCTAssertTrue(wire.isEmpty)
    }

    func testReplacementWithTheSameDisplayedValueRejectsTheOldHeader() async throws {
        let fixture = try await HeaderFixture.make(camera: MonitorContractCameraFixture.camera())
        defer { fixture.close() }
        let header = try await fixture.element("contract.header.iso")
        let next = MonitorContractCameraFixture.camera()
        await next.cameraReportsStatus()
        fixture.probe.control.bind(next)
        let replaced = await eventually { fixture.probe.control.snapshot?.session == next.id }
        XCTAssertTrue(replaced)
        XCTAssertEqual(fixture.probe.control.captureField(.iso)?.label, fixture.probe.field.label)
        _ = header.accessibilityActivate()
        await fixture.settleActions()
        XCTAssertTrue(fixture.probe.opened.isEmpty, "Inspection cannot borrow a successor with identical labels")
        let oldWire = await fixture.camera.wire
        let nextWire = await next.wire
        XCTAssertTrue(oldWire.isEmpty && nextWire.isEmpty)
    }
}

@MainActor
@Observable
private final class HeaderProbe {
    let control: MonitorControlModel
    let field: MonitorCaptureField
    let source: MonitorCaptureSourceIdentity
    let enabled: Bool
    let commandEnabled: Bool
    let state = MonitorOperatorCaptureState<SettingKey, Never>()
    var presentationOwner: UUID?
    var opened: [SettingKey] = []
    var previewNotifications = 0
    var nativeCommits = 0
    init(control: MonitorControlModel, field: MonitorCaptureField, source: MonitorCaptureSourceIdentity,
        enabled: Bool, commandEnabled: Bool) {
        self.control = control; self.field = field; self.source = source
        self.enabled = enabled; self.commandEnabled = commandEnabled
    }
    var isCurrent: Bool {
        control.snapshot?.session == source.camera && control.snapshot?.epoch == source.epoch
    }
    func readout(_ identifier: String) -> MonitorOperatorLiveReadout<SettingKey, String> {
        .init(id: .iso, title: field.title, value: field.label ?? "Not set", field: field,
            accessibilityIdentifier: identifier)
    }
    var inputs: MonitorOperatorCaptureInputs<SettingKey, String, Never> {
        .init(readouts: [readout("contract.row.iso")], fields: [.iso: field], haptics: false,
            open: { [weak self] key in self?.opened.append(key) }, dismiss: {},
            nativeQuick: { _ in nil }, nativeCurrent: { _, _ in false },
            nativeCommit: { [weak self] _, _, _ in self?.nativeCommits += 1 },
            previewChanged: { [weak self] _, _ in self?.previewNotifications += 1 },
            presentationOwner: { [weak self] in self?.presentationOwner })
    }
}

private struct HeaderContractSurface: View {
    let probe: HeaderProbe
    var body: some View {
        VStack(spacing: 30) {
            MonitorOperatorCaptureHeaderReadout(inputs: probe.inputs, control: probe.control, state: probe.state,
                source: probe.source, readout: probe.readout("contract.header.iso"), enabled: probe.enabled,
                commandEnabled: probe.commandEnabled, currentSource: { probe.isCurrent }) {
                Text(probe.field.label ?? "Not set")
            }
            MonitorOperatorCaptureStrip(inputs: probe.inputs, control: probe.control, state: probe.state,
                source: probe.source, enabled: probe.enabled, commandEnabled: probe.commandEnabled,
                currentSource: { probe.isCurrent })
        }.frame(width: 360, height: 240).environment(\.scenePhase, .active)
            .coordinateSpace(name: "monitor.canvas")
    }
}

@MainActor
private final class HeaderFixture {
    let camera: FakeCameraSession
    let probe: HeaderProbe
    let host: UIHostingController<HeaderContractSurface>
    let window: UIWindow
    private init(camera: FakeCameraSession, probe: HeaderProbe) {
        self.camera = camera; self.probe = probe
        host = UIHostingController(rootView: HeaderContractSurface(probe: probe))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }
    static func make(camera: FakeCameraSession, enabled: Bool = true,
        commandEnabled: Bool = true) async throws -> HeaderFixture {
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        let loaded = await eventually { control.captureField(.iso) != nil }
        XCTAssertTrue(loaded)
        let field = try XCTUnwrap(control.captureField(.iso))
        let snapshot = try XCTUnwrap(control.snapshot)
        let probe = HeaderProbe(control: control, field: field,
            source: .init(camera: snapshot.session, epoch: snapshot.epoch, monitor: UUID(), picture: "SIMULATED"),
            enabled: enabled, commandEnabled: commandEnabled)
        return HeaderFixture(camera: camera, probe: probe)
    }
    func close() {
        window.isHidden = true; window.rootViewController = nil
        probe.control.unbind()
    }
    func element(_ identifier: String) async throws -> NSObject {
        for _ in 0..<200 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            if let element = HostedAccessibility.leaves(in: host.view).first(where: { HostedAccessibility.identifier($0) == identifier }) { return element }
            await Task.yield()
        }
        return try XCTUnwrap(HostedAccessibility.leaves(in: host.view).first { HostedAccessibility.identifier($0) == identifier },
            "The real shared header/row accessibility element must be mounted")
    }
    func activate(_ element: NSObject, expecting opened: [SettingKey]) async {
        XCTAssertTrue(element.accessibilityActivate())
        let delivered = await eventually { probe.opened == opened }
        XCTAssertTrue(delivered, "The actual accessibility action must reach the captured header/row")
    }
    func settleActions() async {
        for _ in 0..<50 { await Task.yield() }
    }
}
#endif
