import CoreGraphics
import Testing
@testable import OpenCineAppUITesting

struct PaintedCapacityMatchTests {
    private let control = CGRect(x: 100, y: 20, width: 120, height: 44)
    private let viewport = CGRect(x: 0, y: 0, width: 400, height: 900)

    private func token(_ value: String, x: CGFloat, y: CGFloat = 28) -> PaintedCapacityToken {
        PaintedCapacityToken(value: value, frame: CGRect(x: x, y: y, width: 28, height: 16))
    }

    @Test func compactCapacityAcceptsSeparateNumberAndUnitTokens() {
        let frame = PaintedCapacityMatch.frame(expected: "115GB", tokens: [
            token("115", x: 108), token("GB", x: 142),
        ], control: control, viewport: viewport)
        #expect(frame != nil)
    }

    @Test func spacedCapacityAcceptsSeparateNumberAndUnitTokens() {
        let frame = PaintedCapacityMatch.frame(expected: "114.89 GB", tokens: [
            token("114.89", x: 106), token("GB", x: 150),
        ], control: control, viewport: viewport)
        #expect(frame != nil)
    }

    @Test func oneJoinedTokenStillMatchesEveryWrittenForm() {
        for (expected, value) in [("115GB", "115GB"), ("115GB", "115 GB"), ("114.89 GB", "114.89GB")] {
            let frame = PaintedCapacityMatch.frame(expected: expected, tokens: [token(value, x: 106)],
                control: control, viewport: viewport)
            #expect(frame != nil, "\(value) must satisfy \(expected)")
        }
    }

    @Test func reversedOrOutsideTokensAreRejected() {
        // The number painted to the right of its unit is not the capacity label.
        #expect(PaintedCapacityMatch.frame(expected: "115GB", tokens: [
            token("115", x: 142), token("GB", x: 108),
        ], control: control, viewport: viewport) == nil)
        #expect(PaintedCapacityMatch.frame(expected: "115GB", tokens: [
            token("115", x: 108), token("GB", x: 260),
        ], control: control, viewport: viewport) == nil)
    }

    @Test func exactMatchMustBeFullyInsideTheControlAndAlone() {
        // A token whose midpoint is inside can still paint outside its control.
        let overflowing = PaintedCapacityToken(
            value: "115GB", frame: CGRect(x: 90, y: 28, width: 40, height: 16))
        #expect(PaintedCapacityMatch.frame(expected: "115GB", tokens: [overflowing],
            control: control, viewport: viewport) == nil)
        // An exact token beside another recognized token is not a clean capacity read.
        #expect(PaintedCapacityMatch.frame(expected: "115GB",
            tokens: [token("115GB", x: 106), token("1", x: 150)],
            control: control, viewport: viewport) == nil)
    }

    /// Z landscape (local run, 2026-10-20): Vision read the readout's card glyph as "G" left of
    /// "521 GB". The glyph is not capacity text; the capacity itself must still read in full.
    @Test func theLeadingGlyphReadAsALetterDoesNotHideTheCapacity() {
        let glyph = PaintedCapacityToken(value: "G", frame: CGRect(x: 101, y: 29, width: 9, height: 11))
        #expect(PaintedCapacityMatch.frame(expected: "521 GB", tokens: [glyph, token("521 GB", x: 118)],
            control: control, viewport: viewport) != nil)
        #expect(PaintedCapacityMatch.frame(expected: "115GB", tokens: [glyph, token("115", x: 118),
            token("GB", x: 150)], control: control, viewport: viewport) != nil)
        // Only a lone non-digit glyph before the text is set aside, never a digit or a trailing token.
        #expect(PaintedCapacityMatch.frame(expected: "521 GB", tokens: [
            PaintedCapacityToken(value: "1", frame: glyph.frame), token("521 GB", x: 118),
        ], control: control, viewport: viewport) == nil)
        #expect(PaintedCapacityMatch.frame(expected: "521 GB", tokens: [
            token("521 GB", x: 104), PaintedCapacityToken(value: "G", frame: CGRect(x: 190, y: 29, width: 9, height: 11)),
        ], control: control, viewport: viewport) == nil)
    }

    @Test func capacityPartsAreParsedFromCompactAndSpacedForms() {
        #expect(PaintedCapacityMatch.parts("115GB")?.number == "115")
        #expect(PaintedCapacityMatch.parts("115GB")?.unit == "GB")
        #expect(PaintedCapacityMatch.parts("114.89 GB")?.number == "114.89")
        #expect(PaintedCapacityMatch.parts("114.89 GB")?.unit == "GB")
        #expect(PaintedCapacityMatch.parts("no capacity") == nil)
    }
}
