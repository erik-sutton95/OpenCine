import OpenCineAppKit
import OpenCineCore
import Testing

/// SIMULATED network names; the rules never talk to a radio.
@Suite struct StationNetworkRowsTests {
    private static let brand = StationNetworkBrand(
        appName: "Example Monitor", cameraFamily: "Example", cameraNetworkPrefix: "cam")
    private static func isCamera(_ ssid: String) -> Bool {
        StationNetworkSetupRules.isCameraNetwork(ssid, brand: brand, camera: nil, cameraSSIDs: ["BODY-AP"])
    }

    @Test func rowsListTheCurrentNetworkThenSavedThenNearbyEachOnce() {
        let rows = StationNetworkRows(
            current: "Studio",
            saved: ["Office", "Studio", "Office", "Venue"],
            nearby: ["Venue", "Lobby", "Studio", "Lobby", "Hall"],
            isCameraNetwork: Self.isCamera)
        #expect(rows.current == "Studio")
        #expect(rows.saved == ["Office", "Venue"])
        #expect(rows.nearby == ["Lobby", "Hall"])
        #expect(!rows.isEmpty)
    }

    @Test func nearbyDropsEmptyNamesAndCamerasOwnWiFi() {
        let rows = StationNetworkRows(
            current: nil, saved: ["", "cam_body_1"],
            nearby: ["", "  ", "CAM-Body-2", "BODY-AP", "Lobby"],
            isCameraNetwork: Self.isCamera)
        #expect(rows.saved.isEmpty)
        #expect(rows.nearby == ["Lobby"])
    }

    @Test func aCameraNetworkIsNeverTheCurrentRow() {
        let rows = StationNetworkRows(
            current: "cam_body_1", saved: [], nearby: [], isCameraNetwork: Self.isCamera)
        #expect(rows.current == nil)
        #expect(rows.isEmpty)
    }

    @Test func anEmptyListSaysWhy() {
        #expect(
            StationNetworkRows.emptyNote(host: .mac, locationDenied: true)
                == "Allow Location for this module in System Settings to show the Mac’s Wi-Fi.")
        #expect(
            StationNetworkRows.emptyNote(host: .mac, locationDenied: false)
                == "Type the name of the Wi-Fi the cameras should join.")
        #expect(
            StationNetworkRows.emptyNote(host: .iPhone, locationDenied: true)
                == "Type the name of the Wi-Fi the cameras should join.")
    }
}
