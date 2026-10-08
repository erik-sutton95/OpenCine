#if os(iOS)
import SwiftUI

/// Cache scope and IO stay with the host; this section owns common cache presentation.
public struct MonitorCacheSettings: View {
    private let cacheOriginals: Binding<Bool>?
    private let sizeLabel: String
    private let clearing: Bool
    private let cacheHelp: String
    private let scopeHelp: String
    private let clearHelp: String
    private let feedback: () -> Void
    private let clear: () -> Void
    private let clearSummary: String?

    public init(cacheOriginals: Binding<Bool>? = nil, sizeLabel: String, clearing: Bool = false,
        cacheHelp: String = "", scopeHelp: String, clearHelp: String,
        feedback: @escaping () -> Void = {}, clear: @escaping () -> Void, clearSummary: String? = nil) {
        self.cacheOriginals = cacheOriginals; self.sizeLabel = sizeLabel; self.clearing = clearing
        self.cacheHelp = cacheHelp; self.scopeHelp = scopeHelp; self.clearHelp = clearHelp
        self.feedback = feedback; self.clear = clear
        self.clearSummary = clearSummary
    }
    public var body: some View {
        MonitorSettingsRowCard {
            if let cacheOriginals {
                MonitorSettingsSwitchInlineRow(title: "Full Resolution Caching", help: cacheHelp,
                    showTopDivider: false, isOn: cacheOriginals.wrappedValue, feedback: feedback) {
                        cacheOriginals.wrappedValue.toggle()
                    }
            }
            MonitorSettingsInlineRow(title: "Local Media Cache", help: scopeHelp,
                showTopDivider: cacheOriginals != nil) {
                MonitorSettingsValueText(value: sizeLabel)
            }
            MonitorSettingsInlineRow(title: "Clear Cache", help: clearHelp) {
                Button(action: clear) {
                    Text(clearing ? "Clearing…" : "Clear").font(MonitorTheme.font(13, weight: .semibold))
                        .foregroundStyle(MonitorTheme.recording)
                }
                .buttonStyle(MonitorSettingsButtonStyle())
                .disabled(clearing)
            }
            if let clearSummary {
                Text(clearSummary).font(MonitorTheme.font(11.5)).foregroundStyle(MonitorTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("monitor.cache.result")
            }
        }
    }
}

/// App identity and protocol descriptions are content supplied by app composition.
public struct MonitorAppInformationSettings: View {
    private let theme: String
    private let protocolName: String
    private let version: String
    private let themeHelp: String
    private let protocolHelp: String
    private let versionHelp: String
    public init(theme: String, protocolName: String, version: String,
        themeHelp: String, protocolHelp: String, versionHelp: String) {
        self.theme = theme; self.protocolName = protocolName; self.version = version
        self.themeHelp = themeHelp; self.protocolHelp = protocolHelp; self.versionHelp = versionHelp
    }
    public var body: some View {
        MonitorSettingsRowCard(title: "App Information") {
            MonitorSettingsInlineRow(title: "Theme", help: themeHelp, showTopDivider: false) {
                MonitorSettingsValueText(value: theme)
            }
            MonitorSettingsInlineRow(title: "Protocol Implementation", help: protocolHelp) {
                MonitorSettingsValueText(value: protocolName)
            }
            MonitorSettingsInlineRow(title: "App Version", help: versionHelp) {
                MonitorSettingsValueText(value: version)
            }
        }
    }
}

/// Legal documents and external navigation remain app actions.
public struct MonitorProjectLegalSettings: View {
    private let sourceHelp: String
    private let termsHelp: String
    private let source: () -> Void
    private let privacy: () -> Void
    private let terms: () -> Void
    private let licenses: (() -> Void)?
    private let notice: (() -> Void)?
    public init(sourceHelp: String, termsHelp: String,
        source: @escaping () -> Void, privacy: @escaping () -> Void, terms: @escaping () -> Void,
        licenses: (() -> Void)? = nil, notice: (() -> Void)? = nil) {
        self.sourceHelp = sourceHelp; self.termsHelp = termsHelp; self.source = source
        self.privacy = privacy; self.terms = terms; self.licenses = licenses; self.notice = notice
    }
    public var body: some View {
        MonitorSettingsRowCard(title: "Project & Legal") {
            row("Source Code", help: sourceHelp, divider: false, action: source)
            row("Privacy", help: "What this app stores on this phone.", action: privacy)
            row("Terms", help: termsHelp, action: terms)
            if let licenses { row("Licenses", help: "Apache 2.0 and third-party notices.", action: licenses) }
            if let notice { row("NOTICE", help: "Attribution shipped with the app.", action: notice) }
        }
    }
    private func row(_ title: String, help: String, divider: Bool = true, action: @escaping () -> Void) -> some View {
        MonitorSettingsInlineRow(title: title, help: help, showTopDivider: divider) {
            MonitorSettingsActionPill(title: "Open", action: action)
                .accessibilityLabel(title == "Privacy" ? "Open Privacy Policy"
                    : title == "Terms" ? "Open Terms of Use" : "Open \(title)")
        }
    }
}
#endif
