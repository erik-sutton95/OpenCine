import OpenCineCameraVocabulary
import Testing

struct CaptureNativeISOCapabilitiesTests {
    @Test func absentDeclarationsRemainUnknown() {
        let value = CaptureNativeISOCapabilities()
        #expect(value.hop == nil)
        #expect(value.ceiling == nil)
        #expect(value != CaptureNativeISOCapabilities(hop: false, ceiling: false))
    }
    @Test func independentDeclarationsKeepTheirMeaning() {
        let value = CaptureNativeISOCapabilities(hop: true, ceiling: false)
        #expect(value.hop == true)
        #expect(value.ceiling == false)
    }
}
