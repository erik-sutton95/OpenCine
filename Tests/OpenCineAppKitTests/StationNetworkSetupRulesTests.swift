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

    @Test func hostRoutesJoinTheSharedChooserInOneOrderWithSharedCopy() {
        let chooser = StationNetworkSetupRules.setupChooser(
            context: .camera(Self.camera),
            routes: [
                StationSetupRoute(.usb, actionTitle: "Connect now"),
                StationSetupRoute(.cameraAccessPoint, enabled: false),
                StationSetupRoute(.phoneHotspot),
                StationSetupRoute(.infrastructureNetwork, actionTitle: "Find on this network"),
                StationSetupRoute(.captureDevice),
            ],
            notice: AddSetupNotice(id: "names", message: "Allow names.", actionTitle: "Allow"))
        #expect(chooser.title == "How should this camera connect?")
        #expect(chooser.detail == "Body A · Model 1")
        #expect(
            chooser.options.map(\.id)
                == ["wifi", "phoneHotspot", "cameraAccessPoint", "usb", "captureDevice"])
        #expect(
            chooser.options.map(\.title)
                == ["Wi-Fi", "Hotspot", "Camera Wi-Fi", "USB-C", "HDMI capture"])
        #expect(
            chooser.options.map(\.actionTitle)
                == [
                    "Find on this network", "Choose hotspot", "Choose camera Wi-Fi",
                    "Connect now", "Choose HDMI capture",
                ])
        #expect(chooser.options.map(\.enabled) == [true, true, false, true, true])
        #expect(chooser.options[2].detail.hasPrefix("Added · BODY-AP\n"))
        #expect(chooser.notice?.id == "names")
        // The camera's Wi-Fi is on offer, so the footer does not claim it is already there.
        #expect(chooser.footer == "Switch setups from the camera’s chips at any time.")
        let words = [chooser.title, chooser.detail, chooser.footer ?? ""]
            + chooser.options.flatMap { [$0.title, $0.detail, $0.actionTitle] }
        #expect(!words.contains { $0.contains("\u{2014}") })
    }

    @Test func aCameraWithoutModelIsNamedAlone() {
        var camera = Self.camera
        camera.model = ""
        #expect(StationNetworkSetupRules.setupChooser(context: .camera(camera)).detail == "Body A")
    }

    @Test func stationHostsKeepWiFiAndHotspotOnly() {
        let chooser = StationNetworkSetupRules.setupChooser(context: .camera(Self.camera))
        #expect(chooser.options.map(\.actionTitle) == ["Choose Wi-Fi", "Choose hotspot"])
        #expect(chooser.notice == nil)
        #expect(
            chooser.footer
                == "Camera Wi-Fi stays available. Switch setups from the camera’s chips at any time.")
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
