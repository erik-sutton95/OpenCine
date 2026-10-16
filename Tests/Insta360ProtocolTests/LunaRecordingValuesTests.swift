import Insta360Protocol
import Testing

/// The colour names and shape groups every Luna host shows (twin of Kotlin LunaRecordingValuesTest).
struct LunaRecordingValuesTests {
    @Test func colourNamesAndNativeChoicesAreShared() {
        #expect(LunaColorMode.nativeRecordingChoices.map(\.label) == ["Standard", "I-Log", "Dolby Vision"])
        #expect(LunaColorMode.vivid.label == "Vivid")
        #expect(LunaColorMode.hdr.label == "HDR")
    }
}
