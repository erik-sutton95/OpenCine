#if os(iOS)
import OpenCineAppKit
import OpenCineCore
import OpenCineHostedAccessibility
import OpenCineHostedTestSupport
import SwiftUI
import Testing
import UIKit
@testable import OpenCineAppKitApple

@MainActor @Suite struct StationNetworkSetupLockedPageTests {
    private let services = StationNetworkServices(
        savedNetworks: { [] }, currentSSID: { nil }, hotspotActive: { false },
        acceptsJoin: { _, _ in true })
    private let brand = StationNetworkBrand(appName: "App", cameraFamily: "Cam", cameraNetworkPrefix: "cam")

    @Test func lockedPageDoneCompletesAndTheSheetIsNamedByItsContext() async throws {
        #expect(await HostedAccessibility.awaitRuntime())
        var scans = 0
        var closes = 0
        var completes = 0
        let view = StationNetworkSetupView(
            context: .multiview, brand: brand, services: services,
            scan: { _ in scans += 1 }, save: { _ in true }, close: { closes += 1 },
            lockedNetwork: StationNetwork(ssid: "Studio", password: "pw", hotspot: false),
            complete: { completes += 1 })
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func labels() -> [String] {
            controller.view.layoutIfNeeded()
            return HostedAccessibility.leaves(in: window).compactMap(\.accessibilityLabel)
        }
        let shown = await HostedCondition.wait {
            let all = labels()
            return all.contains("Studio") && all.contains("Done")
                && all.contains("Cameras are using this network. Remove them before changing it.")
        }
        #expect(shown, "Shown: \(labels())")
        // The inline navigation title is not in a hosted window's accessibility tree, so the page
        // value that titles it is checked.
        #expect(view.lockedPage?.title == "Shared Wi-Fi")
        #expect(
            HostedAccessibility.elements(in: window).contains {
                HostedAccessibility.identifier($0) == StationNetworkSetupContext.multiview.identifier
            }, "The locked sheet is named by its wizard context")
        #expect(StationNetworkSetupContext.multiview.identifier == "multiview.networkSetup")

        let done = try #require(HostedAccessibility.leaves(in: window).first { $0.accessibilityLabel == "Done" })
        if !done.accessibilityActivate() { (done as? UIControl)?.sendActions(for: .touchUpInside) }
        #expect(await HostedCondition.wait { completes == 1 })
        #expect(closes == 0, "Done keeps the confirmed network: it completes, never cancels")
        #expect(scans == 0, "The locked page never scans")
    }

    @Test func withoutALockedNetworkTheWizardRuns() {
        let open = StationNetworkSetupView(
            context: .multiview, brand: brand, services: services, scan: { _ in },
            save: { _ in true }, close: {}, complete: {})
        #expect(open.lockedPage == nil)
    }
}
#endif
