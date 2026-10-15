#if os(iOS)
import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI

/// Connection facts and an optional SDK processing choice, with no transport ownership.
public struct MonitorSettingsLinkSource {
    let transport: String, transportHelp: String, phase: String, phaseHelp: String
    let network: String?, networkHelp: String
    let signalBars: Int?
    let saved: [MonitorSavedCameraSummary]
    let savedHelp: String
    let processing: MonitorMotionChoiceSetting?
    let sourceGroups: [MonitorSettingsSourceGroup]
    let healthScore: Int?
    let healthCaption: String?
    public init(transport: String, transportHelp: String, phase: String, phaseHelp: String,
        network: String?, networkHelp: String, signalBars: Int?, saved: [MonitorSavedCameraSummary],
        savedHelp: String, processing: MonitorMotionChoiceSetting? = nil,
        sourceGroups: [MonitorSettingsSourceGroup] = [], healthScore: Int? = nil, healthCaption: String? = nil) {
        self.transport = transport; self.transportHelp = transportHelp; self.phase = phase; self.phaseHelp = phaseHelp
        self.network = network; self.networkHelp = networkHelp; self.signalBars = signalBars
        self.saved = saved; self.savedHelp = savedHelp; self.processing = processing
        self.sourceGroups = sourceGroups; self.healthScore = healthScore; self.healthCaption = healthCaption
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
public struct MonitorSettingsSupportSource {
    let consent: Binding<Bool>
    let available: Bool
    let automaticHelp: String, unavailableHelp: String, deleteHelp: String, sourceHelp: String, termsHelp: String
    let sourceURL: URL?, termsURL: URL?
    let saveReport: (() -> URL?)?
    let deleteReports: (() -> Void)?
    let report: @MainActor @Sendable () -> AnyView
    let document: (@MainActor @Sendable (MonitorSettingsDocument, @escaping () -> Void) -> AnyView)?
    let shareReport: @MainActor @Sendable (URL) -> AnyView
    let model: MonitorSettingsSupportModel?
    let actions: MonitorSettingsSupportActions?
    let links: [MonitorSettingsSupportLink]
    let privacyDestination: MonitorSettingsBrowserDestination?
    let sourceDestination: MonitorSettingsBrowserDestination?
    let termsDestination: MonitorSettingsBrowserDestination?
    let reportAction: (() -> Void)?
    let reportTitle: String, reportActionTitle: String, diagnosticsHelp: String
    let supportEmail: String
    let deleteStoredReports: (() -> Void)?
    let deleteReportsHelp: String
    /// Legal pages the shared legal screen shows: bundled text opens in it, a web page keeps the
    /// host's browser destination. Nil keeps privacy and terms on those destinations only.
    let legal: MonitorLegalDocuments?
    public init(consent: Binding<Bool>, available: Bool, automaticHelp: String, unavailableHelp: String,
        deleteHelp: String, sourceHelp: String, termsHelp: String, sourceURL: URL?, termsURL: URL?,
        saveReport: @escaping () -> URL?, deleteReports: @escaping () -> Void,
        report: @escaping @MainActor @Sendable () -> AnyView,
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
        self.reportAction = nil; self.reportTitle = "Report a problem"; self.reportActionTitle = "Open"; self.diagnosticsHelp = ""
        self.supportEmail = supportEmail
        self.deleteStoredReports = nil; self.deleteReportsHelp = ""
        self.legal = nil
    }
    @MainActor public init(consent: Binding<Bool>, available: Bool, automaticHelp: String, unavailableHelp: String,
        sourceHelp: String, termsHelp: String, model: MonitorSettingsSupportModel, actions: MonitorSettingsSupportActions,
        links: [MonitorSettingsSupportLink], privacy: MonitorSettingsBrowserDestination?,
        source: MonitorSettingsBrowserDestination?, terms: MonitorSettingsBrowserDestination?,
        reportTitle: String, reportActionTitle: String, diagnosticsHelp: String,
        reportAction: (() -> Void)? = nil, report: @escaping @MainActor @Sendable () -> AnyView,
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
        self.reportAction = reportAction; self.reportTitle = reportTitle; self.reportActionTitle = reportActionTitle
        self.diagnosticsHelp = diagnosticsHelp
        self.supportEmail = supportEmail
        self.deleteStoredReports = deleteStoredReports; self.deleteReportsHelp = deleteReportsHelp
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
        links.map { link in
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

/// Values and coherent optional domains for the complete common settings owner.
@MainActor
public struct MonitorOperatorSettingsConfiguration<Looks: MonitorLookProvider> {
    let assist: MonitorAssistState<Looks>
    let safeArea: EdgeInsets
    let phase: String, sharingSubtitle: String
    let isLive: Bool
    let close: () -> Void, disconnect: () -> Void, feedback: () -> Void
    let link: MonitorSettingsLinkSource
    let sharing: MonitorSettingsSharingSource?
    let motion: MonitorSettingsMotionSource?
    let account: MonitorSettingsAccountSource?
    let cache: MonitorSettingsCacheSource?
    let support: MonitorSettingsSupportSource?
    let information: MonitorSettingsAppInformation?
    let recordConfirmation: Binding<Bool>, haptics: Binding<Bool>, keepAwake: Binding<Bool>
    let hdrDisplay: Binding<Bool>?, cacheOriginals: Binding<Bool>?
    let input: MonitorSettingsInputSource?
    let signalOptions: MonitorOperatorSignalOptions
    let cacheScopeHelp: String?
    let cacheConfirmationMessage: String?
    let hapticsHelp: String, keepAwakeHelp: String, hdrHelp: String, cacheHelp: String, clearHelp: String, exposureHelp: String
    let availableDisplay: Set<MonitorDisplayChrome.Section>?
    let lookLabel: String
    let lookCatalog: (@MainActor @Sendable () -> AnyView)?
    let assistSettings: @MainActor () -> AnyView

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
        availableAssist: Set<MonitorAssistSelection> = [.falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope, .peaking, .trafficLights]) {
        self.init(borrowedSafeArea: safeArea, phase: phase, isLive: isLive, sharingSubtitle: sharingSubtitle,
            close: close, disconnect: disconnect, feedback: feedback, link: link, sharing: sharing, motion: motion,
            account: account, cache: cache, support: support, information: information,
            recordConfirmation: recordConfirmation, haptics: haptics, keepAwake: keepAwake,
            hdrDisplay: hdrDisplay, cacheOriginals: cacheOriginals, hapticsHelp: hapticsHelp, keepAwakeHelp: keepAwakeHelp,
            hdrHelp: hdrHelp, cacheHelp: cacheHelp, clearHelp: clearHelp, exposureHelp: exposureHelp, availableDisplay: availableDisplay,
            assist: assist, stores: stores, falseColorLooks: falseColorLooks, palette: palette, operatorHaptics: operatorHaptics,
            transfer: transfer, clipByte: clipByte, lookLabel: lookLabel, lookCatalog: lookCatalog, availableAssist: availableAssist)
    }

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
        cacheScopeHelp: String? = nil, cacheConfirmationMessage: String? = nil) {
        self.assist = assist
        self.input = input; self.signalOptions = signalOptions
        self.cacheScopeHelp = cacheScopeHelp; self.cacheConfirmationMessage = cacheConfirmationMessage
        self.safeArea = borrowedSafeArea; self.phase = phase; self.isLive = isLive; self.sharingSubtitle = sharingSubtitle
        self.close = close; self.disconnect = disconnect; self.feedback = feedback; self.link = link
        self.sharing = sharing; self.motion = motion; self.account = account; self.cache = cache
        self.support = support; self.information = information
        self.recordConfirmation = recordConfirmation; self.haptics = haptics; self.keepAwake = keepAwake
        self.hdrDisplay = hdrDisplay; self.cacheOriginals = cacheOriginals
        self.hapticsHelp = hapticsHelp; self.keepAwakeHelp = keepAwakeHelp; self.hdrHelp = hdrHelp
        self.cacheHelp = cacheHelp; self.clearHelp = clearHelp; self.exposureHelp = exposureHelp
        self.availableDisplay = availableDisplay; self.lookLabel = lookLabel; self.lookCatalog = lookCatalog
        assistSettings = {
            AnyView(MonitorOperatorAssistSettings(assist: assist, stores: stores, looks: falseColorLooks,
                palette: palette, haptics: operatorHaptics, transfer: transfer, clipByte: clipByte, available: availableAssist, signalOptions: signalOptions))
        }
    }
}
#endif
