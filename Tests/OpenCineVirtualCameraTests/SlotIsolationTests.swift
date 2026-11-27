import Foundation
import Testing

@testable import OpenCineVirtualCamera

/// Review focus: each driver slot owns one `FramePolicy`, so one module's failure stays in its slot.
@Suite struct SlotIsolationTests {
    final class Picture {}

    @Test func producerDeathOnlyAffectsItsSlot() {
        let a = FramePolicy<Picture>()
        let b = FramePolicy<Picture>()
        let producerA = UUID()
        let producerB = UUID()
        let epochA = a.claim(producerA)!
        let epochB = b.claim(producerB)!
        let now: UInt64 = 1_000_000_000
        #expect(a.offer(Picture(), producer: producerA, generation: epochA, timestamp: now, now: now))
        #expect(b.offer(Picture(), producer: producerB, generation: epochB, timestamp: now, now: now))
        a.retire(producerA)
        guard case .slate(.feedOff) = a.output(now: now + 1_000_000) else {
            Issue.record("dead producer's slot should show the feed-off slate")
            return
        }
        guard case .frame(_, repeated: false) = b.output(now: now + 1_000_000) else {
            Issue.record("the other slot should keep its picture")
            return
        }
    }

    @Test func sourceWithoutProducerShowsSlate() {
        guard case .slate(.feedOff) = FramePolicy<Picture>().output(now: 1) else {
            Issue.record("an input with no producer shows a slate")
            return
        }
    }

    @Test func staleProducerSlatesAfter500ms() {
        let slot = FramePolicy<Picture>()
        let producer = UUID()
        let epoch = slot.claim(producer)!
        let now: UInt64 = 1_000_000_000
        #expect(slot.offer(Picture(), producer: producer, generation: epoch, timestamp: now, now: now))
        guard case .slate(.noFeed) = slot.output(now: now + 500_000_001) else {
            Issue.record("a hung producer shows the waiting slate after 500 ms")
            return
        }
    }

    @Test func secondProducerIsRefused() {
        let slot = FramePolicy<Picture>()
        let first = UUID()
        let epoch = slot.claim(first)!
        #expect(slot.claim(UUID()) == nil)
        let now: UInt64 = 1_000_000_000
        #expect(slot.offer(Picture(), producer: first, generation: epoch, timestamp: now, now: now))
    }
}
