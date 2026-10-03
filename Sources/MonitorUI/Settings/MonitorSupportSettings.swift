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

/// A focused support action supplied by the host's real reporting or help workflow.
public struct MonitorSupportAction: Identifiable {
    public let id: String
    public let title: String
    public let help: String?
    public let actionTitle: String
    public let accessibilityLabel: String
    public let enabled: Bool
    public let action: () -> Void
    public init(id: String, title: String, help: String? = nil, actionTitle: String,
        accessibilityLabel: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.id = id; self.title = title; self.help = help; self.actionTitle = actionTitle
        self.accessibilityLabel = accessibilityLabel; self.enabled = enabled; self.action = action
    }
}

public struct MonitorSupportSettings: View {
    private let automaticReports: Binding<Bool>?
    private let available: Bool
    private let automaticHelp: String
    private let unavailableHelp: String
    private let status: MonitorReportStatus?
    private let discard: (() -> Void)?
    private let feedback: () -> Void
    private let report: () -> Void
    private let privacy: (() -> Void)?
    private let reportTitle: String
    private let reportHelp: String
    private let reportActionTitle: String
    private let actions: [MonitorSupportAction]
    public init(automaticReports: Binding<Bool>? = nil, available: Bool = false,
        automaticHelp: String = "", unavailableHelp: String = "", status: MonitorReportStatus? = nil,
        discard: (() -> Void)? = nil, feedback: @escaping () -> Void = {},
        reportTitle: String = "Report a problem",
        reportHelp: String = "Tell us what happened in the app. Choose whether to include technical details and an email for a reply.",
        reportActionTitle: String = "Open", actions: [MonitorSupportAction] = [],
        report: @escaping () -> Void, privacy: (() -> Void)? = nil) {
        self.automaticReports = automaticReports; self.available = available
        self.automaticHelp = automaticHelp; self.unavailableHelp = unavailableHelp
        self.status = status; self.discard = discard; self.feedback = feedback
        self.report = report; self.privacy = privacy
        self.reportTitle = reportTitle; self.reportHelp = reportHelp
        self.reportActionTitle = reportActionTitle; self.actions = actions
    }
    public var body: some View {
        MonitorSettingsRowCard(title: "Help & Feedback") {
            MonitorSettingsInlineRow(title: reportTitle, help: reportHelp,
                showTopDivider: false) {
                MonitorSettingsActionPill(title: reportActionTitle, action: report)
                    .accessibilityIdentifier("support.report.open")
                    .accessibilityLabel(reportTitle)
            }
            ForEach(actions) { action in
                MonitorSettingsInlineRow(title: action.title, help: action.help) {
                    MonitorSettingsActionPill(title: action.actionTitle, action: action.action)
                        .accessibilityIdentifier(action.id)
                        .accessibilityLabel(action.accessibilityLabel)
                        .disabled(!action.enabled)
                }
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
            if let automaticReports {
                if available {
                    MonitorSettingsSwitchInlineRow(title: "Automatic error reports", help: automaticHelp,
                        isOn: automaticReports.wrappedValue, feedback: feedback) {
                            automaticReports.wrappedValue.toggle()
                        }
                } else {
                    MonitorSettingsInlineRow(title: "Automatic error reports", help: unavailableHelp) {
                        MonitorSettingsValueText(value: "Off")
                    }
                }
            }
            if let privacy {
                MonitorSettingsInlineRow(title: "Reporting Privacy",
                    help: "What reports contain, retention, and how to request deletion.") {
                    MonitorSettingsActionPill(title: "Read", action: privacy)
                }
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
