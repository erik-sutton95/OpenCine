#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI

/// Complete common settings flow over explicit stores and optional media capability.
public struct MonitorOperatorSettingsScreen<Payload: Sendable, Looks: MonitorLookProvider>: View {
    private let shell: ShellModel?
    private let brand: String
    private let coverSafeArea: EdgeInsets?
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    private let actions: ShellActions?
    private let preferences: MonitorOperatorPreferences?
    private let display: MonitorDisplayPreferences?
    private let assist: MonitorAssistState<Looks>
    private let library: MonitorMediaLibraryModel<Payload>?
    private let availableAssistTools: Set<MonitorAssistSelection>
    private let assistPanels: AssistPanelStores?
    private let falseColorLooks: FalseColorLooks
    @State private var operatorSession: MonitorOperatorSessionModel<Looks>?
    private let configuration: MonitorOperatorSettingsConfiguration<Looks>?
    private let borrowedDisplay: MonitorOperatorBorrowedDisplay?
    private let borrowedSelection: Binding<MonitorSettingsTab>?
    private let borrowedScrollOffsets: Binding<[String: CGFloat]>?
    private let sourceIdentity: UUID?
    @Environment(\.openURL) private var openURL
    @State private var document: MonitorSettingsDocument?
    @State private var showLook = false
    @State private var showJoinCode = false
    @State private var showReport = false
    @State private var showDiagnostics = false
    @State private var supportError = false
    private struct ReportShare: Identifiable { let id = UUID(); let url: URL }
    @State private var reportShare: ReportShare?
    @State private var preferenceRevision = 0

    public init(shell: ShellModel, brand: String, actions: ShellActions? = nil,
        preferences: MonitorOperatorPreferences, display: MonitorDisplayPreferences,
        assist: MonitorAssistState<Looks>, library: MonitorMediaLibraryModel<Payload>?,
        availableAssistTools: Set<MonitorAssistSelection> = [.lut, .peaking, .falseColor, .zebra, .guides, .grid, .crosshair, .desqueeze, .mirror],
        operatorSession: MonitorOperatorSessionModel<Looks>? = nil,
        assistPanels: AssistPanelStores? = nil, falseColorLooks: FalseColorLooks = .signal,
        configuration: MonitorOperatorSettingsConfiguration<Looks>? = nil, safeArea: EdgeInsets? = nil) {
        self.shell = shell; self.brand = brand; self.actions = actions
        self.preferences = preferences; self.display = display; self.assist = assist; self.library = library
        self.availableAssistTools = availableAssistTools
        self.configuration = configuration; self.coverSafeArea = safeArea
        self.borrowedDisplay = nil; self.borrowedSelection = nil; self.borrowedScrollOffsets = nil; self.sourceIdentity = nil
        self.assistPanels = assistPanels; self.falseColorLooks = falseColorLooks
        _operatorSession = State(initialValue: operatorSession ?? MonitorOperatorSessionModel(shell: shell, assist: assist, display: display))
    }

    /// Complete configured flow over a source's existing display storage and page state.
    public init(brand: String, configuration: MonitorOperatorSettingsConfiguration<Looks>,
        library: MonitorMediaLibraryModel<Payload>?, selectedTab: Binding<MonitorSettingsTab>,
        scrollOffsets: Binding<[String: CGFloat]>, borrowedDisplay: MonitorOperatorBorrowedDisplay,
        sourceIdentity: UUID?, initialReportPresented: Bool = false, safeArea: EdgeInsets? = nil) {
        self.shell = nil; self.brand = brand; self.actions = nil
        self.preferences = nil; self.display = nil; self.assist = configuration.assist; self.library = library
        self.availableAssistTools = []; self.assistPanels = nil; self.falseColorLooks = .signal
        self.configuration = configuration; self.coverSafeArea = safeArea; self.borrowedDisplay = borrowedDisplay
        self.borrowedSelection = selectedTab; self.borrowedScrollOffsets = scrollOffsets; self.sourceIdentity = sourceIdentity
        _operatorSession = State(initialValue: nil)
        _showReport = State(initialValue: initialReportPresented)
    }

    private var tabs: [MonitorSettingsTab] {
        if configuration != nil { return MonitorSettingsTab.allCases }
        return [.link, .assist, .controls, .display] + (library == nil ? [] : [.storage]) + [.system]
    }

    private var selectedTab: Binding<MonitorSettingsTab> {
        if let borrowedSelection { return borrowedSelection }
        return Binding(get: { operatorSession?.settingsTab ?? .link }, set: { operatorSession?.settingsTab = $0 })
    }

    public var body: some View {
        let _ = preferenceRevision
        Group {
            if let configuration { configuredPage(configuration) }
            else {
                GeometryReader { proxy in
                    MonitorSettingsPage(safeArea: coverSafeArea ?? OperatorPanelMetrics.resolvedDeviceSafeArea(
                        proxy.safeAreaInsets, window: windowGeometry.safeArea), brand: brand, selection: selectedTab,
                        tabs: tabs, isLive: shell?.monitor != nil,
                        phaseLabel: shell?.monitor?.camera.saved.displayName ?? "No camera connected",
                        onClose: { shell?.dismissCover() }, disconnect: { shell?.close() }, rows: rows)
                }
            }
        }.ignoresSafeArea().preferredColorScheme(.dark)
        .onChange(of: sourceIdentity ?? shell?.monitor?.id) { _, _ in retireSheets() }
        .onDisappear { retireSheets() }
    }

    private func configuredPage(_ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        MonitorSettingsPage(safeArea: coverSafeArea ?? source.safeArea, brand: brand, selection: selectedTab,
            tabs: tabs, isLive: source.isLive, phaseLabel: source.phase,
            sharingSubtitle: source.sharingSubtitle, scrollOffsets: borrowedScrollOffsets, feedback: source.feedback,
            onClose: source.close, disconnect: source.disconnect, rows: rows)
        .modifier(MonitorSettingsSupportPresentation(source: source.support))
        .overlay {
            if let document, let support = source.support {
                support.document?(document, { self.document = nil })
            }
        }
        .sheet(isPresented: $showLook) { source.lookCatalog?() }
        .sheet(isPresented: $showJoinCode) { source.sharing?.joinCode?() }
        .sheet(isPresented: $showReport) { source.support?.report() }
        .sheet(item: $reportShare) { payload in source.support?.shareReport(payload.url) }
        .alert("Report unavailable", isPresented: $supportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Email support@opencapture.org. You can save a report under Diagnostic options.")
        }
    }
    private func retireSheets() {
        document = nil; showLook = false; showJoinCode = false; showReport = false
        reportShare = nil; supportError = false
    }

    @ViewBuilder private func rows(_ tab: MonitorSettingsTab) -> some View {
        switch tab {
        case .link:
            if let configuration { linkRows(configuration.link, isLive: configuration.isLive) }
            else {
                MonitorSettingsRowCard(title: "Connection") {
                    Text(shell?.monitor?.camera.saved.displayName ?? "No camera connected").foregroundStyle(MonitorTheme.text)
                }
            }
        case .assist: assistRows
        case .controls:
            if let configuration { controlsRows(configuration) }
            else {
                MonitorOperatorSafetySettings(recordConfirmation: preference(\.recordConfirmation),
                    haptics: preference(\.haptics), keepScreenAwake: preference(\.keepScreenAwake))
            }
        case .display: displayRows
        case .storage:
            if let configuration { storageRows(configuration) }
            else if let library { MonitorOperatorCacheSettings(library: library, cacheOriginals: preference(\.cacheOriginals)) }
        case .system:
            if let configuration { systemRows(configuration) }
            else {
                MonitorSettingsRowCard(title: "Diagnostics") {
                    if let actions {
                        Button("Diagnostics", action: actions.diagnostics)
                        Button("Report a problem", action: actions.reportProblem)
                    }
                }
            }
        case .sharing:
            if let configuration, let sharing = configuration.sharing { sharingRows(sharing, configuration: configuration) }
        }
    }

    @ViewBuilder private var assistRows: some View {
        if let configuration {
            configuration.assistSettings()
            MonitorExposureMeterSettings(isOn: assist.evMeter, help: configuration.exposureHelp,
                feedback: configuration.feedback, onToggle: { assist.toggle(.evMeter) })
            if configuration.lookCatalog != nil {
                MonitorLookSettings(look: configuration.lookLabel,
                    help: "Looks apply on this phone. The file on the camera is unchanged.", onOpen: { showLook = true })
            }
        } else { defaultAssistRows }
    }

    @ViewBuilder private var defaultAssistRows: some View {
        MonitorSettingsRowCard(title: "View Assist") {
            ForEach(MonitorAssistSelection.settingsCases.filter { availableAssistTools.contains($0) }, id: \.self) { tool in
                MonitorSettingsSwitchInlineRow(title: tool.title,
                    help: "Apply this monitor tool to the displayed picture.", isOn: assist.isOn(tool),
                    identifier: "monitor.assist.\(tool.rawValue)") { assist.toggle(tool) }
            }
        }
        if let stores = assistPanels {
            MonitorOperatorAssistSettings(assist: assist, stores: stores, looks: falseColorLooks,
                palette: MonitorDefaultLivePalette.self, haptics: OperatorHaptics(isEnabled: { preferences?.haptics == true }),
                transfer: assist.looks.transfer, clipByte: assist.looks.referenceClipByte, available: availableAssistTools)
        }
    }

    private var editChrome: ((MonitorDisplayMode) -> Void)? {
        guard configuration?.isLive ?? (shell?.monitor != nil), let operatorSession else { return nil }
        return operatorSession.beginEditing
    }

    @ViewBuilder private var displayRows: some View {
        if let configuration {
            if let hdr = configuration.hdrDisplay {
                MonitorPanelSettings(hdrDisplay: hdr, help: configuration.hdrHelp, feedback: configuration.feedback)
            }
        } else {
            MonitorPanelSettings(hdrDisplay: preference(\.hdrDisplay),
                help: "Show the native monitor in HDR when the display supports it.", feedback: {})
        }
        if let value = borrowedDisplay {
            MonitorDisplaySettings(layoutHelp: value.layoutHelp, choices: value.choices,
                selection: value.selection, expandedSection: value.expandedSection,
                sections: value.sections, order: value.order).onAppear(perform: value.returnedFromEditor)
        } else {
            MonitorOperatorDisplaySections(live: displayValue(.live), clean: displayValue(.clean), assist: assist,
                available: configuration?.availableDisplay ?? [.statusBar, .cameraValues, .lockButton, .recReadout,
                    .timecode, .toolBar, .railRecord, .railMedia, .railSettings], edit: editChrome,
                feedback: configuration?.feedback ?? {})
                .onAppear { operatorSession?.returnedMode = nil }
        }
    }

    @ViewBuilder private func linkRows(_ link: MonitorSettingsLinkSource, isLive: Bool) -> some View {
        if let score = link.healthScore, let caption = link.healthCaption {
            MonitorLinkHealthScale(title: "Link Health", caption: caption, score: score)
        } else { MonitorSettingsLinkHealthCard(isLive: isLive, signalBars: link.signalBars).monitorFullWidthCard() }
        MonitorConnectionSettings(transport: link.transport, transportHelp: link.transportHelp,
            phase: link.phase, phaseHelp: link.phaseHelp, network: link.network, networkHelp: link.networkHelp)
        if let processing = link.processing { MonitorProcessingSettings(choice: processing) }
        MonitorSavedCameraSettings(cameras: link.saved, emptyHelp: link.savedHelp)
        MonitorSettingsSourceGroups(groups: link.sourceGroups)
    }

    @ViewBuilder private func sharingRows(_ source: MonitorSettingsSharingSource,
        configuration: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        if !source.enabled {
            MonitorSettingsRowCard {
                MonitorSettingsInlineRow(title: source.unavailableTitle, help: source.unavailableHelp,
                    showTopDivider: false) { if let value = source.unavailableValue { MonitorSettingsValueText(value: value) } }
            }
        } else if configuration.isLive {
            let priorities = source.priorities ?? ["Quality", "High", "Medium", "Steady"]
            let priority = source.prioritySelection ?? Binding(get: {
                priorities[min(max(0, source.priority?.wrappedValue ?? 0), priorities.count - 1)]
            }, set: {
                if let index = priorities.firstIndex(of: $0) { source.priority?.wrappedValue = index }
            })
            MonitorFeedSharingSettings(sharing: source.sharing, passcode: source.passcode,
                controlRequests: source.controlRequests, priority: priority, priorities: priorities, help: source.help,
                showWiFiCode: source.joinCode == nil ? nil : { showJoinCode = true },
                passcodeChanged: source.passcodeChanged, feedback: configuration.feedback)
            if let watchers = source.watchers { watcherRows(watchers) }
        } else {
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

    @ViewBuilder private func controlsRows(_ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        if let gyro = source.gyro {
            MonitorSettingsRowCard(title: "Gyro logging") {
                MonitorSettingsSwitchInlineRow(title: "Log gyro with camera recordings",
                    help: "Mount this phone firmly to the camera. Synchronize exported logs in Gyroflow.",
                    showTopDivider: false, isOn: gyro.enabled.wrappedValue,
                    feedback: source.feedback) { gyro.enabled.wrappedValue.toggle() }
                    .disabled(!gyro.available)
                MonitorSettingsInlineRow(title: "Status", help: nil) {
                    MonitorSettingsValueText(value: gyro.status)
                }
            }
        }
        MonitorOperatorSafetySettings(recordConfirmation: source.recordConfirmation, haptics: source.haptics,
            keepScreenAwake: source.keepAwake, hapticsHelp: source.hapticsHelp,
            keepScreenAwakeHelp: source.keepAwakeHelp, feedback: source.feedback)
        if let input = source.input {
            MonitorInputOrientationSettings(remoteShutter: input.remoteShutter,
                remoteTitle: input.remoteTitle, remoteHelp: input.remoteHelp,
                autoRotateFeed: input.autoRotateFeed, rotationHelp: input.rotationHelp, feedback: source.feedback)
        }
        if let motion = source.motion {
            if let sensitivity = motion.sensitivity { MonitorGimbalSettings(sensitivity: sensitivity, headTracking: motion.headTracking) }
            if let joystick = motion.joystick {
                MonitorJoystickSettings(size: joystick.size, invertPan: joystick.invertPan, invertTilt: joystick.invertTilt,
                    deadZone: joystick.deadZone, response: joystick.response, identifierPrefix: joystick.identifier)
            }
            if let controller = motion.controller {
                MonitorControllerSettings(stick: controller, status: motion.controllerStatus, statusHelp: motion.controllerHelp)
            }
        }
    }

    @ViewBuilder private func storageRows(_ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        if let gyro = source.gyro {
            MonitorSettingsRowCard(title: "Gyro logs") {
                MonitorSettingsInlineRow(title: "Saved motion logs",
                    help: "Share a log with the matching camera video, then select its lens and mount orientation in Gyroflow.",
                    showTopDivider: false) {
                    MonitorSettingsActionPill(title: "Open", action: gyro.openLogs)
                }
            }
        }
        if let account = source.account {
            MonitorSettingsConfiguredAccount(source: account)
        }
        if let cache = source.cache {
            MonitorSettingsCapturedCache(source: cache, cacheOriginals: source.cacheOriginals,
                cacheHelp: source.cacheHelp, clearHelp: source.clearHelp, feedback: source.feedback,
                scopeHelp: source.cacheScopeHelp, confirmationMessage: source.cacheConfirmationMessage)
        } else if let library, let cacheOriginals = source.cacheOriginals {
            MonitorOperatorCacheSettings(library: library, cacheOriginals: cacheOriginals)
        }
    }

    @ViewBuilder private func systemRows(_ source: MonitorOperatorSettingsConfiguration<Looks>) -> some View {
        if let support = source.support {
            if support.model != nil {
                MonitorSettingsConfiguredSupport(source: support, report: {
                    if let action = support.reportAction { action() } else { showReport = true }
                })
            } else {
                MonitorSupportSettings(automaticReports: observedBinding(support.consent), available: support.available,
                    automaticHelp: support.automaticHelp, unavailableHelp: support.unavailableHelp,
                    report: { showReport = true }, privacy: { document = .privacy })
                MonitorDiagnosticSettings(expanded: $showDiagnostics, deleteHelp: support.deleteHelp,
                save: {
                    if let url = support.saveReport?() { reportShare = ReportShare(url: url) }
                    else { supportError = true }
                }, delete: { support.deleteReports?() })
                MonitorProjectLegalSettings(sourceHelp: support.sourceHelp, termsHelp: support.termsHelp,
                source: { if let url = support.sourceURL { openURL(url) } }, privacy: { document = .privacy },
                terms: { if let url = support.termsURL { openURL(url) } },
                licenses: { document = .licenses }, notice: { document = .notice })
            }
        }
        if let information = source.information {
            MonitorAppInformationSettings(theme: information.theme, protocolName: information.protocolName,
                version: information.version, themeHelp: information.themeHelp,
                protocolHelp: information.protocolHelp, versionHelp: information.versionHelp)
        }
    }
    private func observedBinding(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; preferenceRevision += 1 })
    }

    private func preference(_ field: ReferenceWritableKeyPath<MonitorOperatorPreferences, Bool>) -> Binding<Bool> {
        guard let preferences else { preconditionFailure("Configured settings require their explicit preference bindings") }
        return Binding(get: { preferences[keyPath: field] }, set: {
            preferences[keyPath: field] = $0; preferenceRevision += 1
        })
    }
    private func displayValue(_ mode: MonitorDisplayMode) -> Binding<MonitorDisplayChrome> {
        guard let operatorSession else { preconditionFailure("Borrowed layouts require their explicit display bindings") }
        return Binding(get: { operatorSession.chrome(for: mode) }, set: {
            if mode == .clean { operatorSession.clean = $0 } else { operatorSession.live = $0 }
            preferenceRevision += 1
        })
    }
}

private struct MonitorSettingsConfiguredSupport: View {
    let source: MonitorSettingsSupportSource
    let report: () -> Void
    var body: some View {
        Group {
            MonitorSupportSettings(automaticReports: source.consent, available: source.available,
                automaticHelp: source.automaticHelp, unavailableHelp: source.unavailableHelp,
                reportTitle: source.reportTitle, reportActionTitle: source.reportActionTitle,
                actions: supportActions, report: report, privacy: { request(source.privacyDestination) })
            MonitorProjectLegalSettings(sourceHelp: source.sourceHelp, termsHelp: source.termsHelp,
                source: { request(source.sourceDestination) }, privacy: { request(source.privacyDestination) },
                terms: { request(source.termsDestination) })
        }

    }
    private var supportActions: [MonitorSupportAction] {
        source.links.map { link in
            .init(id: link.destination.id, title: link.destination.title, help: link.help,
                actionTitle: link.actionTitle, accessibilityLabel: link.accessibilityLabel,
                action: { request(link.destination) })
        } + [.init(id: "support.diagnostics", title: "Share Diagnostics", help: source.diagnosticsHelp,
            actionTitle: source.model?.preparingReport == true ? "Preparing…" : "Share",
            accessibilityLabel: "Share Diagnostics", enabled: source.model?.preparingReport != true,
            action: { source.model?.prepareReport() })]
    }
    private func request(_ destination: MonitorSettingsBrowserDestination?) {
        if let destination { source.model?.request(destination) }
    }
}

private struct MonitorSettingsSupportPresentation: ViewModifier {
    let source: MonitorSettingsSupportSource?
    private struct ReportFile: Identifiable { var id: URL { url }; let url: URL }
    @ViewBuilder func body(content: Content) -> some View {
        if let source, source.model != nil {
            content
                .onAppear { bind() }
                .onChange(of: source.actions?.identity) { _, _ in bind() }
                .onChange(of: source.actions?.requiresInternetConsent) { _, _ in bind() }
                .sheet(item: Binding(get: { source.model?.reportURL.map { ReportFile(url: $0) } },
                    set: { if $0 == nil { source.model?.dismissReport() } })) { source.shareReport($0.url) }
                .alert("Leave camera Wi-Fi?", isPresented: Binding(
                    get: { source.model?.destination != nil }, set: { if !$0 { source.model?.cancelConfirmation() } })) {
                    Button("Cancel", role: .cancel) { source.model?.cancelConfirmation() }
                    Button("Continue") { source.model?.confirmBrowser() }
                } message: { if let destination = source.model?.destination { Text(destination.confirmationMessage) } }
                .alert(source.model?.reportFailed == true ? "Couldn’t Share Diagnostics" : "Couldn’t Reach the Internet",
                    isPresented: Binding(get: { source.model?.reportFailed == true || source.model?.browserFailed == true },
                        set: { if !$0 { source.model?.dismissError() } })) {
                    Button("OK", role: .cancel) { source.model?.dismissError() }
                } message: {
                    if let reason = source.model?.reportFailure ?? source.model?.browserFailure { Text(reason) }
                }
        } else { content }
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

private struct MonitorSettingsCapturedCache: View {
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
            cacheHelp: cacheHelp, scopeHelp: scopeHelp ?? "Originals and playback proxies downloaded from the camera.",
            clearHelp: clearHelp, feedback: feedback, clear: model.requestClear, clearSummary: model.clearSummary)
        .confirmationDialog("Clear cache?", isPresented: confirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive, action: model.clear)
            Button("Cancel", role: .cancel, action: model.cancelConfirmation)
        } message: { Text(confirmationMessage ?? "Removes downloaded clip files from this phone. The clip list is kept.") }
        .disabled(model.clearing)
        .alert(model.readFailed ? "Could not read the cache." : "Could not clear the cache. Try again.",
            isPresented: Binding(get: { model.clearFailed || model.readFailed }, set: { if !$0 { model.dismissError() } })) {
            Button("OK", role: .cancel, action: model.dismissError)
        } message: { if let reason = model.failure { Text(reason) } }
        .task(id: request) { model.refresh(source) }
        .onDisappear { model.retire() }
    }
    private var sizeLabel: String {
        guard let bytes = model.bytes else { return model.readFailed ? "Unavailable" : "Checking…" }
        return bytes == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
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
        MonitorSettingsCapturedCache(source: source, cacheOriginals: cacheOriginals,
            cacheHelp: "Keep originals downloaded for playback.",
            clearHelp: "Remove downloaded picture files while keeping the clip list.", feedback: {})
    }

    private var source: MonitorSettingsCacheSource {
        let token = library.actionToken
        let revision = library.cacheRevision
        let files = Set(library.entries.values.flatMap { [$0.originalURL, $0.proxyURL, $0.thumbnailURL].compactMap { $0 } })
        return MonitorSettingsCacheSource(
            identity: .init(namespace: library.cache.directory.root.path, source: token.lifetime), revision: revision,
            isCurrent: { library.isCurrent(token) && library.cacheRevision == revision },
            count: {
                await Task.detached {
                    files.reduce(UInt64(0)) { total, file in
                        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber
                        return total + (size?.uint64Value ?? 0)
                    }
                }.value
            }, clear: { try await library.clearCache() })
    }
}
#endif
