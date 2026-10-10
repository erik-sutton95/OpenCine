import Testing

@testable import OpenCineCameraVocabulary
import OpenCineMedia

/// The DJI access point policy over the neutral redactor (Kotlin `dji.PrivacyRedactorTest`).
@Suite struct PrivacyRedactorTests {
    @Test func keepsCameraSSIDAndSoftAPAddress() {
        let raw = "ssid=OsmoPocket3-A1B2 path=192.168.2.15 seq=42054"
        let out = PrivacyRedactor.redact(raw)
        #expect(out.contains("OsmoPocket3-A1B2"))
        #expect(out.contains("192.168.2.15"))
        #expect(out.contains("seq=42054"))
    }

    @Test func cameraNetworkDetection() {
        #expect(PrivacyRedactor.isCameraNetwork("OsmoPocket3-AAAA"))
        #expect(PrivacyRedactor.isCameraNetwork("Xtra-Muse-1"))
        #expect(!PrivacyRedactor.isCameraNetwork("ErikHome"))
    }
}
