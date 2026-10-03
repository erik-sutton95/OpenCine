#if os(iOS)
import SwiftUI

/// Optional queued-report presentation supplied by an app's report owner.
public struct MonitorReportStatus: Equatable, Sendable {
    public var label: String
    public var detail: String
    public var id: String?
    public init(label: String, detail: String, id: String? = nil) {
        self.label = label; self.detail = detail; self.id = id
    }
}

public struct MonitorSupportSettings: View {
    @Binding private var automaticReports: Bool
    private let available: Bool
    private let automaticHelp: String
    private let unavailableHelp: String
    private let status: MonitorReportStatus?
    private let discard: (() -> Void)?
    private let feedback: () -> Void
    private let report: () -> Void
    private let privacy: () -> Void
    public init(automaticReports: Binding<Bool>, available: Bool,
        automaticHelp: String, unavailableHelp: String, status: MonitorReportStatus? = nil,
        discard: (() -> Void)? = nil, feedback: @escaping () -> Void = {},
        report: @escaping () -> Void, privacy: @escaping () -> Void) {
        self._automaticReports = automaticReports; self.available = available
        self.automaticHelp = automaticHelp; self.unavailableHelp = unavailableHelp
        self.status = status; self.discard = discard; self.feedback = feedback
        self.report = report; self.privacy = privacy
    }
    public var body: some View {
        MonitorSettingsRowCard(title: "Help & Feedback") {
            MonitorSettingsInlineRow(title: "Report a problem",
                help: "Tell us what happened in the app. Choose whether to include technical details and an email for a reply.",
                showTopDivider: false) {
                MonitorSettingsActionPill(title: "Open", action: report)
                    .accessibilityIdentifier("support.report.open")
            }
            if let status {
                MonitorSettingsInlineRow(title: "Report status", help: status.detail) {
                    MonitorSettingsValueText(value: status.label)
                }
                if let id = status.id {
                    MonitorSettingsInlineRow(title: "Report ID", help: "Use this ID if you follow up.") {
                        MonitorSettingsValueText(value: id)
                    }
                }
                if let discard {
                    MonitorSettingsInlineRow(title: "Queued report", help: "Remove the unsent report from this phone.") {
                        MonitorSettingsActionPill(title: "Discard", action: discard)
                    }
                }
            }
            if available {
                MonitorSettingsSwitchInlineRow(title: "Automatic error reports", help: automaticHelp,
                    isOn: automaticReports, feedback: feedback) { automaticReports.toggle() }
            } else {
                MonitorSettingsInlineRow(title: "Automatic error reports", help: unavailableHelp) {
                    MonitorSettingsValueText(value: "Off")
                }
            }
            MonitorSettingsInlineRow(title: "Reporting Privacy",
                help: "What reports contain, retention, and how to request deletion.") {
                MonitorSettingsActionPill(title: "Read", action: privacy)
            }
        }
    }
}

/// Reporting IO and account policy stay with the host.
public struct MonitorDiagnosticSettings: View {
    @Binding private var expanded: Bool
    private let deleteHelp: String
    private let save: () -> Void
    private let delete: () -> Void
    public init(expanded: Binding<Bool>, deleteHelp: String,
        save: @escaping () -> Void, delete: @escaping () -> Void) {
        self._expanded = expanded; self.deleteHelp = deleteHelp; self.save = save; self.delete = delete
    }
    public var body: some View {
        MonitorSettingsRowCard {
            Button { expanded.toggle() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diagnostic options").font(MonitorTheme.font(13, weight: .semibold))
                        Text("Save or remove reports on this phone").font(MonitorTheme.font(11.5))
                            .foregroundStyle(MonitorTheme.muted)
                    }
                    Spacer()
                    (expanded ? MonitorIcon.chevronUp : MonitorIcon.chevronDown)
                        .frame(width: 20, height: 20).foregroundStyle(MonitorTheme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(MonitorTheme.text)
            .accessibilityIdentifier("support.diagnostics.disclosure")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                MonitorSettingsInlineRow(title: "Save diagnostic report", help: "Keep a copy or share it with support.") {
                    MonitorSettingsActionPill(title: "Save", action: save)
                }
                MonitorSettingsInlineRow(title: "Delete saved feed reports", help: deleteHelp) {
                    MonitorSettingsActionPill(title: "Delete", action: delete)
                }
            }
        }
    }
}
#endif
