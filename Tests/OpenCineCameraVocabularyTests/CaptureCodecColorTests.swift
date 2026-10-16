import Testing

@testable import OpenCineCameraVocabulary

/// The codec and the colour of a recording are one popup. It lists only what the camera offers:
/// codec choices when the camera has them, and the colour (tone, gamma or profile) choices the
/// camera allows for the selected codec. Kotlin twin: `CaptureCodecColorTest`.
@Suite struct CaptureCodecColorTests {
    private typealias Choice = CaptureCodecColorChoice

    @Test func bothReadoutsOpenTheOnePopup() {
        #expect(CaptureCodecColorReadout.codec.popup == CaptureCodecColorReadout.color.popup)
        #expect(CaptureCodecColorReadout.allCases.count == 2)
    }

    @Test func aCameraWithoutCodecChoicesShowsColourOnly() {
        let choices = CaptureCodecColorChoices(
            colors: [Choice(id: "normal", label: "Normal"), Choice(id: "dlogm", label: "D-Log M")],
            selectedColor: "dlogm")
        #expect(!choices.showsCodec)
        #expect(choices.showsColor)
        #expect(choices.title == "COLOR")
        #expect(choices.selectedColorChoice?.label == "D-Log M")
    }

    @Test func aCameraWithCodecChoicesShowsBothSectionsInOrder() {
        let choices = CaptureCodecColorChoices(
            codecs: [Choice(id: "h265", label: "H.265 10-bit"), Choice(id: "prores", label: "ProRes 422 HQ")],
            selectedCodec: "h265",
            colors: [Choice(id: "sdr", label: "SDR"), Choice(id: "hlg", label: "HLG"), Choice(id: "nlog", label: "N-Log")],
            selectedColor: "nlog")
        #expect(choices.showsCodec && choices.showsColor)
        #expect(choices.title == "CODEC · COLOR")
        #expect(choices.sections == [.codec, .color])
        #expect(choices.selectedCodecChoice?.label == "H.265 10-bit")
        #expect(choices.colors.map(\.label) == ["SDR", "HLG", "N-Log"])
    }

    @Test func duplicateIdentitiesKeepTheCameraOrderAndTheFirstLabel() {
        let choices = CaptureCodecColorChoices(
            codecs: [Choice(id: "a", label: "A"), Choice(id: "b", label: "B"), Choice(id: "a", label: "A again")],
            colors: [])
        #expect(choices.codecs.map(\.label) == ["A", "B"])
        #expect(choices.sections == [.codec])
        #expect(choices.title == "CODEC")
    }

    @Test func anUnlistedSelectionIsUnknownNotTheFirstChoice() {
        let choices = CaptureCodecColorChoices(
            codecs: [Choice(id: "h265", label: "H.265")], selectedCodec: "r3d",
            colors: [Choice(id: "sdr", label: "SDR")], selectedColor: "hlg")
        #expect(choices.selectedCodec == nil)
        #expect(choices.selectedColor == nil)
    }

    @Test func aColourFixedByTheCodecIsShownButNotEditable() {
        let choices = CaptureCodecColorChoices(
            codecs: [Choice(id: "r3d", label: "R3D NE")], selectedCodec: "r3d",
            colors: [Choice(id: "log3g10", label: "Log3G10", isEditable: false)], selectedColor: "log3g10")
        #expect(choices.showsColor)
        #expect(!choices.colorEditable)
        #expect(choices.codecEditable)
    }

    @Test func nothingOfferedIsEmpty() {
        #expect(CaptureCodecColorChoices.empty.isEmpty)
        #expect(CaptureCodecColorChoices.empty.sections.isEmpty)
        #expect(!CaptureCodecColorChoices(colors: [Choice(id: "x", label: "X")]).isEmpty)
    }
}
