#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import Observation
import OpenCineAppKit
import OpenCineCore
import OpenCineHostedAccessibility
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

@testable import OpenCineCameraControls

/// SIMULATED hosted actions enter the actual canonical body and its forwarded record service.
/// This is the real service path for a source without a local CameraSession binding.
@MainActor
final class CanonicalMonitorRecordAdmissionTests: XCTestCase {
    func testAllowedRecordActionEntersTheCapturedServiceOnce() async throws {
        let fixture = try RecordBodyFixture()
        defer { fixture.close() }
        let button = try await fixture.recordElement()
        XCTAssertEqual(fixture.probe.requests, 0, "Mounting must not start recording")
        XCTAssertTrue(button.accessibilityActivate())
        await fixture.waitForRequests(1)
        XCTAssertEqual(fixture.probe.requests, 1)
        XCTAssertEqual(fixture.probe.confirmations, 0)
    }

    func testLockedMonitorCannotEnterTheRecordService() async throws {
        try await assertRecordRefused { $0.session.locked = true }
    }

    func testSessionBusyProjectionCannotEnterTheRecordService() async throws {
        try await assertRecordRefused { $0.busy = true }
    }

    func testReadOnlyMonitorCannotEnterTheRecordService() async throws {
        try await assertRecordRefused { $0.readOnly = true }
    }

    func testRetiredSourceCannotUseTheMountedRecordAction() async throws {
        let fixture = try RecordBodyFixture()
        defer { fixture.close() }
        let button = try await fixture.recordElement()
        fixture.probe.currentSource = .init(monitor: UUID(), camera: nil, epoch: nil, picture: "SIMULATED")
        _ = button.accessibilityActivate()
        await fixture.settleActions()
        XCTAssertEqual(fixture.probe.requests, 0, "An outgoing action must not borrow the successor")
    }

    func testUnknownRecordingDoesNotBecomeAnAdmittedStart() async throws {
        try await assertRecordRefused { $0.recording = nil }
    }

    private func assertRecordRefused(_ configure: (RecordBodyProbe) -> Void) async throws {
        let fixture = try RecordBodyFixture(configure: configure)
        defer { fixture.close() }
        let button = try await fixture.recordElement()
        _ = button.accessibilityActivate()
        await fixture.settleActions()
        XCTAssertEqual(fixture.probe.requests, 0)
        XCTAssertEqual(fixture.probe.confirmations, 0)
    }
}

@MainActor
@Observable
private final class RecordBodyProbe: ChromeEditHost {
    typealias Palette = MonitorDefaultLivePalette
    typealias ChromeSection = MonitorDisplayChrome.Section
    typealias ChromeMode = MonitorDisplayMode
    let identity: MonitorOperatorLiveIdentity
    /// Unobserved, so a change models a source that moved on before the mounted body re-rendered.
    @ObservationIgnored var currentSource: MonitorOperatorLiveIdentity
    var busy = false
    var readOnly = false
    var recording: Bool? = false
    var requests = 0
    var confirmations = 0
    var usage = MonitorToolUsage()
    let control = MonitorControlModel()
    let assist: MonitorAssistState<RecordBodyLooks>
    let session: MonitorOperatorSessionModel<RecordBodyLooks>
    var note: String?
    var portraitAspect = PortraitFeedAspect.fit16x9
    let storage: UserDefaults
    let storageName: String

    init() throws {
        let identity = MonitorOperatorLiveIdentity(monitor: UUID(), camera: nil, epoch: nil, picture: "SIMULATED")
        self.identity = identity
        currentSource = identity
        let name = "SIMULATED.canonical-record." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        storageName = name; storage = preferences
        assist = MonitorAssistState(looks: RecordBodyLooks(), storage: preferences,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
        var document: Data?
        let cameras = CamerasModel(integrations: [], store: SavedCamerasStore(document: StoredData(
            read: { document }, write: { document = $0 })))
        let display = MonitorDisplayPreferences(storage: preferences, keys: .init(live: "live", clean: "clean"))
        session = MonitorOperatorSessionModel(shell: ShellModel(cameras: cameras, control: control),
            assist: assist, display: display)
    }

    var hapticsEnabled: Bool { false }
    var chromeEditSections: [ChromeSection] { ChromeSection.allCases }
    func chromeSectionTitle(_ section: ChromeSection) -> String { section.title }
    func chromeSectionID(_ section: ChromeSection) -> String { section.rawValue }
    func chromeModeTitle(_ mode: ChromeMode) -> String { mode.title }
    func isChromeConfigurable(_ section: ChromeSection, in mode: ChromeMode) -> Bool { false }
    func isChromeVisible(_ section: ChromeSection, in mode: ChromeMode) -> Bool { section == .railRecord }
    func toggleChrome(_ section: ChromeSection, for mode: ChromeMode) {}
    func endChromeEditing() {}
}

@MainActor
private final class RecordBodyLooks: MonitorLookProvider {
    var selection: Int { 0 }
    var cube: CubeLUT? { nil }
    var transfer: MonitorTransfer { .rec709 }
    var referenceClipByte: Int { 255 }
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
}

private struct RecordContractSurface: View {
    @Bindable var probe: RecordBodyProbe
    var body: some View {
        let layout = LiveMonitorLayout.fieldMonitor(size: CGSize(width: 420, height: 900), safeArea: EdgeInsets(),
            sourceAspect: 16 / 9, fill: false, showsValues: false, showsBottomBars: false)
        MonitorOperatorLiveSurface(host: probe, control: probe.control, session: probe.session, layout: layout,
            source: MonitorOperatorLiveSource<SettingKey, Never>(
                identity: { probe.currentSource }, available: { [.railRecord] },
                picture: { .init(aspect: 16 / 9, waiting: false, vertical: false, flipped: false, recovering: false) },
                status: { .init(recording: .init(recording: probe.recording), showsTimecode: false, showsRecording: false) },
                cameraBattery: { nil },
                capture: { .init(readouts: [], haptics: false, open: { _ in }, dismiss: {}) },
                record: {
                    .init(photo: false, confirm: false, busy: probe.busy, openMode: nil,
                        external: .init(recording: probe.recording, confirmation: nil,
                            request: { probe.requests += 1 }, cancel: {}, confirm: { probe.confirmations += 1 }))
                },
                exposure: nil, level: nil, audio: { nil }, readOnly: { probe.readOnly }, borrowed: { false },
                returnToStage: nil, coverOpen: { false }, note: $probe.note, settings: {}, media: {}),
            assists: .init(scopes: nil, tools: { [] }, rendered: { nil }, fitted: { [] }, signalOptions: .init(),
                usage: $probe.usage, usageSeed: [:], toggle: { _ in }),
            views: .init(), portraitAspect: $probe.portraitAspect,
            picture: { Color.black }, cameraPanel: { _, _ in EmptyView() },
            photoRelease: { _ in EmptyView() }, preview: { _ in EmptyView() }, lookMenu: { EmptyView() })
            .frame(width: 420, height: 900).environment(\.scenePhase, .active)
    }
}

@MainActor
private final class RecordBodyFixture {
    let probe: RecordBodyProbe
    let host: UIHostingController<RecordContractSurface>
    let window: UIWindow
    init(configure: (RecordBodyProbe) -> Void = { _ in }) throws {
        let probe = try RecordBodyProbe()
        configure(probe)
        let host = UIHostingController(rootView: RecordContractSurface(probe: probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 900))
        self.probe = probe; self.host = host; self.window = window
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }
    func close() {
        window.isHidden = true; window.rootViewController = nil
        probe.control.unbind()
        probe.storage.removePersistentDomain(forName: probe.storageName)
    }
    func recordElement() async throws -> NSObject {
        for _ in 0..<200 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            if let element = HostedAccessibility.leaves(in: host.view).first(where: { HostedAccessibility.identifier($0) == "monitor.system.record" }) {
                return element
            }
            await Task.yield()
        }
        return try XCTUnwrap(HostedAccessibility.leaves(in: host.view).first { HostedAccessibility.identifier($0) == "monitor.system.record" },
            "The canonical body's real record element must be mounted")
    }
    func waitForRequests(_ count: Int) async {
        for _ in 0..<200 {
            if probe.requests == count { return }
            await Task.yield()
        }
    }
    func settleActions() async {
        for _ in 0..<50 { await Task.yield() }
    }
}
#endif
