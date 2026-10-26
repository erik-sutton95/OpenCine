#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineMedia
import SwiftUI

/// Complete common settings flow over explicit stores and optional media capability. Every
/// initializer reaches one typed configuration and one body (A2-35): the shared scene's form
/// builds its configuration from the shell and preference stores on each render.
public struct MonitorOperatorSettingsScreen<Payload: Sendable, Looks: MonitorLookProvider>: View {
    private let shell: ShellModel?
    private let brand: String
    private let coverSafeArea: EdgeInsets?
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    private let actions: ShellActions?
    private let preferences: MonitorOperatorPreferences?
    private let assist: MonitorAssistState<Looks>
    private let library: MonitorMediaLibraryModel<Payload>?
    private let availableAssistTools: Set<MonitorAssistSelection>
    private let assistPanels: AssistPanelStores?
    private let falseColorLooks: FalseColorLooks
    @State private var operatorSession: MonitorOperatorSessionModel<Looks>
    private let configuration: MonitorOperatorSettingsConfiguration<Looks>?
    private let borrowedSelection: Binding<MonitorSettingsTab>?
    private let sourceIdentity: UUID?
    @Environment(\.openURL) private var openURL
    @State private var document: MonitorSettingsDocument?
    @State private var legalPage: MonitorLegalPage?
    @State private var showLook = false
    @State private var showJoinCode = false
    @State private var showDiagnostics = false
    @State private var supportError = false
    private struct ReportShare: Identifiable { let id = UUID(); let url: URL }
    @State private var reportShare: ReportShare?
    @State private var preferenceRevision = 0

    /// The shared scene's form: settings over the shell, the common preference stores and the
    /// media library. A passed `configuration` is used as given.
    public init(shell: ShellModel, brand: String, actions: ShellActions? = nil,
        preferences: MonitorOperatorPreferences, display: MonitorDisplayPreferences,
        assist: MonitorAssistState<Looks>, library: MonitorMediaLibraryModel<Payload>?,
        availableAssistTools: Set<MonitorAssistSelection> = [.lut, .peaking, .falseColor, .zebra, .guides, .grid, .crosshair, .desqueeze, .mirror],
        operatorSession: MonitorOperatorSessionModel<Looks>? = nil,
        assistPanels: AssistPanelStores? = nil, falseColorLooks: FalseColorLooks = .signal,
        configuration: MonitorOperatorSettingsConfiguration<Looks>? = nil, safeArea: EdgeInsets? = nil) {
        self.shell = shell; self.brand = brand; self.actions = actions
        self.preferences = preferences; self.assist = assist; self.library = library
        self.availableAssistTools = availableAssistTools
        self.configuration = configuration; self.coverSafeArea = safeArea
        self.borrowedSelection = nil; self.sourceIdentity = nil
        self.assistPanels = assistPanels; self.falseColorLooks = falseColorLooks
        _operatorSession = State(initialValue: operatorSession ?? MonitorOperatorSessionModel(shell: shell, assist: assist, display: display))
    }

    /// Complete configured flow over a source's page state and the one display owner, which also
    /// keeps each tab's scroll offset.
    public init(brand: String, configuration: MonitorOperatorSettingsConfiguration<Looks>,
        library: MonitorMediaLibraryModel<Payload>?, selectedTab: Binding<MonitorSettingsTab>,
        operatorSession: MonitorOperatorSessionModel<Looks>,
        sourceIdentity: UUID?, safeArea: EdgeInsets? = nil) {
        self.shell = nil; self.brand = brand; self.actions = nil
        self.preferences = nil; self.assist = configuration.assist; self.library = library
        self.availableAssistTools = []; self.assistPanels = nil; self.falseColorLooks = .signal
        self.configuration = configuration; self.coverSafeArea = safeArea
        self.borrowedSelection = selectedTab; self.sourceIdentity = sourceIdentity
        _operatorSession = State(initialValue: operatorSession)
    }

    private var selectedTab: Binding<MonitorSettingsTab> {
        if let borrowedSelection { return borrowedSelection }
        return Binding(get: { operatorSession.settingsTab }, set: { operatorSession.settingsTab = $0 })
    }

    /// Every form restores each tab's scroll from the one display owner (A2-84).
    private var scrollOffsets: Binding<[MonitorSettingsTab: CGFloat]> {
        let session = operatorSession
        return Binding(get: { session.settingsScrollOffsets.mapValues { CGFloat($0) } },
            set: { session.settingsScrollOffsets = $0.mapValues { Double($0) } })
    }

    public var body: some View {
        let _ = preferenceRevision
        Group {
            if let configuration { page(configuration, safeArea: coverSafeArea ?? configuration.safeArea) }
            else {
                GeometryReader { proxy in
                    let safeArea = coverSafeArea ?? OperatorPanelMetrics.resolvedDeviceSafeArea(
                        proxy.safeAreaInsets, window: windowGeometry.safeArea)
                    page(sceneConfiguration(safeArea: safeArea), safeArea: safeArea)
                }
            }
        }.ignoresSafeArea().preferredColorScheme(.dark)
        .onChange(of: sourceIdentity ?? shell?.monitor?.id) { _, _ in retireSheets() }
        .onDisappear { retireSheets() }
    }

    /// The shared scene's settings: the same typed domains a host composes, from the shell and
    /// the common stores (Kotlin `MonitorOperatorSettingsScreen(shell, ...)`).
    func sceneConfiguration(safeArea: EdgeInsets) -> MonitorOperatorSettingsConfiguration<Looks> {
        let live = shell?.monitor != nil
        let phase = shell?.monitor?.camera.saved.displayName ?? "No camera connected"
        let link = MonitorSettingsLinkSource(transport: live ? "Connected" : "Not connected",
            transportHelp: "How this phone reaches the camera.", phase: phase, phaseHelp: "The camera this monitor shows.")
        let tools = MonitorAssistSelection.settingsCases.filter { availableAssistTools.contains($0) }
        let assistSource = MonitorSettingsAssistSource(state: assist, switches: tools, panels: scenePanels)
        let controls = MonitorSettingsControlsSource(recordConfirmation: preference(\.recordConfirmation),
            haptics: MonitorSettingsToggle(value: preference(\.haptics), help: MonitorSettingsCopy.haptics),
            keepAwake: MonitorSettingsToggle(value: preference(\.keepScreenAwake), help: MonitorSettingsCopy.keepScreenAwake))
        let display = MonitorSettingsDisplaySource(
            hdr: MonitorSettingsToggle(value: preference(\.hdrDisplay), help: MonitorSettingsCopy.hdrDisplay))
        var cache: MonitorSettingsCachePresentation?
        if let library { cache = .library(library, cacheOriginals: preference(\.cacheOriginals)) }
        var support: MonitorSettingsSupportSource?
        if let actions {
            support = MonitorSettingsSupportSource(report: actions.reportProblem, actions: [MonitorSupportAction(
                id: "support.diagnostics", title: "Diagnostics", actionTitle: "Share",
                accessibilityLabel: "Share Diagnostics", action: actions.diagnostics)])
        }
        let shell = self.shell
        return MonitorOperatorSettingsConfiguration(safeArea: safeArea, phase: phase, isLive: live,
            close: { shell?.dismissCover() }, disconnect: { shell?.close() }, feedback: {}, link: link,
            assist: assistSource, controls: controls, display: display, cache: cache, support: support)
    }

    /// The scene's option panels, when it has panel stores.
    private var scenePanels: (@MainActor () -> AnyView)? {
        guard let stores = assistPanels else { return nil }
        let assist = assist, looks = falseColorLooks, available = availableAssistTools
        let haptics = OperatorHaptics(isEnabled: { [preferences] in preferences?.haptics == true })
        return {
            AnyView(MonitorOperatorAssistSettings(assist: assist, stores: stores, looks: looks,
                palette: MonitorDefaultLivePalette.self, haptics: haptics,
                transfer: assist.looks.transfer, clipByte: assist.looks.referenceClipByte, available: available))
        }
    }

    private func page(_ source: MonitorOperatorSettingsConfiguration<Looks>, safeArea: EdgeInsets) -> some View {
        let hasLibrary = library != nil
        return MonitorSettingsPage(safeArea: safeArea, brand: brand, selection: selectedTab,
            tabs: source.tabs(library: hasLibrary), isLive: source.isLive, phaseLabel: source.phase,
            sharingSubtitle: source.sharingSubtitle, scrollOffsets: scrollOffsets, feedback: source.feedback,
            onClose: source.close, disconnect: source.disconnect) { tab in
            ForEach(source.rows(tab, library: hasLibrary), id: \.self) { row($0, source) }
        }
        .modifier(MonitorSettingsSupportPresentation(source: source.support))
        .overlay {
            if let document, let support = source.support {
                support.document?(document, { self.document = nil })
            } else if let legalPage, let legal = source.support?.legal {
                MonitorLegalDocumentScreen(documents: legal, page: legalPage, onClose: { self.legalPage = nil })
            }
        }
        .sheet(isPresented: $showLook) { source.assistSource.lookCatalog?() }
        .sheet(isPresented: $showJoinCode) { source.sharing?.joinCode?() }
        .sheet(item: $reportShare) { payload in source.support?.shareReport(payload.url) }
        .alert("Report unavailable", isPresented: $supportError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let support = source.support { Text(support.reportUnavailableMessage) }
        }
    }
    private func retireSheets() {
        document = nil; legalPage = nil; showLook = false; showJoinCode = false
        reportShare = nil; supportError = false
    }

    /// The one renderer: each row kind draws from its own domain value.
    @ViewBuilder private func row(_ row: MonitorSettingsRow, _ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        switch row {
        case .linkHealth, .connection, .processing, .savedCameras, .sourceGroups: linkRow(row, source)
        case .sharingUnavailable, .sharing, .watchers, .watchFeed:
            if let sharing = source.sharing { sharingRow(row, sharing, feedback: source.feedback) }
        case .assistTools, .assistPanels, .exposureMeter, .look: assistRow(row, source)
        case .gyro, .safety, .input, .gimbal, .joystick, .controller: controlsRow(row, source)
        case .hdrPanel, .displaySections, .gyroLogs, .account, .cache: displayStorageRow(row, source)
        case .support, .diagnosticOptions, .projectLegal, .information: systemRow(row, source)
        }
    }

    @ViewBuilder private func linkRow(_ row: MonitorSettingsRow, _ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        let link = source.link
        switch row {
        case .linkHealth:
            if let score = link.healthScore, let caption = link.healthCaption {
                MonitorLinkHealthScale(title: "Link Health", caption: caption, score: score)
            } else { MonitorSettingsLinkHealthCard(isLive: source.isLive, signalBars: link.signalBars).monitorFullWidthCard() }
        case .connection:
            MonitorConnectionSettings(transport: link.transport, transportHelp: link.transportHelp,
                phase: link.phase, phaseHelp: link.phaseHelp, network: link.network, networkHelp: link.networkHelp)
        case .processing:
            if let group = link.processing?.group { MonitorSettingsSourceGroups(groups: [group]) }
        case .savedCameras:
            if let saved = link.saved { MonitorSavedCameraSettings(cameras: saved, emptyHelp: link.savedHelp) }
        default: MonitorSettingsSourceGroups(groups: link.sourceGroups)
        }
    }

    @ViewBuilder private func assistRow(_ row: MonitorSettingsRow, _ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        let assistSource = source.assistSource
        switch row {
        case .assistTools:
            MonitorSettingsRowCard(title: "View Assist") {
                ForEach(assistSource.switches, id: \.self) { tool in
                    MonitorSettingsSwitchInlineRow(title: tool.title,
                        help: "Apply this monitor tool to the displayed picture.", isOn: assist.isOn(tool),
                        identifier: "monitor.assist.\(tool.rawValue)") { assist.toggle(tool) }
                }
            }
        case .assistPanels: assistSource.panels?()
        case .exposureMeter:
            MonitorExposureMeterSettings(isOn: assist.evMeter, help: assistSource.exposureHelp ?? "",
                feedback: source.feedback, onToggle: { assist.toggle(.evMeter) })
        default:
            MonitorLookSettings(look: assistSource.lookLabel,
                help: "Looks apply on this phone. The file on the camera is unchanged.", onOpen: { showLook = true })
        }
    }

    @ViewBuilder private func controlsRow(_ row: MonitorSettingsRow, _ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        let controls = source.controls
        switch row {
        case .gyro:
            if let gyro = source.gyro { MonitorSettingsGyroCard(gyro: gyro, feedback: source.feedback) }
        case .safety:
            MonitorOperatorSafetySettings(recordConfirmation: controls.recordConfirmation, haptics: controls.haptics.value,
                keepScreenAwake: controls.keepAwake.value, hapticsHelp: controls.haptics.help,
                keepScreenAwakeHelp: controls.keepAwake.help, feedback: source.feedback)
        case .input:
            if let input = controls.input {
                MonitorInputOrientationSettings(remoteShutter: input.remoteShutter?.enabled,
                    remoteTitle: input.remoteShutter?.title ?? "Remote shutter", remoteHelp: input.remoteShutter?.help,
                    autoRotateFeed: input.autoRotate?.enabled, rotationHelp: input.autoRotate?.help ?? "",
                    feedback: source.feedback)
            }
        case .gimbal:
            if let motion = controls.motion, let sensitivity = motion.sensitivity {
                MonitorGimbalSettings(sensitivity: sensitivity, headTracking: motion.headTracking)
            }
        case .joystick:
            if let joystick = controls.motion?.joystick {
                MonitorJoystickSettings(size: joystick.size, invertPan: joystick.invertPan, invertTilt: joystick.invertTilt,
                    deadZone: joystick.deadZone, response: joystick.response, identifierPrefix: joystick.identifier)
            }
        default:
            if let motion = controls.motion, let controller = motion.controller {
                MonitorControllerSettings(stick: controller, status: motion.controllerStatus, statusHelp: motion.controllerHelp)
            }
        }
    }

    @ViewBuilder private func displayStorageRow(_ row: MonitorSettingsRow,
        _ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        switch row {
        case .hdrPanel:
            if let hdr = source.display.hdr {
                MonitorPanelSettings(hdrDisplay: hdr.value, help: hdr.help, feedback: source.feedback)
            }
        case .displaySections:
            MonitorOperatorDisplaySections(modes: operatorSession.modes, chrome: displayValue, assist: assist,
                available: source.display.sections, edit: editChrome(source), feedback: source.feedback)
                .onAppear { operatorSession.returnedMode = nil }
        case .gyroLogs:
            if let gyro = source.gyro {
                MonitorSettingsRowCard(title: "Gyro logs") {
                    MonitorSettingsInlineRow(title: "Saved motion logs",
                        help: gyro.configureMount == nil
                            ? "Share a log with the matching camera video, then select its lens and mount orientation in Gyroflow."
                            : "Share a log with the matching camera video, then select its lens in Gyroflow. A configured phone mount is included in each new log.",
                        showTopDivider: false) {
                        MonitorSettingsActionPill(title: "Open", action: gyro.openLogs)
                    }
                }
            }
        case .account:
            if let account = source.account { MonitorSettingsConfiguredAccount(source: account) }
        default:
            if let cache = source.cache ?? libraryCache(source) {
                MonitorSettingsCapturedCache(source: cache.source, cacheOriginals: cache.cacheOriginals?.value,
                    cacheHelp: cache.cacheOriginals?.help ?? "", clearHelp: cache.clearHelp, feedback: source.feedback,
                    scopeHelp: cache.scopeHelp, confirmationMessage: cache.confirmationMessage)
            }
        }
    }

    @ViewBuilder private func systemRow(_ row: MonitorSettingsRow, _ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        switch row {
        case .support:
            if let support = source.support {
                MonitorSettingsSupportRows(source: support, consent: support.consent.map(observedBinding),
                    report: support.report, openLegal: { legalPage = $0 }, openDocument: { document = $0 })
            }
        case .diagnosticOptions:
            if let support = source.support {
                MonitorDiagnosticSettings(expanded: $showDiagnostics, deleteHelp: support.deleteHelp,
                    save: {
                        if let url = support.saveReport?() { reportShare = ReportShare(url: url) }
                        else { supportError = true }
                    }, delete: { support.deleteReports?() })
            }
        case .projectLegal:
            if let support = source.support {
                MonitorSettingsProjectLegalRows(source: support, openLegal: { legalPage = $0 },
                    openDocument: { document = $0 }, openURL: { openURL($0) })
            }
        default:
            if let information = source.information {
                MonitorAppInformationSettings(theme: information.theme, protocolName: information.protocolName,
                    version: information.version, themeHelp: information.themeHelp,
                    protocolHelp: information.protocolHelp, versionHelp: information.versionHelp)
            }
        }
    }

    private func editChrome(_ source: MonitorOperatorSettingsConfiguration<Looks>) -> ((MonitorDisplayMode) -> Void)? {
        guard source.isLive else { return nil }
        return operatorSession.beginEditing
    }

    /// Published form only: originals caching over this screen's media library.
    private func libraryCache(_ source: MonitorOperatorSettingsConfiguration<Looks>) -> MonitorSettingsCachePresentation? {
        guard let library, let originals = source.libraryCacheOriginals else { return nil }
        return .library(library, cacheOriginals: originals)
    }

    @ViewBuilder private func sharingRow(_ row: MonitorSettingsRow, _ source: MonitorSettingsSharingSource,
        feedback: @escaping () -> Void) -> some View {
        switch row {
        case .sharingUnavailable:
            MonitorSettingsRowCard {
                MonitorSettingsInlineRow(title: source.unavailableTitle, help: source.unavailableHelp,
                    showTopDivider: false) { if let value = source.unavailableValue { MonitorSettingsValueText(value: value) } }
            }
        case .sharing:
            let priorities = source.priorities ?? ["Quality", "High", "Medium", "Steady"]
            let priority = source.prioritySelection ?? Binding(get: {
                priorities[min(max(0, source.priority?.wrappedValue ?? 0), priorities.count - 1)]
            }, set: {
                if let index = priorities.firstIndex(of: $0) { source.priority?.wrappedValue = index }
            })
            MonitorFeedSharingSettings(sharing: source.sharing, passcode: source.passcode,
                controlRequests: source.controlRequests, priority: priority, priorities: priorities, help: source.help,
                showWiFiCode: source.joinCode == nil ? nil : { showJoinCode = true },
                passcodeChanged: source.passcodeChanged, feedback: feedback)
        case .watchers:
            if let watchers = source.watchers { watcherRows(watchers) }
        default:
            MonitorSettingsRowCard {
                MonitorSettingsInlineRow(title: "Watch a feed", help: source.browseHelp, showTopDivider: false) {
                    MonitorSettingsActionPill(title: "Browse", action: source.browse)
                }
            }
        }
    }
    private func watcherRows(_ source: MonitorSettingsWatchersSource) -> some View {
        MonitorSettingsRowCard(title: "Watchers") {
            MonitorSettingsInlineRow(title: "Watching", help: source.watchingHelp, showTopDivider: false) {
                MonitorSettingsValueText(value: source.watching)
            }
            if let request = source.request {
                MonitorSettingsInlineRow(title: "Control Requested", help: request.help) {
                    HStack(spacing: 8) {
                        MonitorSettingsActionPill(title: "Decline", action: request.decline)
                        MonitorSettingsActionPill(title: "Grant to \(request.name)", action: request.grant)
                    }
                }
            }
            if let holder = source.holder {
                MonitorSettingsInlineRow(title: "Camera Control", help: holder.help) {
                    HStack(spacing: 8) {
                        MonitorSettingsValueText(value: holder.name)
                        MonitorSettingsActionPill(title: "Take back", action: holder.reclaim)
                    }
                }
            }
        }
    }

    private func observedBinding(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; preferenceRevision += 1 })
    }

    private func preference(_ field: ReferenceWritableKeyPath<MonitorOperatorPreferences, Bool>) -> Binding<Bool> {
        guard let preferences else { preconditionFailure("The shared scene's settings read the common preference store") }
        return Binding(get: { preferences[keyPath: field] }, set: {
            preferences[keyPath: field] = $0; preferenceRevision += 1
        })
    }
    private func displayValue(_ mode: MonitorDisplayMode) -> Binding<MonitorDisplayChrome> {
        Binding(get: { operatorSession.chrome(for: mode) }, set: {
            switch mode {
            case .live: operatorSession.live = $0
            case .clean: operatorSession.clean = $0
            case .command: operatorSession.command = $0
            }
            preferenceRevision += 1
        })
    }
}

/// Help & Feedback for every support form, in one row order (A2-25).
private struct MonitorSettingsSupportRows: View {
    let source: MonitorSettingsSupportSource
    let consent: Binding<Bool>?
    let report: () -> Void
    let openLegal: (MonitorLegalPage) -> Void
    let openDocument: (MonitorSettingsDocument) -> Void
    var body: some View {
        MonitorSupportSettings(automaticReports: consent, available: source.available,
            automaticHelp: source.automaticHelp, unavailableHelp: source.unavailableHelp,
            reportTitle: source.reportTitle, reportActionTitle: source.reportActionTitle,
            actions: source.configuredSupportActions(reportPreparing: source.model?.preparingReport == true),
            report: report, privacy: privacy)
    }
    /// Reporting Privacy: the closure form's document page, else a local or browser privacy page.
    private var privacy: (() -> Void)? {
        if source.document != nil { return { openDocument(.privacy) } }
        if source.showsLocally(.privacy) { return { openLegal(.privacy) } }
        guard let destination = source.privacyDestination else { return nil }
        return { source.model?.request(destination) }
    }
}

/// Project & Legal: bundled pages open in the shared legal screen, web pages keep the host's
/// browser destination, and the closure form keeps its document pages and plain links.
private struct MonitorSettingsProjectLegalRows: View {
    let source: MonitorSettingsSupportSource
    let openLegal: (MonitorLegalPage) -> Void
    let openDocument: (MonitorSettingsDocument) -> Void
    let openURL: (URL) -> Void
    var body: some View {
        if source.document != nil {
            MonitorProjectLegalSettings(sourceHelp: source.sourceHelp, termsHelp: source.termsHelp,
                source: { if let url = source.sourceURL { openURL(url) } }, privacy: { openDocument(.privacy) },
                terms: { if let url = source.termsURL { openURL(url) } },
                licenses: { openDocument(.licenses) }, notice: { openDocument(.notice) })
        } else {
            MonitorProjectLegalSettings(sourceHelp: source.sourceHelp, termsHelp: source.termsHelp,
                source: { request(source.sourceDestination) }, privacy: { open(.privacy, else: source.privacyDestination) },
                terms: { open(.terms, else: source.termsDestination) },
                licenses: source.legal == nil ? nil : { openLegal(.licenses) },
                notice: source.legal == nil ? nil : { openLegal(.notice) })
        }
    }
    private func request(_ destination: MonitorSettingsBrowserDestination?) {
        if let destination { source.model?.request(destination) }
    }
    private func open(_ page: MonitorLegalPage, else destination: MonitorSettingsBrowserDestination?) {
        if source.showsLocally(page) { openLegal(page) } else { request(destination) }
    }
}

/// Gates bindings, never the content: the page keeps one identity whichever support source
/// (closure, model or none) the host supplies, so tab scroll, sheets and cache state survive.
struct MonitorSettingsSupportPresentation: ViewModifier {
    let source: MonitorSettingsSupportSource?
    private struct ReportFile: Identifiable { var id: URL { url }; let url: URL }
    func body(content: Content) -> some View {
        let model = source?.model
        content
            .onAppear { bind() }
            .onChange(of: source?.actions?.identity) { _, _ in bind() }
            .onChange(of: source?.actions?.requiresInternetConsent) { _, _ in bind() }
            .sheet(item: Binding(get: { model?.reportURL.map { ReportFile(url: $0) } },
                set: { if $0 == nil { model?.dismissReport() } })) { file in source?.shareReport(file.url) }
            .alert("Leave camera Wi-Fi?", isPresented: Binding(
                get: { model?.destination != nil }, set: { if !$0 { model?.cancelConfirmation() } })) {
                Button("Cancel", role: .cancel) { model?.cancelConfirmation() }
                Button("Continue") { model?.confirmBrowser() }
            } message: { if let destination = model?.destination { Text(destination.confirmationMessage) } }
            .alert(model?.reportFailed == true ? "Couldn’t Share Diagnostics" : "Couldn’t Reach the Internet",
                isPresented: Binding(get: { model?.reportFailed == true || model?.browserFailed == true },
                    set: { if !$0 { model?.dismissError() } })) {
                Button("OK", role: .cancel) { model?.dismissError() }
            } message: {
                if let reason = model?.reportFailure ?? model?.browserFailure { Text(reason) }
            }
    }
    private func bind() { if let actions = source?.actions { source?.model?.bind(actions) } }
}


private struct MonitorSettingsConfiguredAccount: View {
    let source: MonitorSettingsAccountSource
    var body: some View {
        let _ = source.model?.accountRevision
        MonitorAccountSettings(title: source.title, help: source.help,
            state: source.model?.busy == true ? .connecting : source.readState?() ?? source.state,
            signIn: source.signIn, signOut: source.signOut, statusLabel: source.status,
            signInTitle: source.signInTitle, signOutTitle: source.signOutTitle,
            busyLabel: source.model?.busy == true ? source.busyTitle : nil, errorMessage: source.model?.failure)
        .onAppear { bind() }
        .onChange(of: source.actions?.identity) { _, _ in bind() }
        .onChange(of: source.actions?.requiresInternetConsent) { _, _ in bind() }
        .alert(source.consentTitle, isPresented: Binding(
            get: { source.model?.confirmationPresented == true },
            set: { if !$0 { source.model?.cancelConfirmation() } })) {
            Button("Cancel", role: .cancel) { source.model?.cancelConfirmation() }
            Button(source.consentAction) { source.model?.confirmSignIn() }
        } message: { Text(source.consentMessage) }
    }
    private func bind() {
        if let actions = source.actions { source.model?.bind(actions) }
    }
}

/// Shared link caption policy receives optional delivery facts, never an SDK session.
public struct MonitorSettingsLinkHealthCard: View {
    private let isLive: Bool
    private let bars: Int?
    public init(isLive: Bool, signalBars: Int?) { self.isLive = isLive; bars = signalBars }
    private var caption: String {
        guard isLive else { return "No live path." }
        guard let bars, bars > 0 else { return "Waiting for the link." }
        switch MonitorLinkHealthBand(bars: bars) {
        case .stable: return "Link is clean. · Stable"
        case .watch: return "Some loss on the link. · Watch"
        case .poor: return "Link is weak. · Poor"
        }
    }
    public var body: some View {
        MonitorLinkHealthScale(title: "Link Health", caption: caption, score: min(4, max(0, bars ?? 0)) * 25)
    }
}

struct MonitorSettingsCapturedCache: View {
    let source: MonitorSettingsCacheSource
    let cacheOriginals: Binding<Bool>?
    let cacheHelp: String, clearHelp: String
    let feedback: () -> Void
    var scopeHelp: String? = nil
    var confirmationMessage: String? = nil
    @State private var model = MonitorSettingsCacheModel()
    private struct Request: Equatable { let identity: MonitorSettingsCacheIdentity; let revision: UInt64 }
    private var request: Request { .init(identity: source.identity, revision: source.revision) }
    private var confirm: Binding<Bool> {
        Binding(get: { model.confirmationPresented }, set: { if !$0 { model.cancelConfirmation() } })
    }
    var body: some View {
        MonitorCacheSettings(cacheOriginals: cacheOriginals, sizeLabel: sizeLabel, clearing: model.clearing,
            cacheHelp: cacheHelp, scopeHelp: scopeHelp ?? Self.scopeHelpText,
            clearHelp: clearHelp, feedback: feedback, clear: model.requestClear, clearSummary: model.clearSummary)
        .confirmationDialog("Clear cache?", isPresented: confirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive, action: model.clear)
            Button("Cancel", role: .cancel, action: model.cancelConfirmation)
        } message: { Text(confirmationMessage ?? Self.confirmationText) }
        .disabled(model.clearing)
        .alert(model.readFailed ? "Could not read the cache." : "Could not clear the cache. Try again.",
            isPresented: Binding(get: { model.clearFailed || model.readFailed }, set: { if !$0 { model.dismissError() } })) {
            Button("OK", role: .cancel, action: model.dismissError)
        } message: { if let reason = model.failure { Text(reason) } }
        .task(id: request) { model.refresh(source) }
        .onDisappear { model.retire() }
    }
    /// One cache scope and Clear wording every app shares (A2-33): the scope is every camera's
    /// cache on this phone, and Clear removes the camera indexes too, so a formatted card cannot
    /// leave thumbnail-less rows behind. A host with a different scope states its own two texts.
    static let scopeHelpText =
        "Clips and thumbnails cached from the camera for offline playback and sharing, across all paired cameras."
    static let confirmationText =
        "Removes cached clip files, thumbnails, and camera indexes for every camera. The on-device library is left intact."
    private var sizeLabel: String {
        guard let bytes = model.bytes else { return model.readFailed ? "Unavailable" : "Checking…" }
        return bytes == 0 ? "Empty" : MediaClipFormatting.byteLabel(bytes)
    }
}

/// Cache confirmation, progress and stale completion belong to one shared settings lifetime.
public struct MonitorOperatorCacheSettings<Payload: Sendable>: View {
    private let library: MonitorMediaLibraryModel<Payload>
    private let cacheOriginals: Binding<Bool>
    public init(library: MonitorMediaLibraryModel<Payload>, cacheOriginals: Binding<Bool>) {
        self.library = library; self.cacheOriginals = cacheOriginals
    }

    public var body: some View {
        let cache = MonitorSettingsCachePresentation.library(library, cacheOriginals: cacheOriginals)
        MonitorSettingsCapturedCache(source: cache.source, cacheOriginals: cache.cacheOriginals?.value,
            cacheHelp: cache.cacheOriginals?.help ?? "", clearHelp: cache.clearHelp, feedback: {},
            scopeHelp: cache.scopeHelp, confirmationMessage: cache.confirmationMessage)
    }
}

extension MonitorSettingsCachePresentation {
    /// Originals and playback proxies a media library downloaded from the camera.
    @MainActor static func library<Payload: Sendable>(_ library: MonitorMediaLibraryModel<Payload>,
        cacheOriginals: Binding<Bool>) -> Self {
        let token = library.actionToken
        let revision = library.cacheRevision
        let files = Set(library.entries.values.flatMap { [$0.originalURL, $0.proxyURL, $0.thumbnailURL].compactMap { $0 } })
        return .init(source: MonitorSettingsCacheSource(
                identity: .init(namespace: library.cache.directory.root.path, source: token.lifetime), revision: revision,
                isCurrent: { library.isCurrent(token) && library.cacheRevision == revision },
                count: {
                    await Task.detached {
                        files.reduce(UInt64(0)) { total, file in
                            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber
                            return total + (size?.uint64Value ?? 0)
                        }
                    }.value
                }, clear: { try await library.clearCache() }),
            cacheOriginals: .init(value: cacheOriginals, help: "Keep originals downloaded for playback."),
            clearHelp: "Remove downloaded picture files while keeping the clip list.",
            scopeHelp: "Originals and playback proxies downloaded from the camera.",
            confirmationMessage: "Removes downloaded picture files while keeping the clip list.")
    }
}
/// The Gyro logging card: the switch, the status, the calibrate row and the legacy mount row.
struct MonitorSettingsGyroCard: View {
    let gyro: MonitorSettingsGyroSource
    let feedback: () -> Void

    var body: some View {
        MonitorSettingsRowCard(title: "Gyro logging") {
            MonitorSettingsSwitchInlineRow(title: "Log gyro with camera recordings",
                help: "Mount this phone firmly to the camera. Synchronize exported logs in Gyroflow.",
                showTopDivider: false, isOn: gyro.enabled.wrappedValue,
                feedback: feedback) { gyro.enabled.wrappedValue.toggle() }
                .disabled(!gyro.available)
            MonitorSettingsInlineRow(title: "Status", help: nil) {
                MonitorSettingsValueText(value: gyro.status)
            }
            if let calibrate = gyro.calibrate {
                MonitorSettingsInlineRow(title: GyroCopy.settingsCalibrate, help: nil) {
                    MonitorSettingsActionPill(title: GyroCopy.getStarted, action: calibrate)
                }
            }
            if let configureMount = gyro.configureMount {
                MonitorSettingsInlineRow(title: "Phone mount",
                    help: "Choose the phone's position relative to the camera. Keep the mount unchanged during a take; rotating the whole rig needs no new selection.") {
                    HStack(spacing: 8) {
                        if let name = gyro.mountName { MonitorSettingsValueText(value: name) }
                        MonitorSettingsActionPill(title: "Configure", action: configureMount)
                    }
                }
            }
        }
    }
}
#endif
