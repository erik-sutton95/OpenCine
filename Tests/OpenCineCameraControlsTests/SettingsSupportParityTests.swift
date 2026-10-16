#if os(iOS)
import MonitorPresentation
import OpenCineAppKit
import SwiftUI
import Testing

@testable import OpenCineCameraControls

/// A2-79 and A2-25: the shared support source owns the support email behind the report
/// unavailable alert and the delete-stored-reports row, so the System tab copy and rows
/// come from one place instead of a hard-coded Core address or a per-app gap.
@MainActor
@Suite struct SettingsSupportParityTests {
    private func source(supportEmail: String = "support@opencapture.org",
        deleteStoredReports: (() -> Void)? = nil, legal: MonitorLegalDocuments? = nil,
        report: @escaping () -> Void = {}) -> MonitorSettingsSupportSource {
        .init(consent: .constant(false), available: true, automaticHelp: "", unavailableHelp: "",
            sourceHelp: "", termsHelp: "", model: MonitorSettingsSupportModel(),
            actions: .init(identity: "SIMULATED", isCurrent: { true }, requiresInternetConsent: nil,
                makeReport: { throw CancellationError() }, prepareBrowser: { _ in nil }, open: { _ in false }),
            links: [], privacy: nil, source: nil, terms: nil, reportTitle: "Report a problem",
            reportActionTitle: "Open", diagnosticsHelp: "",
            report: report, shareReport: { _ in AnyView(EmptyView()) },
            deleteStoredReports: deleteStoredReports, supportEmail: supportEmail, legal: legal)
    }

    /// A2-26: bundled pages open in the shared legal screen; web pages keep the browser route.
    @Test func bundledLegalPagesOpenLocallyAndWebPagesKeepTheBrowserRoute() {
        let legal = MonitorLegalDocuments(wordmark: "SIMULATED", privacy: .text("P"),
            terms: .link(URL(string: "https://example.org/terms")!), licenses: .unavailable, notice: .text("N"))
        let configured = source(legal: legal)
        #expect(configured.showsLocally(.privacy))
        #expect(!configured.showsLocally(.terms))
        #expect(configured.showsLocally(.licenses), "A missing bundled page states that it is unavailable")
        #expect(configured.showsLocally(.notice))
        #expect(MonitorLegalPage.allCases.allSatisfy { !source().showsLocally($0) })
    }

    /// A2-24: every support form asks the app root to present the problem report, so the draft
    /// lives with the root and survives the monitor ending. The settings screen owns no report sheet.
    @Test func everySupportFormAsksTheHostRootToPresentTheReport() {
        var requested: [String] = []
        source(report: { requested.append("model") }).report()
        MonitorSettingsSupportSource(report: { requested.append("actions") }).report()
        MonitorSettingsSupportSource(consent: .constant(false), available: true, automaticHelp: "", unavailableHelp: "",
            deleteHelp: "", sourceHelp: "", termsHelp: "", sourceURL: nil, termsURL: nil,
            saveReport: { nil }, deleteReports: {}, report: { requested.append("closure") },
            document: { _, _ in AnyView(EmptyView()) }, shareReport: { _ in AnyView(EmptyView()) }).report()
        #expect(requested == ["model", "actions", "closure"])
    }

    @Test func theReportUnavailableAlertUsesTheConfiguredSupportEmail() {
        #expect(source(supportEmail: "support@openpocketcine.app").reportUnavailableMessage
            == "Email support@openpocketcine.app. You can save a report under Diagnostic options.")
        #expect(source().reportUnavailableMessage
            == "Email support@opencapture.org. You can save a report under Diagnostic options.")
    }

    @Test func theConfiguredSupportRowsExposeTheDeleteStoredReportsAction() {
        var deleted = false
        let actions = source(deleteStoredReports: { deleted = true })
            .configuredSupportActions(reportPreparing: false)
        let delete = actions.first { $0.id == "support.deleteReports" }
        #expect(delete?.title == "Delete saved feed reports")
        #expect(delete?.actionTitle == "Delete")
        #expect(delete?.accessibilityLabel == "Delete saved feed reports")
        delete?.action()
        #expect(deleted)
    }

    @Test func theConfiguredSupportRowsOmitTheDeleteRowWithoutTheAction() {
        let actions = source().configuredSupportActions(reportPreparing: false)
        #expect(!actions.contains { $0.id == "support.deleteReports" })
    }

    @Test func theShareDiagnosticsRowStillReflectsPreparation() {
        let idle = source(deleteStoredReports: {}).configuredSupportActions(reportPreparing: false)
        let busy = source(deleteStoredReports: {}).configuredSupportActions(reportPreparing: true)
        #expect(idle.first { $0.id == "support.diagnostics" }?.actionTitle == "Share")
        #expect(busy.first { $0.id == "support.diagnostics" }?.actionTitle == "Preparing…")
        #expect(busy.first { $0.id == "support.diagnostics" }?.enabled == false)
    }
}
#endif
