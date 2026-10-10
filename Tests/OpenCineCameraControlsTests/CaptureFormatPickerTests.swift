import Testing
import OpenCineCameraVocabulary
@testable import OpenCineCameraControls

@Suite struct CaptureFormatPickerTests {
    private let fx = CaptureFormatGroup(id: "FX", title: "FX")
    private let dx = CaptureFormatGroup(id: "DX", title: "DX")
    private let four = CaptureFormatGroup(id: "4", title: "4K")
    private let six = CaptureFormatGroup(id: "6", title: "6K")
    private let wide = CaptureFormatGroup(id: "wide", title: "16:9")
    private let tall = CaptureFormatGroup(id: "tall", title: "9:16")

    private func choice(_ token: String, _ size: CaptureFormatGroup, _ rate: String,
        area: CaptureFormatGroup? = nil, aspect: CaptureFormatGroup? = nil, editable: Bool = true) -> CaptureFormatChoice<String> {
        CaptureFormatChoice(value: token, title: token, imageArea: area, aspect: aspect,
            resolution: size, frameRate: CaptureFormatGroup(id: rate, title: rate), isEditable: editable)
    }

    @Test func sparseTuplesNeverCreateAnUnsupportedRate() {
        let choices = [choice("4-60", four, "60p"), choice("6-25", six, "25p"), choice("4-25", four, "25p")]
        var state = CaptureFormatPickerState(choices: choices, current: "4-60")
        let next = state.select(imageArea: nil, aspect: nil, resolution: six, choices: choices, enabled: true)
        #expect(next?.value == "6-25")
        #expect(state.visibleChoices(choices).map(\.drumTitle) == ["25p"])
        #expect(state.selectDrum("60p", choices: choices, enabled: true) == nil)
        #expect(state.resolutions(choices) == [four, six])
    }

    @Test func groupingKeepsTheSelectedRateWhenAdvertisedElseTheFirstTuple() {
        let choices = [choice("4-25", four, "25p"), choice("6-50", six, "50p"), choice("6-25", six, "25p")]
        var state = CaptureFormatPickerState(choices: choices, current: "4-25")
        #expect(state.select(imageArea: nil, aspect: nil, resolution: six, choices: choices, enabled: true)?.value == "6-25")
        let only50 = Array(choices.prefix(2))
        state = CaptureFormatPickerState(choices: only50, current: "4-25")
        #expect(state.select(imageArea: nil, aspect: nil, resolution: six, choices: only50, enabled: true)?.value == "6-50")
    }

    @Test func identicalVisibleRatesDoNotEraseImageAreaOrExactPayload() {
        let choices = [choice("[FX] 4K · 25p", four, "25p", area: fx), choice("[DX] 4K · 25p", four, "25p", area: dx)]
        var state = CaptureFormatPickerState(choices: choices, current: choices[0].value)
        #expect(state.select(imageArea: dx, aspect: nil, resolution: four, choices: choices, enabled: true)?.value == choices[1].value)
        #expect(state.visibleChoices(choices) == [choices[1]])
    }

    @Test func imageAreaAndAspectStayIndependent() {
        let choices = [choice("FX-wide", four, "25p", area: fx, aspect: wide), choice("FX-tall", four, "25p", area: fx, aspect: tall), choice("DX-wide", four, "25p", area: dx, aspect: wide)]
        var state = CaptureFormatPickerState(choices: choices, current: "FX-wide")
        #expect(state.select(imageArea: fx, aspect: tall, resolution: four, choices: choices, enabled: true)?.value == "FX-tall")
        #expect(state.imageArea == fx)
        #expect(state.select(imageArea: dx, aspect: tall, resolution: four, choices: choices, enabled: true)?.value == "DX-wide")
        #expect(state.aspect == wide)
    }

    @Test func unclassifiedTokensAreRetainedWithoutInventedFacts() {
        let choices = [choice("4-25", four, "25p"), CaptureFormatChoice(value: "future exact token", title: "future exact token")]
        var state = CaptureFormatPickerState(choices: choices, current: "4-25")
        let next = state.select(imageArea: nil, aspect: nil, resolution: nil, choices: choices, enabled: true)
        #expect(next?.value == "future exact token")
        #expect(next?.imageArea == nil && next?.frameRate == nil && next?.resolution == nil)
        #expect(state.visibleChoices(choices).map(\.drumTitle) == ["future exact token"])
    }

    @Test func emptyReadOnlyAndRemovedChoicesNeverSubmit() {
        var empty = CaptureFormatPickerState<String>(choices: [], current: nil)
        #expect(empty.selectDrum("25p", choices: [], enabled: true) == nil)
        let choices = [choice("4-25", four, "25p"), choice("6-50", six, "50p")]
        var state = CaptureFormatPickerState(choices: choices, current: "4-25")
        #expect(state.select(imageArea: nil, aspect: nil, resolution: six, choices: choices, enabled: false) == nil)
        #expect(state.value == "4-25")
        #expect(state.select(imageArea: nil, aspect: nil, resolution: six, choices: [choices[0]], enabled: true) == nil)
        #expect(state.selectDrum("60p", choices: choices, enabled: true) == nil)
    }

    @Test func currentOnlyVocabularyPairStaysVisibleAndInert() {
        let current = VideoFormat(resolution: .p1080, frameRate: .fps240)
        let choices = CaptureVideoFormatChoices.make(available: [], current: current)
        #expect(choices.map(\.value) == [current])
        #expect(choices.first?.isEditable == false)
        var state = CaptureFormatPickerState(choices: choices, current: current)
        #expect(state.selectDrum("240p", choices: choices, enabled: true) == nil)
        #expect(state.visibleChoices(choices).map(\.drumTitle) == ["240p"])
    }

    @Test func ambiguousVisibleRatesRefuseEveryPayloadOrderAndCurrentIdentity() {
        let known = VideoFormat(resolution: .p4K, frameRate: .fps25)
        let unknown = VideoFormat(resolution: .p4K, frameRate: VideoFrameRate(rawValue: 0x25))
        let unique = VideoFormat(resolution: .p4K, frameRate: .fps60)
        #expect(known != unknown)
        #expect(known.frameRate.drumLabel == "25p" && unknown.frameRate.drumLabel == "25p")
        for advertised in [[known, unknown, unique], [unknown, known, unique]] {
            let choices = CaptureVideoFormatChoices.make(available: advertised, current: nil)
            for current in [known, unknown, unique] {
                var state = CaptureFormatPickerState(choices: choices, current: current)
                let before = state
                #expect(state.selectDrum("25p", choices: choices, enabled: true) == nil)
                #expect(state == before)
                if current == unique {
                    #expect(state.selectDrum("60p", choices: choices, enabled: true) == nil)
                    #expect(state == before)
                } else {
                    let picked = state.selectDrum("60p", choices: choices, enabled: true)
                    #expect(picked == choices.first { $0.value == unique })
                    #expect(state.value == unique)
                }
            }
        }
        let choices = CaptureVideoFormatChoices.make(available: [known, unique], current: unknown)
        var state = CaptureFormatPickerState(choices: choices, current: unknown)
        let before = state
        #expect(state.selectDrum("25p", choices: choices, enabled: true) == nil)
        #expect(state == before)
        #expect(state.selectDrum("60p", choices: choices, enabled: true) == choices.first { $0.value == unique })
        #expect(state.value == unique)
    }
}
