#if os(iOS)
import MonitorPresentation
@testable import MonitorUI
import OpenCineAppKit
import OpenCineApple
import OpenCineCore
import OpenCineHostedAccessibility
import OpenCineMedia
import SwiftUI
import XCTest

@testable import OpenCineCameraControls

/// A2-35: every settings call form reaches one typed configuration, and the one body draws exactly
/// its `tabs(library:)` and `rows(_:library:)`. The published forms, the typed form and the shared
/// scene's form give the same tabs and rows for the same values, and an absent optional domain
/// leaves its rows (and an empty tab) out instead of an empty flag. The apps' hosted tests render
/// the page. SIMULATED stores in a private defaults suite; no camera.
@MainActor
final class MonitorSettingsCompositionTests: XCTestCase {
    private final class SimulatedLooks: MonitorLookProvider {
        var selection: Int { 0 }
        var cube: CubeLUT? { nil }
        var transfer: MonitorTransfer { .rec709 }
        var referenceClipByte: Int { 255 }
        func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
    }
    private typealias Screen = MonitorOperatorSettingsScreen<String, SimulatedLooks>
    private typealias Configuration = MonitorOperatorSettingsConfiguration<SimulatedLooks>

    private var storageName = ""
    private var storage: UserDefaults!
    private var stores: AssistPanelStores!
    private var assist: MonitorAssistState<SimulatedLooks>!
    private var preferences: MonitorOperatorPreferences!
    private var display: MonitorDisplayPreferences!
    private var shell: ShellModel!
    private var session: MonitorOperatorSessionModel<SimulatedLooks>!
    private var flag = false

    override func setUp() async throws {
        storageName = "SIMULATED.settings-composition." + UUID().uuidString
        storage = try XCTUnwrap(UserDefaults(suiteName: storageName))
        stores = AssistPanelStores(storage: storage, namespace: "SIMULATED.settings")
        assist = MonitorAssistState(looks: SimulatedLooks(), storage: storage,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
        preferences = MonitorOperatorPreferences(storage: storage, keys: .init(keepScreenAwake: "awake",
            hdrDisplay: "hdr", recordConfirmation: "confirm", haptics: "haptics", cacheOriginals: "originals"))
        display = MonitorDisplayPreferences(storage: storage, keys: .init(live: "live", clean: "clean"))
        var document: Data?
        shell = ShellModel(cameras: CamerasModel(integrations: [], store: SavedCamerasStore(document: StoredData(
            read: { document }, write: { document = $0 }))))
        session = MonitorOperatorSessionModel(shell: shell, assist: assist, display: display)
    }

    override func tearDown() async throws {
        storage.removePersistentDomain(forName: storageName)
    }

    // MARK: Fixture values every form receives

    private var binding: Binding<Bool> { Binding(get: { self.flag }, set: { self.flag = $0 }) }
    private var link: MonitorSettingsLinkSource {
        .init(transport: "SIMULATED transport", transportHelp: "SIMULATED transport help", phase: "SIMULATED phase",
            phaseHelp: "SIMULATED phase help", network: "SIMULATED network", networkHelp: "SIMULATED network help",
            signalBars: 3, saved: [], savedHelp: "SIMULATED saved help")
    }
    private var support: MonitorSettingsSupportSource {
        .init(report: {}, actions: [MonitorSupportAction(id: "support.diagnostics", title: "Diagnostics",
            actionTitle: "Share", accessibilityLabel: "Share Diagnostics", action: {})])
    }
    private var information: MonitorSettingsAppInformation {
        .init(theme: "SIMULATED theme", protocolName: "SIMULATED protocol", version: "1 (1)",
            themeHelp: "SIMULATED", protocolHelp: "SIMULATED", versionHelp: "SIMULATED")
    }

    private func published(borrowed: Bool, support: MonitorSettingsSupportSource? = nil,
        information: MonitorSettingsAppInformation? = nil, hdr: Bool = true,
        gyro: MonitorSettingsGyroSource? = nil) -> Configuration {
        if !borrowed {
            return .init(safeArea: EdgeInsets(), phase: "SIMULATED phase", isLive: false, sharingSubtitle: "SIMULATED",
                close: {}, disconnect: {}, feedback: {}, link: link, support: support, information: information,
                recordConfirmation: binding, haptics: binding, keepAwake: binding, hdrDisplay: binding,
                cacheOriginals: binding, hapticsHelp: "SIMULATED haptics", keepAwakeHelp: "SIMULATED awake",
                hdrHelp: "SIMULATED hdr", cacheHelp: "SIMULATED cache", clearHelp: "SIMULATED clear",
                exposureHelp: "SIMULATED exposure", availableDisplay: MonitorSettingsDisplaySource.commonSections,
                assist: assist, stores: stores, falseColorLooks: .signal, palette: MonitorDefaultLivePalette.self,
                operatorHaptics: OperatorHaptics(isEnabled: { false }), transfer: .rec709, clipByte: 255,
                lookLabel: "SIMULATED look", gyro: gyro)
        }
        return .init(borrowedSafeArea: EdgeInsets(), phase: "SIMULATED phase", isLive: false,
            sharingSubtitle: "SIMULATED", close: {}, disconnect: {}, feedback: {}, link: link,
            support: support, information: information,
            recordConfirmation: binding, haptics: binding, keepAwake: binding,
            hdrDisplay: hdr ? binding : nil, hapticsHelp: "SIMULATED haptics", keepAwakeHelp: "SIMULATED awake",
            hdrHelp: "SIMULATED hdr", cacheHelp: "SIMULATED cache", clearHelp: "SIMULATED clear",
            exposureHelp: "SIMULATED exposure",
            assist: assist, stores: stores, falseColorLooks: .signal, palette: MonitorDefaultLivePalette.self,
            operatorHaptics: OperatorHaptics(isEnabled: { false }), transfer: .rec709, clipByte: 255,
            lookLabel: "SIMULATED look", gyro: gyro)
    }

    private func typed(support: MonitorSettingsSupportSource?, information: MonitorSettingsAppInformation?,
        input: MonitorSettingsInputSource? = nil, gyro: MonitorSettingsGyroSource? = nil) -> Configuration {
        .init(safeArea: EdgeInsets(), phase: "SIMULATED phase", isLive: false, sharingSubtitle: "SIMULATED",
            close: {}, disconnect: {}, feedback: {}, link: link,
            assist: .init(state: assist, stores: stores, falseColorLooks: .signal, palette: MonitorDefaultLivePalette.self,
                haptics: OperatorHaptics(isEnabled: { false }), transfer: .rec709, clipByte: 255,
                exposureHelp: "SIMULATED exposure", lookLabel: "SIMULATED look"),
            controls: .init(recordConfirmation: binding, haptics: .init(value: binding, help: "SIMULATED haptics"),
                keepAwake: .init(value: binding, help: "SIMULATED awake"), input: input),
            display: .init(hdr: .init(value: binding, help: "SIMULATED hdr")),
            support: support, information: information, gyro: gyro)
    }

    private func signature(_ configuration: Configuration, library: Bool = false) -> [[MonitorSettingsRow]] {
        MonitorSettingsTab.allCases.map { configuration.rows($0, library: library) }
    }

    // MARK: Contracts

    func testEveryPublishedFormGivesTheTypedFormsTabsRowsAndHelp() {
        let typed = typed(support: support, information: information)
        for published in [published(borrowed: false, support: support, information: information),
            published(borrowed: true, support: support, information: information)] {
            XCTAssertEqual(signature(published), signature(typed))
            XCTAssertEqual(published.tabs(library: false), typed.tabs(library: false))
            XCTAssertEqual(published.controls.haptics.help, typed.controls.haptics.help)
            XCTAssertEqual(published.controls.keepAwake.help, typed.controls.keepAwake.help)
            XCTAssertEqual(published.display.hdr?.help, typed.display.hdr?.help)
            XCTAssertEqual(published.display.sections, typed.display.sections)
            XCTAssertEqual(published.assistSource.exposureHelp, typed.assistSource.exposureHelp)
        }
        XCTAssertEqual(typed.rows(.system, library: false), [.support, .information],
            "No legal pages or links: no empty Project & Legal card")
    }

    func testGyroRowsAreOptionalAndKeepLogsReachableInEveryCallForm() {
        let gyro = MonitorSettingsGyroSource(enabled: binding, status: "SIMULATED", available: false,
            openLogs: {}, mountName: "SIMULATED mount", configureMount: {})
        for configuration in [typed(support: nil, information: nil), published(borrowed: true), published(borrowed: false)] {
            XCTAssertNil(configuration.gyro)
            XCTAssertFalse(configuration.rows(.controls, library: false).contains(.gyro))
            XCTAssertFalse(configuration.rows(.storage, library: false).contains(.gyroLogs))
        }
        for configuration in [typed(support: nil, information: nil, gyro: gyro),
            published(borrowed: true, gyro: gyro), published(borrowed: false, gyro: gyro)] {
            XCTAssertEqual(configuration.rows(.controls, library: false).first, .gyro)
            XCTAssertEqual(configuration.rows(.storage, library: false), [.gyroLogs])
            XCTAssertTrue(configuration.tabs(library: false).contains(.storage))
            XCTAssertEqual(configuration.gyro?.available, false,
                "An unavailable phone sensor still allows previously saved logs to open")
        }
    }

    func testGyroCalibrateRowAppearsOnlyWhenProvided() {
        var started = 0
        let without = MonitorSettingsGyroSource(enabled: binding, status: "SIMULATED", openLogs: {})
        let with = MonitorSettingsGyroSource(
            enabled: binding, status: "SIMULATED", openLogs: {}, calibrate: { started += 1 })
        XCTAssertNil(without.calibrate)
        XCTAssertNil(without.mountName, "Presets are gone from the main form")
        XCTAssertNil(without.configureMount)
        XCTAssertNotNil(with.calibrate)
        with.calibrate?()
        XCTAssertEqual(started, 1)
        for source in [without, with] {
            for configuration in [typed(support: nil, information: nil, gyro: source),
                published(borrowed: true, gyro: source), published(borrowed: false, gyro: source)] {
                XCTAssertEqual(configuration.rows(.controls, library: false).first, .gyro)
                XCTAssertEqual(configuration.gyro?.calibrate != nil, source.calibrate != nil)
            }
        }
    }

    /// The card draws the Calibrate phone mount row only when the host provides the action.
    func testGyroCardRendersTheCalibrateRowOnlyWhenProvided() async throws {
        func labels(_ source: MonitorSettingsGyroSource) async -> [String] {
            let controller = UIHostingController(
                rootView: MonitorSettingsGyroCard(gyro: source, feedback: {}).frame(width: 393, height: 600))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            defer { window.isHidden = true; window.rootViewController = nil }
            _ = await HostedAccessibility.awaitRuntime()
            try? await Task.sleep(for: .milliseconds(400))
            controller.view.layoutIfNeeded()
            return HostedAccessibility.leaves(in: controller.view).map { $0.accessibilityLabel ?? "" }
        }
        let without = await labels(MonitorSettingsGyroSource(enabled: binding, status: "SIMULATED", openLogs: {}))
        let with = await labels(MonitorSettingsGyroSource(
            enabled: binding, status: "SIMULATED", openLogs: {}, calibrate: {}))
        XCTAssertFalse(without.isEmpty, "The card renders")
        XCTAssertFalse(without.contains { $0.contains(GyroCopy.settingsCalibrate) })
        XCTAssertTrue(with.contains { $0.contains(GyroCopy.settingsCalibrate) }, "\(with)")
    }

    func testAbsentDomainsLeaveTheirTabsOut() {
        XCTAssertEqual(published(borrowed: true).tabs(library: false), [.link, .assist, .controls, .display],
            "No sharing, cache, account, support or information: no Sharing, Storage or System tab")
        XCTAssertEqual(published(borrowed: true, information: information).tabs(library: false),
            [.link, .assist, .controls, .display, .system])
        XCTAssertEqual(published(borrowed: true, information: information).rows(.system, library: false), [.information])
        XCTAssertEqual(published(borrowed: false).tabs(library: true), [.link, .assist, .controls, .display, .storage],
            "The published originals-caching form keeps Storage over the screen's media library")
    }

    /// A2-32: Input & orientation is a row only when the host declares a capability, and the
    /// remote shutter and auto-rotate are each declared on their own.
    func testTheInputRowFollowsTheDeclaredCapabilities() {
        func rows(_ input: MonitorSettingsInputSource?) -> [MonitorSettingsRow] {
            typed(support: nil, information: nil, input: input).rows(.controls, library: false)
        }
        XCTAssertEqual(rows(nil), [.safety])
        XCTAssertEqual(rows(.init()), [.safety], "An input source with no capability is no row")
        XCTAssertEqual(rows(.init(remoteShutter: .init(enabled: binding, title: "SIMULATED", help: "SIMULATED"))),
            [.safety, .input])
        XCTAssertEqual(rows(.init(autoRotate: .init(enabled: binding, help: "SIMULATED"))), [.safety, .input])
    }

    func testAnAbsentHDRChoiceLeavesItsRowOutInsteadOfAnEmptyHelpFlag() {
        let without = published(borrowed: true, hdr: false)
        XCTAssertNil(without.display.hdr)
        XCTAssertEqual(without.rows(.display, library: false), [.displaySections])
        XCTAssertEqual(published(borrowed: true).rows(.display, library: false), [.hdrPanel, .displaySections])
        XCTAssertEqual(published(borrowed: true).display.hdr?.help, "SIMULATED hdr")
    }

    /// The shared scene's settings are the same typed domains a host composes: connection rows,
    /// the common Controls copy, and Help & Feedback over the shell's report and diagnostics.
    /// A2-78: one Processing card on the Link tab, after the connection and before the saved
    /// setups: the feed upscaler with the shared help, then the host's own processing rows.
    func testProcessingIsOneCardWithTheSharedUpscalerHelpBeforeTheSavedSetups() throws {
        var chosen = MonitorUpscaler.lanczos
        let hostRow = MonitorSettingsSourceProperty(id: "processing.host", title: "SIMULATED host processing",
            help: "SIMULATED", value: .reported("SIMULATED"))
        let processing = MonitorSettingsProcessingSource(
            upscaler: Binding(get: { chosen }, set: { chosen = $0 }), supported: [.off, .lanczos], rows: [hostRow])
        let configured = Configuration(safeArea: EdgeInsets(), phase: "SIMULATED phase", isLive: false,
            close: {}, disconnect: {}, feedback: {},
            link: .init(transport: "SIMULATED", transportHelp: "", phase: "", phaseHelp: "", network: nil,
                networkHelp: "", signalBars: nil, saved: [], savedHelp: "", processing: processing),
            assist: .init(state: assist, switches: [], panels: nil),
            controls: .init(recordConfirmation: binding, haptics: .init(value: binding, help: ""),
                keepAwake: .init(value: binding, help: "")))
        XCTAssertEqual(configured.rows(.link, library: false), [.linkHealth, .connection, .processing, .savedCameras])
        let group = try XCTUnwrap(processing.group)
        XCTAssertEqual(group.title, "Processing")
        XCTAssertEqual(group.properties.map(\.id), ["processing.upscaler", "processing.host"])
        XCTAssertEqual(group.properties.first?.title, "Feed Upscaler")
        XCTAssertEqual(group.properties.first?.help, MonitorSettingsCopy.feedUpscaler)
        guard case .choice(let choice)? = group.properties.first?.value else { return XCTFail("upscaler is a choice") }
        XCTAssertEqual(choice.options, ["Off", "Fast"])
        choice.selection.wrappedValue = "Off"
        XCTAssertEqual(chosen, .off)
        XCTAssertNil(MonitorSettingsProcessingSource(upscaler: .constant(.lanczos), supported: [.lanczos]).group,
            "One upscaler and no host rows leaves the card out")
    }

    func testTheSharedSceneFormBuildsTheTypedDomains() {
        var reported = 0, diagnostics = 0
        let actions = ShellActions(diagnostics: { diagnostics += 1 }, reportProblem: { reported += 1 })
        let screen = Screen(shell: shell, brand: "SIMULATED", actions: actions, preferences: preferences,
            display: display, assist: assist, library: nil, operatorSession: session)
        let scene = screen.sceneConfiguration(safeArea: EdgeInsets())
        XCTAssertEqual(scene.tabs(library: false), [.link, .assist, .controls, .display, .system],
            "No media library and no sharing: no Storage or Sharing tab")
        XCTAssertEqual(scene.rows(.link, library: false), [.linkHealth, .connection])
        XCTAssertEqual(scene.link.transport, "Not connected")
        XCTAssertEqual(scene.link.transportHelp, "How this phone reaches the camera.")
        XCTAssertEqual(scene.rows(.controls, library: false), [.safety])
        XCTAssertEqual(scene.controls.keepAwake.help, MonitorSettingsCopy.keepScreenAwake)
        XCTAssertEqual(scene.rows(.display, library: false), [.hdrPanel, .displaySections])
        XCTAssertEqual(scene.rows(.system, library: false), [.support])
        guard let support = scene.support else { return XCTFail("The scene has Help & Feedback") }
        XCTAssertNil(support.consent, "The scene offers no automatic reports switch")
        support.report()
        XCTAssertEqual(reported, 1)
        let rows = support.configuredSupportActions(reportPreparing: false)
        XCTAssertEqual(rows.map(\.id), ["support.diagnostics"])
        rows.first?.action()
        XCTAssertEqual(diagnostics, 1)
        scene.controls.keepAwake.value.wrappedValue = false
        XCTAssertFalse(preferences.keepScreenAwake, "The scene's Keep screen awake row writes the shared store")
    }
}
#endif
