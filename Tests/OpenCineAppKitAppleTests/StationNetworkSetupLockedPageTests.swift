#if os(iOS)
import OpenCineAppKit
import OpenCineCore
import Testing

@testable import OpenCineAppKitApple

/// While cameras use the shared network the wizard shows one read-only page, as on Android.
@MainActor @Suite struct StationNetworkSetupLockedPageTests {
    @Test func lockedNetworkShowsTheSharedWiFiPageAndNeverScans() {
        var scans = 0
        var closes = 0
        let services = StationNetworkServices(
            savedNetworks: { [] }, currentSSID: { nil }, hotspotActive: { false },
            acceptsJoin: { _, _ in true })
        let view = StationNetworkSetupView(
            context: .multiview,
            brand: StationNetworkBrand(appName: "App", cameraFamily: "Cam", cameraNetworkPrefix: "cam"),
            services: services,
            scan: { _ in scans += 1 },
            save: { _ in true },
            close: { closes += 1 },
            lockedNetwork: StationNetwork(ssid: "Studio", password: "pw", hotspot: false))

        let page = view.lockedPage
        #expect(page?.title == "Shared Wi-Fi")
        #expect(page?.ssid == "Studio")
        #expect(page?.message == "Cameras are using this network. Remove them before changing it.")
        #expect(page?.allowsScan == false)
        page?.done(close: view.close)
        #expect(closes == 1)
        #expect(scans == 0)

        let open = StationNetworkSetupView(
            context: .multiview,
            brand: StationNetworkBrand(appName: "App", cameraFamily: "Cam", cameraNetworkPrefix: "cam"),
            services: services, scan: { _ in }, save: { _ in true }, close: {})
        #expect(open.lockedPage == nil)
    }
}
#endif
