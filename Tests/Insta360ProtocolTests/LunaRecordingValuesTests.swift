import Insta360Protocol
import Testing

/// The colour names and shape groups every Luna host shows (twin of Kotlin LunaRecordingValuesTest).
struct LunaRecordingValuesTests {
    @Test func colourNamesAndNativeChoicesAreShared() {
        #expect(LunaColorMode.nativeRecordingChoices.map(\.label) == ["Standard", "I-Log", "Dolby Vision"])
        #expect(LunaColorMode.vivid.label == "Vivid")
        #expect(LunaColorMode.hdr.label == "HDR")
    }

    /// The colour drum opens on the reported colour, even one the native choices lack.
    @Test func theRecordingColourDrumKeepsTheReportedColour() {
        let choices = LunaColorMode.nativeRecordingChoices
        #expect(LunaColorMode.recordingDrum(current: .vivid) == choices + [.vivid])
        #expect(LunaColorMode.recordingDrum(current: .iLog) == choices)
        #expect(LunaColorMode.recordingDrum(current: nil) == choices)
    }
}
