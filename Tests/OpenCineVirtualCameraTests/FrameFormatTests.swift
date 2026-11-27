import Testing

@testable import OpenCineVirtualCamera

@Test func unsupportedFormatDoesNotPartiallyChangeSelection() throws {
    var format = FrameFormat()
    do {
        try format.select(index: 1, durationNumerator: 1, durationTimescale: 24)
        Issue.record("Unsupported rate accepted")
    } catch {}
    #expect(format.index == 0)
    try format.select(index: nil, durationNumerator: 2, durationTimescale: 120)
    #expect(format.index == 1)
    do {
        try format.select(index: 5, durationNumerator: nil, durationTimescale: nil)
        Issue.record("Unsupported index accepted")
    } catch {}
    #expect(format.index == 1)
}
