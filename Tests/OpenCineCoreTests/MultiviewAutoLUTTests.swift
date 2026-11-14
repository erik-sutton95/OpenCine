import OpenCineCore
import Testing

@Suite struct MultiviewAutoLUTTests {
    @Test func captionFollowsTheReportedColorAndTheLookProfile() {
        let waiting = MultiviewAutoLUT(colorMode: nil, conversion: nil)
        #expect(waiting.caption(enabled: true, conversionLoaded: false) == "Waiting for camera color")
        let normal = MultiviewAutoLUT(colorMode: "Normal", conversion: nil)
        #expect(normal.caption(enabled: true, conversionLoaded: false) == "Auto · no conversion needed")
        let log = MultiviewAutoLUT(colorMode: "D-Log M", conversion: "D-Log M to Rec.709")
        #expect(log.caption(enabled: true, conversionLoaded: true) == "Auto · D-Log M to Rec.709")
        #expect(log.caption(enabled: true, conversionLoaded: false) == "LUT unavailable")
        #expect(
            log.caption(enabled: false, conversionLoaded: false) == "Auto · D-Log M to Rec.709",
            "A disabled LUT still names the conversion it would apply")
    }
}
