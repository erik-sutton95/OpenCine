#if os(iOS)
import Observation
import OpenCineAppKit
import SwiftUI
import UIKit
import XCTest

@testable import OpenCineCameraControls

@MainActor @Observable private final class SupportIdentityInputs {
    var modelBacked = false
    @ObservationIgnored var probes: [UUID] = []
    @ObservationIgnored let model = MonitorSettingsSupportModel()
    var source: MonitorSettingsSupportSource {
        if modelBacked {
            return .init(consent: .constant(false), available: true, automaticHelp: "", unavailableHelp: "",
                sourceHelp: "", termsHelp: "", model: model,
                actions: .init(identity: "SIMULATED", isCurrent: { true }, requiresInternetConsent: nil,
                    makeReport: { throw CancellationError() }, prepareBrowser: { _ in nil }, open: { _ in false }),
                links: [], privacy: nil, source: nil, terms: nil, reportTitle: "", reportActionTitle: "",
                diagnosticsHelp: "", report: {}, shareReport: { _ in AnyView(EmptyView()) })
        }
        return .init(consent: .constant(false), available: true, automaticHelp: "", unavailableHelp: "",
            deleteHelp: "", sourceHelp: "", termsHelp: "", sourceURL: nil, termsURL: nil,
            saveReport: { nil }, deleteReports: {}, report: {},
            document: { _, _ in AnyView(EmptyView()) }, shareReport: { _ in AnyView(EmptyView()) })
    }
}
private struct SupportIdentityProbe: View {
    let inputs: SupportIdentityInputs
    @State private var identity = UUID()
    var body: some View {
        let _ = inputs.probes.append(identity)
        Color.gray
    }
}
private struct SupportIdentityHost: View {
    let inputs: SupportIdentityInputs
    var body: some View {
        SupportIdentityProbe(inputs: inputs).modifier(MonitorSettingsSupportPresentation(source: inputs.source))
    }
}

/// A2-80: switching between closure and model support must not replace the settings page.
@MainActor final class MonitorSettingsSupportIdentityTests: XCTestCase {
    func testSupportSourceKindChangeKeepsTheHostedPageState() async throws {
        let inputs = SupportIdentityInputs()
        let host = UIHostingController(rootView: SupportIdentityHost(inputs: inputs))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let first = try XCTUnwrap(inputs.probes.last)
        for modelBacked in [true, false, true] {
            inputs.modelBacked = modelBacked
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            XCTAssertEqual(inputs.probes.last, first, "modelBacked=\(modelBacked) replaced the page identity")
        }
        XCTAssertEqual(Set(inputs.probes), [first])
    }
}
#endif
