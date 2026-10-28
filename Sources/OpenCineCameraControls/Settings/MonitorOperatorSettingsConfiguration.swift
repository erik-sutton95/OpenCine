#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineApple
import OpenCineMedia
import SwiftUI

/// The Link tab's one Processing card (A2-78, Kotlin `processingChoices` and `processing`): the
/// feed upscaler with the shared help, then the host's own processing rows. Absent when this
/// device runs one upscaler and the host adds no rows.
public struct MonitorSettingsProcessingSource {
    let upscaler: Binding<MonitorUpscaler>
    let supported: [MonitorUpscaler]
    let feedback: () -> Void
    let rows: [MonitorSettingsSourceProperty]
    public init(upscaler: Binding<MonitorUpscaler>, supported: [MonitorUpscaler] = MonitorUpscaler.supportedOnThisDevice,
        feedback: @escaping () -> Void = {}, rows: [MonitorSettingsSourceProperty] = []) {
        self.upscaler = upscaler; self.supported = supported; self.feedback = feedback; self.rows = rows
    }

    /// The card the Link tab draws, or nil when there is nothing to choose or report.
    var group: MonitorSettingsSourceGroup? {
        let upscaler = self.upscaler
        let choice = supported.count > 1 ? [MonitorSettingsSourceProperty(id: "processing.upscaler",
            title: "Feed Upscaler", help: MonitorSettingsCopy.feedUpscaler,
            value: .choice(.init(options: supported.map(\.rawValue), selection: Binding(
                get: { upscaler.wrappedValue.rawValue },
                set: { if let next = MonitorUpscaler(rawValue: $0) { upscaler.wrappedValue = next } }),
                help: MonitorSettingsCopy.feedUpscaler, feedback: feedback)), compact: true)] : []
        let properties = choice + rows
        return properties.isEmpty ? nil : .init(id: "processing", title: "Processing", properties: properties)
    }
}

/// Connection facts and the optional processing card, with no transport ownership.
public struct MonitorSettingsLinkSource {
    let transport: String, transportHelp: String, phase: String, phaseHelp: String
    let network: String?, networkHelp: String
    let signalBars: Int?
    /// The saved setups, or nil where the host keeps none (Kotlin `savedCameras`).
    let saved: [MonitorSavedCameraSummary]?
    let savedHelp: String
    let processing: MonitorSettingsProcessingSource?
    let sourceGroups: [MonitorSettingsSourceGroup]
    let healthScore: Int?
    let healthCaption: String?
    public init(transport: String, transportHelp: String, phase: String, phaseHelp: String,
        network: String?, networkHelp: String, signalBars: Int?, saved: [MonitorSavedCameraSummary],
        savedHelp: String, processing: MonitorSettingsProcessingSource? = nil,
        sourceGroups: [MonitorSettingsSourceGroup] = [], healthScore: Int? = nil, healthCaption: String? = nil) {
        self.transport = transport; self.transportHelp = transportHelp; self.phase = phase; self.phaseHelp = phaseHelp
        self.network = network; self.networkHelp = networkHelp; self.signalBars = signalBars
        self.saved = saved; self.savedHelp = savedHelp; self.processing = processing
        self.sourceGroups = sourceGroups; self.healthScore = healthScore; self.healthCaption = healthCaption
    }
    /// Connection facts of a host that keeps no saved setups and offers no processing choice.
    public init(transport: String, transportHelp: String, phase: String, phaseHelp: String,
        network: String? = nil, networkHelp: String = "", signalBars: Int? = nil) {
        self.transport = transport; self.transportHelp = transportHelp; self.phase = phase; self.phaseHelp = phaseHelp
        self.network = network; self.networkHelp = networkHelp; self.signalBars = signalBars
        self.saved = nil; self.savedHelp = ""; self.processing = nil
        self.sourceGroups = []; self.healthScore = nil; self.healthCaption = nil
    }
}

public struct MonitorSettingsSharingSource {
    let enabled: Bool
    let unavailableHelp: String?
    let sharing: Binding<Bool>, passcode: Binding<String>, controlRequests: Binding<Bool>
    let priority: Binding<Int>?
    let prioritySelection: Binding<String>?
    let priorities: [String]?
    let watchers: MonitorSettingsWatchersSource?
    let unavailableTitle: String
    let unavailableValue: String?
    let help: MonitorFeedSharingHelp
    let browseHelp: String
    let browse: () -> Void
    let passcodeChanged: (String) -> Void
    let joinCode: (@MainActor @Sendable () -> AnyView)?
    public init(enabled: Bool = true, unavailableHelp: String? = nil,
        sharing: Binding<Bool>, passcode: Binding<String>, controlRequests: Binding<Bool>, priority: Binding<Int>,
        help: MonitorFeedSharingHelp, browseHelp: String, browse: @escaping () -> Void,
        passcodeChanged: @escaping (String) -> Void,
        joinCode: (@MainActor @Sendable () -> AnyView)? = nil) {
        self.enabled = enabled; self.unavailableHelp = unavailableHelp
        self.sharing = sharing; self.passcode = passcode; self.controlRequests = controlRequests; self.priority = priority
        self.prioritySelection = nil; self.priorities = nil; self.watchers = nil
        self.unavailableTitle = "Sharing unavailable in Multiview"; self.unavailableValue = nil
        self.help = help; self.browseHelp = browseHelp; self.browse = browse
        self.passcodeChanged = passcodeChanged; self.joinCode = joinCode
    }
    public init(enabled: Bool = true, unavailableHelp: String? = nil,
        sharing: Binding<Bool>, passcode: Binding<String>, controlRequests: Binding<Bool>,
        prioritySelection: Binding<String>, priorities: [String], help: MonitorFeedSharingHelp,
        browseHelp: String, browse: @escaping () -> Void, passcodeChanged: @escaping (String) -> Void,
        watchers: MonitorSettingsWatchersSource? = nil, unavailableTitle: String = "Sharing unavailable",
        unavailableValue: String? = nil, joinCode: (@MainActor @Sendable () -> AnyView)? = nil) {
        precondition(!priorities.isEmpty)
        self.enabled = enabled; self.unavailableHelp = unavailableHelp
        self.sharing = sharing; self.passcode = passcode; self.controlRequests = controlRequests
        self.priority = nil; self.prioritySelection = prioritySelection; self.priorities = priorities; self.watchers = watchers
        self.unavailableTitle = unavailableTitle; self.unavailableValue = unavailableValue
        self.help = help; self.browseHelp = browseHelp; self.browse = browse; self.passcodeChanged = passcodeChanged; self.joinCode = joinCode
    }

}

public struct MonitorSettingsJoystickSource {
    let size: MonitorMotionChoiceSetting, invertPan: MonitorMotionToggleSetting, invertTilt: MonitorMotionToggleSetting
    let deadZone: MonitorMotionIntegerSetting, response: MonitorMotionChoiceSetting
    let identifier: String
    public init(size: MonitorMotionChoiceSetting, invertPan: MonitorMotionToggleSetting,
        invertTilt: MonitorMotionToggleSetting, deadZone: MonitorMotionIntegerSetting,
        response: MonitorMotionChoiceSetting, identifier: String = "monitor.joystick") {
        self.size = size; self.invertPan = invertPan; self.invertTilt = invertTilt
        self.deadZone = deadZone; self.response = response; self.identifier = identifier
    }
}

public struct MonitorSettingsMotionSource {
    let sensitivity: MonitorMotionIntegerSetting?
    let headTracking: MonitorMotionToggleSetting?
    let joystick: MonitorSettingsJoystickSource?
    let controller: MonitorMotionChoiceSetting?
    let controllerStatus: String, controllerHelp: String
    public init(sensitivity: MonitorMotionIntegerSetting? = nil, headTracking: MonitorMotionToggleSetting? = nil,
        joystick: MonitorSettingsJoystickSource? = nil, controller: MonitorMotionChoiceSetting? = nil,
        controllerStatus: String = "Not connected", controllerHelp: String = "") {
        self.sensitivity = sensitivity; self.headTracking = headTracking; self.joystick = joystick
        self.controller = controller; self.controllerStatus = controllerStatus; self.controllerHelp = controllerHelp
    }
}

public struct MonitorSettingsAccountSource {
    let title: String, help: String
    let state: MonitorAccountState
    let signIn: () -> Void, signOut: () -> Void
    let model: MonitorSettingsAccountModel?
    let actions: MonitorSettingsAccountActions?
    let readState: (@MainActor () -> MonitorAccountState)?
    let consentTitle: String, consentMessage: String, consentAction: String
    let status: String?, signInTitle: String, signOutTitle: String, busyTitle: String?
    public init(title: String, help: String, state: MonitorAccountState,
        signIn: @escaping () -> Void, signOut: @escaping () -> Void) {
        self.title = title; self.help = help; self.state = state; self.signIn = signIn; self.signOut = signOut
        self.model = nil; self.actions = nil; self.readState = nil
        self.consentTitle = "Leave camera Wi-Fi?"; self.consentMessage = ""; self.consentAction = "Continue"
        self.status = nil; self.signInTitle = "Sign in"; self.signOutTitle = "Log out"; self.busyTitle = nil
    }
    @MainActor public init(title: String, help: String, model: MonitorSettingsAccountModel,
        actions: MonitorSettingsAccountActions, readState: @escaping @MainActor () -> MonitorAccountState,
        consentTitle: String, consentMessage: String, consentAction: String,
        status: String? = nil, signInTitle: String = "Sign in", signOutTitle: String = "Log out",
        busyTitle: String? = nil) {
        self.title = title; self.help = help; self.state = .signedOut
        self.model = model; self.actions = actions; self.readState = readState
        self.signIn = model.requestSignIn; self.signOut = model.signOut
        self.consentTitle = consentTitle; self.consentMessage = consentMessage; self.consentAction = consentAction
        self.status = status; self.signInTitle = signInTitle; self.signOutTitle = signOutTitle; self.busyTitle = busyTitle
    }
}

public enum MonitorSettingsDocument: String, Identifiable { case privacy, licenses, notice; public var id: String { rawValue } }

/// Optional phone motion logging controls; capture and storage stay with the host app.
public struct MonitorSettingsGyroSource {
    let enabled: Binding<Bool>
    let status: String
    let available: Bool
    let openLogs: () -> Void
    let mountName: String?
    let configureMount: (() -> Void)?
    /// Starts the phone mount calibration; the settings card shows its row only when set.
    let calibrate: (() -> Void)?

    /// Creates host-owned controls with callbacks for the logs and for the mount calibration.
    public init(enabled: Binding<Bool>, status: String, available: Bool = true,
        openLogs: @escaping () -> Void, calibrate: (() -> Void)? = nil) {
        self.enabled = enabled; self.status = status
        self.available = available; self.openLogs = openLogs
        self.mountName = nil; self.configureMount = nil; self.calibrate = calibrate
    }

    /// The old form with phone mount presets, kept so existing callers compile.
    @available(*, deprecated, message: "Mount presets are gone; pass calibrate")
    public init(enabled: Binding<Bool>, status: String, available: Bool = true,
        openLogs: @escaping () -> Void, mountName: String?,
        configureMount: (() -> Void)? = nil, calibrate: (() -> Void)? = nil) {
        self.enabled = enabled; self.status = status
        self.available = available; self.openLogs = openLogs
        self.mountName = mountName; self.configureMount = configureMount; self.calibrate = calibrate
    }
}

public struct MonitorSettingsSupportLink {
    let destination: MonitorSettingsBrowserDestination
    let help: String
    let actionTitle: String
    let accessibilityLabel: String
    public init(destination: MonitorSettingsBrowserDestination, help: String,
        actionTitle: String, accessibilityLabel: String) {
        self.destination = destination; self.help = help
        self.actionTitle = actionTitle; self.accessibilityLabel = accessibilityLabel
    }
}

/// Reporting/authorization remain SDK adapters; common sheet and disclosure lifetime is shared.
/// The problem report itself is the app root's (A2-24): `report` asks the root to present it, so a
/// draft survives the monitor ending and the settings cover closing (Kotlin `report`).
public struct MonitorSettingsSupportSource {
    /// The automatic-reports switch, or nil where the host offers no automatic reports.
    let consent: Binding<Bool>?
    let available: Bool
    let automaticHelp: String, unavailableHelp: String, deleteHelp: String, sourceHelp: String, termsHelp: String
    let sourceURL: URL?, termsURL: URL?
    let saveReport: (() -> URL?)?
    let deleteReports: (() -> Void)?
    /// Asks the app root to present its problem report (`ShellActions.reportProblem`).
    let report: () -> Void
    let document: (@MainActor @Sendable (MonitorSettingsDocument, @escaping () -> Void) -> AnyView)?
    let shareReport: @MainActor @Sendable (URL) -> AnyView
    let model: MonitorSettingsSupportModel?
    let actions: MonitorSettingsSupportActions?
    let links: [MonitorSettingsSupportLink]
    let privacyDestination: MonitorSettingsBrowserDestination?
    let sourceDestination: MonitorSettingsBrowserDestination?
    let termsDestination: MonitorSettingsBrowserDestination?
    let reportTitle: String, reportActionTitle: String, diagnosticsHelp: String
    let supportEmail: String
    let deleteStoredReports: (() -> Void)?
    let deleteReportsHelp: String
    /// Legal pages the shared legal screen shows: bundled text opens in it, a web page keeps the
    /// host's browser destination. Nil keeps privacy and terms on those destinations only.
    let legal: MonitorLegalDocuments?
    /// Host support actions listed after the report row when no support model owns the rows.
    let hostActions: [MonitorSupportAction]
    public init(consent: Binding<Bool>, available: Bool, automaticHelp: String, unavailableHelp: String,
        deleteHelp: String, sourceHelp: String, termsHelp: String, sourceURL: URL?, termsURL: URL?,
        saveReport: @escaping () -> URL?, deleteReports: @escaping () -> Void,
        report: @escaping () -> Void,
        document: @escaping @MainActor @Sendable (MonitorSettingsDocument, @escaping () -> Void) -> AnyView,
        shareReport: @escaping @MainActor @Sendable (URL) -> AnyView,
        supportEmail: String = "support@opencapture.org") {
        self.consent = consent; self.available = available; self.automaticHelp = automaticHelp
        self.unavailableHelp = unavailableHelp; self.deleteHelp = deleteHelp
        self.sourceHelp = sourceHelp; self.termsHelp = termsHelp; self.sourceURL = sourceURL; self.termsURL = termsURL
        self.saveReport = saveReport; self.deleteReports = deleteReports
        self.report = report; self.document = document; self.shareReport = shareReport
        self.model = nil; self.actions = nil; self.links = []
        self.privacyDestination = nil; self.sourceDestination = nil; self.termsDestination = nil
        self.reportTitle = "Report a problem"; self.reportActionTitle = "Open"; self.diagnosticsHelp = ""
        self.supportEmail = supportEmail
        self.deleteStoredReports = nil; self.deleteReportsHelp = ""
        self.legal = nil; self.hostActions = []
    }
    /// A report action and the host's own support actions, with no automatic reports, browser
    /// links or support model (Kotlin `MonitorSettingsSupportSource(report, actions)`).
    public init(report: @escaping () -> Void, actions: [MonitorSupportAction] = [],
        reportTitle: String = "Report a problem", reportActionTitle: String = "Open",
        legal: MonitorLegalDocuments? = nil, supportEmail: String = "support@opencapture.org") {
        self.consent = nil; self.available = false; self.automaticHelp = ""; self.unavailableHelp = ""
        self.deleteHelp = ""; self.sourceHelp = ""; self.termsHelp = ""; self.sourceURL = nil; self.termsURL = nil
        self.saveReport = nil; self.deleteReports = nil
        self.report = report; self.document = nil; self.shareReport = { _ in AnyView(EmptyView()) }
        self.model = nil; self.actions = nil; self.links = []
        self.privacyDestination = nil; self.sourceDestination = nil; self.termsDestination = nil
        self.reportTitle = reportTitle; self.reportActionTitle = reportActionTitle
        self.diagnosticsHelp = ""; self.supportEmail = supportEmail
        self.deleteStoredReports = nil; self.deleteReportsHelp = ""
        self.legal = legal; self.hostActions = actions
    }
    @MainActor public init(consent: Binding<Bool>, available: Bool, automaticHelp: String, unavailableHelp: String,
        sourceHelp: String, termsHelp: String, model: MonitorSettingsSupportModel, actions: MonitorSettingsSupportActions,
        links: [MonitorSettingsSupportLink], privacy: MonitorSettingsBrowserDestination?,
        source: MonitorSettingsBrowserDestination?, terms: MonitorSettingsBrowserDestination?,
        reportTitle: String, reportActionTitle: String, diagnosticsHelp: String,
        report: @escaping () -> Void,
        shareReport: @escaping @MainActor @Sendable (URL) -> AnyView,
        deleteStoredReports: (() -> Void)? = nil, deleteReportsHelp: String = "",
        supportEmail: String = "support@opencapture.org", legal: MonitorLegalDocuments? = nil) {
        self.consent = consent; self.available = available; self.automaticHelp = automaticHelp; self.unavailableHelp = unavailableHelp
        self.legal = legal
        self.deleteHelp = ""; self.sourceHelp = sourceHelp; self.termsHelp = termsHelp
        self.sourceURL = source?.url; self.termsURL = terms?.url; self.saveReport = nil; self.deleteReports = nil
        self.report = report; self.document = nil; self.shareReport = shareReport
        self.model = model; self.actions = actions; self.links = links
        self.privacyDestination = privacy; self.sourceDestination = source; self.termsDestination = terms
        self.reportTitle = reportTitle; self.reportActionTitle = reportActionTitle
        self.diagnosticsHelp = diagnosticsHelp
        self.supportEmail = supportEmail
        self.deleteStoredReports = deleteStoredReports; self.deleteReportsHelp = deleteReportsHelp
        self.hostActions = []
    }
}

/// A2-79: the report-unavailable alert names the host's support address, never a hard-coded one.
/// A2-25: the configured System tab rows come from one shared order, so the model-backed apps
/// expose the same host links, share-diagnostics row and, when the host supplies one, the
/// delete-stored-reports row the closure-path apps already render.
extension MonitorSettingsSupportSource {
    /// Whether a legal page opens in the shared legal screen rather than through the browser.
    func showsLocally(_ page: MonitorLegalPage) -> Bool {
        guard let legal else { return false }
        if case .link = legal[page] { return false }
        return true
    }

    var reportUnavailableMessage: String {
        "Email \(supportEmail). You can save a report under Diagnostic options."
    }

    /// Main actor: the rows' actions call the main-actor support model, so the action literals
    /// keep that isolation like every other view-built closure here.
    @MainActor
    func configuredSupportActions(reportPreparing: Bool) -> [MonitorSupportAction] {
        guard model != nil else { return hostActions }
        return links.map { link in
            MonitorSupportAction(id: link.destination.id, title: link.destination.title, help: link.help,
                actionTitle: link.actionTitle, accessibilityLabel: link.accessibilityLabel,
                action: { model?.request(link.destination) })
        }
        + [MonitorSupportAction(id: "support.diagnostics", title: "Share Diagnostics", help: diagnosticsHelp,
            actionTitle: reportPreparing ? "Preparing…" : "Share",
            accessibilityLabel: "Share Diagnostics", enabled: !reportPreparing,
            action: { Task { @MainActor in model?.prepareReport() } })]
        + (deleteStoredReports.map { delete in
            [MonitorSupportAction(id: "support.deleteReports", title: "Delete saved feed reports",
                help: deleteReportsHelp, actionTitle: "Delete",
                accessibilityLabel: "Delete saved feed reports", action: delete)]
        } ?? [])
    }

    /// The closure form keeps its Save and Delete disclosure; the model form lists those actions
    /// in Help & Feedback.
    var showsDiagnosticOptions: Bool { model == nil && saveReport != nil }

    /// Project & Legal appears only with a page to open: a browser destination, bundled legal
    /// pages, or the closure form's document pages.
    var showsProjectLegal: Bool {
        document != nil || legal != nil || sourceDestination != nil || termsDestination != nil
            || privacyDestination != nil
    }
}

public struct MonitorSettingsAppInformation {
    let theme: String, protocolName: String, version: String
    let themeHelp: String, protocolHelp: String, versionHelp: String
    public init(theme: String, protocolName: String, version: String,
        themeHelp: String, protocolHelp: String, versionHelp: String) {
        self.theme = theme; self.protocolName = protocolName; self.version = version
        self.themeHelp = themeHelp; self.protocolHelp = protocolHelp; self.versionHelp = versionHelp
    }
    public static func version(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "0.1") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }
}

/// One on/off choice and the help under it.
public struct MonitorSettingsToggle {
    let value: Binding<Bool>
    let help: String
    public init(value: Binding<Bool>, help: String) { self.value = value; self.help = help }
}

/// Controls tab: touch and safety choices, then the optional input and motion rows
/// (Kotlin `MonitorSettingsControlsSource`).
public struct MonitorSettingsControlsSource {
    let recordConfirmation: Binding<Bool>
    let haptics: MonitorSettingsToggle
    let keepAwake: MonitorSettingsToggle
    let input: MonitorSettingsInputSource?
    let motion: MonitorSettingsMotionSource?
    public init(recordConfirmation: Binding<Bool>, haptics: MonitorSettingsToggle, keepAwake: MonitorSettingsToggle,
        input: MonitorSettingsInputSource? = nil, motion: MonitorSettingsMotionSource? = nil) {
        self.recordConfirmation = recordConfirmation; self.haptics = haptics; self.keepAwake = keepAwake
        self.input = input; self.motion = motion
    }
}

/// Display tab: the optional HDR panel choice and the chrome sections this camera can show.
public struct MonitorSettingsDisplaySource {
    let hdr: MonitorSettingsToggle?
    let sections: Set<MonitorDisplayChrome.Section>
    /// The sections every camera can show.
    public static let commonSections: Set<MonitorDisplayChrome.Section> = [.statusBar, .cameraValues,
        .lockButton, .recReadout, .timecode, .toolBar, .railRecord, .railMedia, .railSettings]
    public init(hdr: MonitorSettingsToggle? = nil, sections: Set<MonitorDisplayChrome.Section> = commonSections) {
        self.hdr = hdr; self.sections = sections
    }
}

/// Storage cache rows (Kotlin `MonitorSettingsCachePresentation`). Clearing always asks first.
public struct MonitorSettingsCachePresentation {
    let source: MonitorSettingsCacheSource
    let cacheOriginals: MonitorSettingsToggle?
    let clearHelp: String
    let scopeHelp: String?
    let confirmationMessage: String?
    /// Nil scope and confirmation texts use the shared every-camera wording (A2-33).
    public init(source: MonitorSettingsCacheSource, cacheOriginals: MonitorSettingsToggle? = nil,
        clearHelp: String, scopeHelp: String? = nil, confirmationMessage: String? = nil) {
        self.source = source; self.cacheOriginals = cacheOriginals; self.clearHelp = clearHelp
        self.scopeHelp = scopeHelp; self.confirmationMessage = confirmationMessage
    }
}

/// View Assist tab: tool switches or option panels, the exposure meter and the look catalog.
@MainActor
public struct MonitorSettingsAssistSource<Looks: MonitorLookProvider> {
    let state: MonitorAssistState<Looks>
    /// Plain on/off rows, for tools a host offers without option panels.
    let switches: [MonitorAssistSelection]
    let panels: (@MainActor () -> AnyView)?
    let exposureHelp: String?
    let lookLabel: String
    let lookCatalog: (@MainActor @Sendable () -> AnyView)?

    /// Option panels for `available` tools over the host's stores, with the exposure meter row
    /// when `exposureHelp` is given and the look row when there is a catalog.
    public init<Palette: LiveChromePalette>(state: MonitorAssistState<Looks>, stores: AssistPanelStores,
        falseColorLooks: FalseColorLooks, palette: Palette.Type, haptics: OperatorHaptics,
        transfer: MonitorTransfer, clipByte: Int,
        available: Set<MonitorAssistSelection> = [.falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope, .peaking, .trafficLights],
        signalOptions: MonitorOperatorSignalOptions = .init(), exposureHelp: String?,
        lookLabel: String = "", lookCatalog: (@MainActor @Sendable () -> AnyView)? = nil) {
        self.init(state: state, switches: [], panels: {
            AnyView(MonitorOperatorAssistSettings(assist: state, stores: stores, looks: falseColorLooks,
                palette: palette, haptics: haptics, transfer: transfer, clipByte: clipByte,
                available: available, signalOptions: signalOptions))
        }, exposureHelp: exposureHelp, lookLabel: lookLabel, lookCatalog: lookCatalog)
    }

    init(state: MonitorAssistState<Looks>, switches: [MonitorAssistSelection], panels: (@MainActor () -> AnyView)?,
        exposureHelp: String? = nil, lookLabel: String = "", lookCatalog: (@MainActor @Sendable () -> AnyView)? = nil) {
        self.state = state; self.switches = switches; self.panels = panels
        self.exposureHelp = exposureHelp; self.lookLabel = lookLabel; self.lookCatalog = lookCatalog
    }
}

/// Every row the one settings body draws (A2-35). Each tab lists its rows from the configured
/// domains, so every call form and the shared scene render the same rows for the same values.
enum MonitorSettingsRow: String, Hashable, Sendable {
    case linkHealth, connection, processing, savedCameras, sourceGroups
    case sharingUnavailable, sharing, watchers, watchFeed
    case assistTools, assistPanels, exposureMeter, look
    case gyro, safety, input, gimbal, joystick, controller
    case hdrPanel, displaySections
    case gyroLogs, account, cache
    case support, diagnosticOptions, projectLegal, information
}

/// Values and coherent optional domains for the complete common settings owner.
@MainActor
public struct MonitorOperatorSettingsConfiguration<Looks: MonitorLookProvider> {
    let safeArea: EdgeInsets
    let phase: String
    let sharingSubtitle: String?
    let isLive: Bool
    let close: () -> Void, disconnect: () -> Void, feedback: () -> Void
    let link: MonitorSettingsLinkSource
    let sharing: MonitorSettingsSharingSource?
    let gyro: MonitorSettingsGyroSource?
    let assistSource: MonitorSettingsAssistSource<Looks>
    let controls: MonitorSettingsControlsSource
    let display: MonitorSettingsDisplaySource
    let cache: MonitorSettingsCachePresentation?
    /// Published form only: originals caching over the screen's media library when no cache is given.
    let libraryCacheOriginals: Binding<Bool>?
    let account: MonitorSettingsAccountSource?
    let support: MonitorSettingsSupportSource?
    let information: MonitorSettingsAppInformation?

    var assist: MonitorAssistState<Looks> { assistSource.state }

    /// The one typed form: each optional domain is present or nil, never an empty flag.
    public init(safeArea: EdgeInsets, phase: String, isLive: Bool, sharingSubtitle: String? = nil,
        close: @escaping () -> Void, disconnect: @escaping () -> Void, feedback: @escaping () -> Void,
        link: MonitorSettingsLinkSource, sharing: MonitorSettingsSharingSource? = nil,
        assist: MonitorSettingsAssistSource<Looks>, controls: MonitorSettingsControlsSource,
        display: MonitorSettingsDisplaySource = .init(), cache: MonitorSettingsCachePresentation? = nil,
        account: MonitorSettingsAccountSource? = nil, support: MonitorSettingsSupportSource? = nil,
        information: MonitorSettingsAppInformation? = nil, gyro: MonitorSettingsGyroSource? = nil) {
        self.init(safeArea: safeArea, phase: phase, isLive: isLive, sharingSubtitle: sharingSubtitle,
            close: close, disconnect: disconnect, feedback: feedback, link: link, sharing: sharing,
            assistSource: assist, controls: controls, display: display, cache: cache, libraryCacheOriginals: nil,
            account: account, support: support, information: information, gyro: gyro)
    }

    private init(safeArea: EdgeInsets, phase: String, isLive: Bool, sharingSubtitle: String?,
        close: @escaping () -> Void, disconnect: @escaping () -> Void, feedback: @escaping () -> Void,
        link: MonitorSettingsLinkSource, sharing: MonitorSettingsSharingSource?,
        assistSource: MonitorSettingsAssistSource<Looks>, controls: MonitorSettingsControlsSource,
        display: MonitorSettingsDisplaySource, cache: MonitorSettingsCachePresentation?,
        libraryCacheOriginals: Binding<Bool>?, account: MonitorSettingsAccountSource?,
        support: MonitorSettingsSupportSource?, information: MonitorSettingsAppInformation?, gyro: MonitorSettingsGyroSource?) {
        self.safeArea = safeArea; self.phase = phase; self.isLive = isLive; self.sharingSubtitle = sharingSubtitle
        self.close = close; self.disconnect = disconnect; self.feedback = feedback
        self.gyro = gyro
        self.link = link; self.sharing = sharing; self.assistSource = assistSource
        self.controls = controls; self.display = display; self.cache = cache
        self.libraryCacheOriginals = libraryCacheOriginals
        self.account = account; self.support = support; self.information = information
    }

    /// Published form: translates to the typed domains.
    public init<Palette: LiveChromePalette>(safeArea: EdgeInsets, phase: String, isLive: Bool,
        sharingSubtitle: String, close: @escaping () -> Void, disconnect: @escaping () -> Void,
        feedback: @escaping () -> Void, link: MonitorSettingsLinkSource,
        sharing: MonitorSettingsSharingSource? = nil, motion: MonitorSettingsMotionSource? = nil,
        account: MonitorSettingsAccountSource? = nil, cache: MonitorSettingsCacheSource? = nil,
        support: MonitorSettingsSupportSource? = nil, information: MonitorSettingsAppInformation? = nil,
        recordConfirmation: Binding<Bool>, haptics: Binding<Bool>, keepAwake: Binding<Bool>,
        hdrDisplay: Binding<Bool>, cacheOriginals: Binding<Bool>,
        hapticsHelp: String, keepAwakeHelp: String, hdrHelp: String, cacheHelp: String, clearHelp: String,
        exposureHelp: String, availableDisplay: Set<MonitorDisplayChrome.Section>,
        assist: MonitorAssistState<Looks>, stores: AssistPanelStores, falseColorLooks: FalseColorLooks,
        palette: Palette.Type, operatorHaptics: OperatorHaptics, transfer: MonitorTransfer, clipByte: Int,
        lookLabel: String, lookCatalog: (@MainActor @Sendable () -> AnyView)? = nil,
        availableAssist: Set<MonitorAssistSelection> = [.falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope, .peaking, .trafficLights],
        gyro: MonitorSettingsGyroSource? = nil) {
        self.init(borrowedSafeArea: safeArea, phase: phase, isLive: isLive, sharingSubtitle: sharingSubtitle,
            close: close, disconnect: disconnect, feedback: feedback, link: link, sharing: sharing, motion: motion,
            account: account, cache: cache, support: support, information: information,
            recordConfirmation: recordConfirmation, haptics: haptics, keepAwake: keepAwake,
            hdrDisplay: hdrDisplay, cacheOriginals: cacheOriginals, hapticsHelp: hapticsHelp, keepAwakeHelp: keepAwakeHelp,
            hdrHelp: hdrHelp, cacheHelp: cacheHelp, clearHelp: clearHelp, exposureHelp: exposureHelp, availableDisplay: availableDisplay,
            assist: assist, stores: stores, falseColorLooks: falseColorLooks, palette: palette, operatorHaptics: operatorHaptics,
            transfer: transfer, clipByte: clipByte, lookLabel: lookLabel, lookCatalog: lookCatalog, availableAssist: availableAssist, gyro: gyro)
    }

    /// Published form: translates to the typed domains. A nil binding leaves its row out.
    public init<Palette: LiveChromePalette>(borrowedSafeArea: EdgeInsets, phase: String, isLive: Bool,
        sharingSubtitle: String, close: @escaping () -> Void, disconnect: @escaping () -> Void,
        feedback: @escaping () -> Void, link: MonitorSettingsLinkSource,
        sharing: MonitorSettingsSharingSource? = nil, motion: MonitorSettingsMotionSource? = nil,
        account: MonitorSettingsAccountSource? = nil, cache: MonitorSettingsCacheSource? = nil,
        support: MonitorSettingsSupportSource? = nil, information: MonitorSettingsAppInformation? = nil,
        recordConfirmation: Binding<Bool>, haptics: Binding<Bool>, keepAwake: Binding<Bool>,
        hdrDisplay: Binding<Bool>? = nil, cacheOriginals: Binding<Bool>? = nil,
        hapticsHelp: String, keepAwakeHelp: String, hdrHelp: String, cacheHelp: String, clearHelp: String,
        exposureHelp: String, availableDisplay: Set<MonitorDisplayChrome.Section>? = nil,
        assist: MonitorAssistState<Looks>, stores: AssistPanelStores, falseColorLooks: FalseColorLooks,
        palette: Palette.Type, operatorHaptics: OperatorHaptics, transfer: MonitorTransfer, clipByte: Int,
        lookLabel: String, lookCatalog: (@MainActor @Sendable () -> AnyView)? = nil,
        availableAssist: Set<MonitorAssistSelection> = [.falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope, .peaking, .trafficLights],
        input: MonitorSettingsInputSource? = nil, signalOptions: MonitorOperatorSignalOptions = .init(),
        cacheScopeHelp: String? = nil, cacheConfirmationMessage: String? = nil,
        gyro: MonitorSettingsGyroSource? = nil) {
        let originals = cacheOriginals.map { MonitorSettingsToggle(value: $0, help: cacheHelp) }
        self.init(safeArea: borrowedSafeArea, phase: phase, isLive: isLive, sharingSubtitle: sharingSubtitle,
            close: close, disconnect: disconnect, feedback: feedback, link: link, sharing: sharing,
            assistSource: .init(state: assist, stores: stores, falseColorLooks: falseColorLooks, palette: palette,
                haptics: operatorHaptics, transfer: transfer, clipByte: clipByte, available: availableAssist,
                signalOptions: signalOptions, exposureHelp: exposureHelp, lookLabel: lookLabel, lookCatalog: lookCatalog),
            controls: .init(recordConfirmation: recordConfirmation,
                haptics: .init(value: haptics, help: hapticsHelp), keepAwake: .init(value: keepAwake, help: keepAwakeHelp),
                input: input, motion: motion),
            display: .init(hdr: hdrDisplay.map { .init(value: $0, help: hdrHelp) },
                sections: availableDisplay ?? MonitorSettingsDisplaySource.commonSections),
            cache: cache.map { .init(source: $0, cacheOriginals: originals, clearHelp: clearHelp,
                scopeHelp: cacheScopeHelp, confirmationMessage: cacheConfirmationMessage) },
            libraryCacheOriginals: cache == nil ? cacheOriginals : nil,
            account: account, support: support, information: information, gyro: gyro)
    }

    /// Stable order; a tab is left out only when its whole optional domain is absent.
    func tabs(library: Bool) -> [MonitorSettingsTab] {
        MonitorSettingsTab.allCases.filter { !rows($0, library: library).isEmpty }
    }

    /// The rows `tab` shows, in order. `library` says whether the screen has a media library
    /// for the published originals-caching form.
    func rows(_ tab: MonitorSettingsTab, library: Bool) -> [MonitorSettingsRow] {
        switch tab {
        case .link:
            return [.linkHealth, .connection] + (link.processing?.group == nil ? [] : [.processing])
                + (link.saved == nil ? [] : [.savedCameras]) + (link.sourceGroups.isEmpty ? [] : [.sourceGroups])
        case .sharing:
            guard let sharing else { return [] }
            if !sharing.enabled { return [.sharingUnavailable] }
            return isLive ? [.sharing] + (sharing.watchers == nil ? [] : [.watchers]) : [.watchFeed]
        case .assist:
            return (assistSource.switches.isEmpty ? [] : [.assistTools]) + (assistSource.panels == nil ? [] : [.assistPanels])
                + (assistSource.exposureHelp == nil ? [] : [.exposureMeter]) + (assistSource.lookCatalog == nil ? [] : [.look])
        case .controls:
            let motion = controls.motion
            let input = controls.input.map { $0.remoteShutter != nil || $0.autoRotate != nil } ?? false
            return (gyro == nil ? [] : [.gyro]) + [.safety] + (input ? [.input] : [])
                + (motion?.sensitivity == nil ? [] : [.gimbal]) + (motion?.joystick == nil ? [] : [.joystick])
                + (motion?.controller == nil ? [] : [.controller])
        case .display:
            return (display.hdr == nil ? [] : [.hdrPanel]) + [.displaySections]
        case .storage:
            let libraryCache = library && libraryCacheOriginals != nil
            return (gyro == nil ? [] : [.gyroLogs]) + (account == nil ? [] : [.account]) + (cache == nil && !libraryCache ? [] : [.cache])
        case .system:
            var rows: [MonitorSettingsRow] = []
            if let support {
                rows.append(.support)
                if support.showsDiagnosticOptions { rows.append(.diagnosticOptions) }
                if support.showsProjectLegal { rows.append(.projectLegal) }
            }
            return rows + (information == nil ? [] : [.information])
        }
    }
}
#endif
