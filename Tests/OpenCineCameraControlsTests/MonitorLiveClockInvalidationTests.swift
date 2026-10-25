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

/// SIMULATED source with a camera timecode that advances once per live view frame (Z reads it
/// from every frame header). Lane media-perf 2026-10-25: each frame re-evaluated the whole live
/// surface (palette, controls, readouts, codec labels) because the clock lived in `status`.
@MainActor
final class MonitorLiveClockInvalidationTests: XCTestCase {
    /// The clock is a status value: every tick re-evaluates the surface. This is the shape that
    /// cost 20% of a core at 25 Hz in the Z simulator profile; it stays supported for sources
    /// whose clock changes rarely.
    func testAClockCarriedInStatusReevaluatesTheSurfaceEveryTick() async throws {
        let fixture = try ClockFixture(live: false)
        defer { fixture.close() }
        let delta = try await fixture.tick(20)
        XCTAssertGreaterThanOrEqual(delta, 20, "Every status clock tick re-evaluates the surface")
    }

    /// A live clock re-renders only its own readout: the surface does not evaluate its source
    /// again, and the readout still shows the newest value.
    func testALiveClockAdvancesWithoutReevaluatingTheSurface() async throws {
        let fixture = try ClockFixture(live: true)
        defer { fixture.close() }
        let delta = try await fixture.tick(20)
        XCTAssertLessThanOrEqual(delta, 1, "A live clock tick re-evaluated the surface \(delta) times")
    }
}

@MainActor
@Observable
private final class ClockProbe: ChromeEditHost {
    typealias Palette = MonitorDefaultLivePalette
    typealias ChromeSection = MonitorDisplayChrome.Section
    typealias ChromeMode = MonitorDisplayMode
    let identity: MonitorOperatorLiveIdentity
    /// Unobserved, so a change models a source that moved on before the mounted body re-rendered.
    @ObservationIgnored var currentSource: MonitorOperatorLiveIdentity
    var timecode = "01:00:00:00"
    /// How often the surface evaluated its source status: once per surface body evaluation.
    @ObservationIgnored var statusEvaluations = 0
    var usage = MonitorToolUsage()
    let control = MonitorControlModel()
    let assist: MonitorAssistState<ClockLooks>
    let session: MonitorOperatorSessionModel<ClockLooks>
    var note: String?
    var portraitAspect = PortraitFeedAspect.fit16x9
    let storage: UserDefaults
    let storageName: String

    init() throws {
        let identity = MonitorOperatorLiveIdentity(monitor: UUID(), camera: nil, epoch: nil, picture: "SIMULATED")
        self.identity = identity
        currentSource = identity
        let name = "SIMULATED.live-clock." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        storageName = name; storage = preferences
        assist = MonitorAssistState(looks: ClockLooks(), storage: preferences,
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
    func isChromeVisible(_ section: ChromeSection, in mode: ChromeMode) -> Bool {
        [.statusBar, .timecode].contains(section)
    }
    func toggleChrome(_ section: ChromeSection, for mode: ChromeMode) {}
    func endChromeEditing() {}
}

@MainActor
private final class ClockLooks: MonitorLookProvider {
    var selection: Int { 0 }
    var cube: CubeLUT? { nil }
    var transfer: MonitorTransfer { .rec709 }
    var referenceClipByte: Int { 255 }
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
}

private struct ClockSurface: View {
    @Bindable var probe: ClockProbe
    let live: Bool
    var body: some View {
        let layout = LiveMonitorLayout.fieldMonitor(size: CGSize(width: 900, height: 420), safeArea: EdgeInsets(),
            sourceAspect: 16 / 9, fill: false, showsValues: false, showsBottomBars: false)
        MonitorOperatorLiveSurface(host: probe, control: probe.control, session: probe.session, layout: layout,
            source: MonitorOperatorLiveSource<SettingKey, Never>(
                identity: { probe.identity }, available: { [.statusBar, .timecode] },
                picture: { .init(aspect: 16 / 9, waiting: true, vertical: false, flipped: false, recovering: false) },
                status: {
                    probe.statusEvaluations += 1
                    // A live clock's template has the clock's width and changes with its shape only.
                    return live
                        ? .init(recording: .init(recording: false, timecode: "00:00:00:00"), showsTimecode: true,
                            showsRecording: false, liveClock: { probe.timecode })
                        : .init(recording: .init(recording: false, timecode: probe.timecode), showsTimecode: true,
                            showsRecording: false)
                },
                cameraBattery: { nil },
                capture: { .init(readouts: [], haptics: false, open: { _ in }, dismiss: {}) },
                record: { .init(photo: false, confirm: false, busy: false, openMode: nil, external: nil) },
                exposure: nil, level: nil, audio: { nil }, readOnly: { false }, borrowed: { false },
                returnToStage: nil, coverOpen: { false }, note: $probe.note, settings: {}, media: {}),
            assists: .init(scopes: nil, tools: { [] }, rendered: { nil }, fitted: { [] }, signalOptions: .init(),
                usage: $probe.usage, usageSeed: [:], toggle: { _ in }),
            views: .init(), portraitAspect: $probe.portraitAspect,
            picture: { Color.black }, cameraPanel: { _, _ in EmptyView() },
            photoRelease: { _ in EmptyView() }, preview: { _ in EmptyView() }, lookMenu: { EmptyView() })
            .frame(width: 900, height: 420).environment(\.scenePhase, .active)
    }
}

@MainActor
private final class ClockFixture {
    let probe: ClockProbe
    let host: UIHostingController<ClockSurface>
    let window: UIWindow
    init(live: Bool) throws {
        let probe = try ClockProbe()
        let host = UIHostingController(rootView: ClockSurface(probe: probe, live: live))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 420))
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
    private func settle() async {
        for _ in 0..<20 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            await Task.yield()
        }
    }
    private func shows(_ timecode: String) -> Bool {
        HostedAccessibility.leaves(in: host.view).contains {
            ($0.accessibilityLabel ?? "").contains(timecode)
        }
    }
    /// Advances the clock `count` frames; returns how many surface evaluations they caused.
    func tick(_ count: Int) async throws -> Int {
        await settle()
        XCTAssertTrue(shows(probe.timecode), "The clock must be mounted before it ticks")
        let before = probe.statusEvaluations
        for frame in 1...count {
            probe.timecode = String(format: "01:00:00:%02d", frame)
            await settle()
        }
        XCTAssertTrue(shows(probe.timecode), "The readout must show the newest frame \(probe.timecode)")
        return probe.statusEvaluations - before
    }
}
#endif
