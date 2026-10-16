import OpenCineAppKit
import OpenCineCore
import Testing

/// SIMULATED saved camera; the rules never talk to a camera or a radio.
@Suite struct StationNetworkSetupRulesTests {
    static let brand = StationNetworkBrand(
        appName: "Example Monitor", cameraFamily: "Example", cameraNetworkPrefix: "cam")
    static let camera = SavedCamera(
        id: "one", integration: IntegrationID("test.station"), advertisedName: "Body A",
        model: "Model 1",
        routes: [
            SavedRoute(key: "ap", kind: .cameraAccessPoint, network: "BODY-AP", bluetooth: true),
            SavedRoute(key: "wifi", kind: .infrastructureNetwork, network: "studio", bluetooth: true),
        ])

    @Test func cameraChooserNamesTheCameraAndItsAddedSetups() {
        let chooser = StationNetworkSetupRules.setupChooser(context: .camera(Self.camera))
        #expect(chooser.title == "How should this camera connect?")
        #expect(chooser.detail == "Body A · Model 1")
        #expect(chooser.identifierPrefix == "addSetup")
        #expect(chooser.options.map(\.id) == ["wifi", "phoneHotspot"])
        #expect(chooser.options.map(\.kind) == [.infrastructureNetwork, .phoneHotspot])
        #expect(chooser.options.map(\.title) == ["Wi-Fi", "Hotspot"])
        #expect(chooser.options[0].detail.hasPrefix("Added · studio\n"))
        #expect(!chooser.options[1].detail.hasPrefix("Added"))
    }

    @Test func multiviewChooserHasNoCamera() {
        let chooser = StationNetworkSetupRules.setupChooser(context: .multiview)
        #expect(chooser.title == "How will your cameras connect?")
        #expect(chooser.detail.isEmpty)
        #expect(chooser.identifierPrefix == "multiview.setup")
        #expect(chooser.footer?.hasPrefix("Choose the shared network") == true)
    }

    @Test func cameraNetworksAreNeverOfferedAsShared() {
        func camera(_ ssid: String, _ saved: SavedCamera?) -> Bool {
            StationNetworkSetupRules.isCameraNetwork(
                ssid, brand: Self.brand, camera: saved, cameraSSIDs: ["OTHER-AP"])
        }
        #expect(camera("CAM-1234", nil))
        #expect(camera("BODY-AP", Self.camera))
        #expect(!camera("BODY-AP", nil))
        #expect(camera("OTHER-AP", nil))
        #expect(!camera("studio", Self.camera))
    }

    @Test func phoneNetworksAreTheIPhoneAndIPadNames() {
        #expect(
            StationNetworkSetupRules.phoneNetworks(["studio", "Ana’s iPhone", "IPAD 2", "Pixel"])
                == ["Ana’s iPhone", "IPAD 2"])
    }
}
