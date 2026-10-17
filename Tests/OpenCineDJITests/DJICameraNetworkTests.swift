import OpenCineMedia
import Testing

@testable import OpenCineDJI

/// A6-10: the camera access point policy belongs to the integration. A DJI host keeps its camera
/// access points; the neutral redactor (every other host) redacts every SSID, including names
/// that merely contain a DJI family word. Kotlin twin: `dji.DjiCameraNetworkTest`.
@Suite struct DJICameraNetworkTests {
    @Test func djiHostKeepsCameraSSIDAndSoftAPAddress() {
        let out = DJICameraNetwork.redact("ssid=OsmoPocket3-A1B2 path=192.168.2.15 seq=42054")
        #expect(out.contains("OsmoPocket3-A1B2"))
        #expect(out.contains("192.168.2.15"))
        #expect(out.contains("seq=42054"))
        #expect(DJICameraNetwork.redact("ssid=CafeWiFi join=8.8.8.8") == "ssid=<redacted> join=<ip>")
    }

    @Test func accessPointDetection() {
        #expect(DJICameraNetwork.isAccessPoint("OsmoPocket3-AAAA"))
        #expect(DJICameraNetwork.isAccessPoint("Xtra-Muse-1"))
        #expect(!DJICameraNetwork.isAccessPoint("ErikHome"))
    }

    @Test(arguments: ["EdgeRouter-5G", "Pocket WiFi", "OsmoPocket3-A1B2", "NIKON_Z_8_12345678"])
    func neutralRedactorKeepsNoSSID(_ ssid: String) {
        let out = PrivacyRedactor.redact("ssid=\(ssid) seq=1")
        #expect(out.hasPrefix("ssid=<redacted>"))
        #expect(!out.contains(ssid.split(separator: " ")[0]))
    }
}
