import Foundation
import OpenCineCore
import Testing

import OpenCineStreaming

@Suite struct StreamFramePacerTests {
    private func at(_ ms: Int) -> MonotonicInstant { .zero + .milliseconds(ms) }

    @Test func noPictureYetIsSlate() {
        let pacer = StreamFramePacer<Int>()
        #expect(pacer.frame(at: at(0)) == .slate)
    }

    @Test func slowSourceRepeatsFrames() {
        var pacer = StreamFramePacer<Int>()
        pacer.submit(1, at: at(0))
        #expect([0, 33, 66, 100].map { pacer.frame(at: at($0)) } == [.picture(1), .picture(1), .picture(1), .picture(1)])
    }

    @Test func fastSourceSkipsToTheNewest() {
        var pacer = StreamFramePacer<Int>()
        for (index, ms) in [0, 10, 20].enumerated() { pacer.submit(index, at: at(ms)) }
        #expect(pacer.frame(at: at(33)) == .picture(2))
    }

    @Test func lostSourceShowsSlateAfterTwoSeconds() {
        var pacer = StreamFramePacer<Int>()
        pacer.submit(7, at: at(1_000))
        #expect(pacer.frame(at: at(2_999)) == .picture(7))
        #expect(pacer.frame(at: at(3_000)) == .slate)
        pacer.submit(8, at: at(5_000))
        #expect(pacer.frame(at: at(5_033)) == .picture(8))
    }
}
