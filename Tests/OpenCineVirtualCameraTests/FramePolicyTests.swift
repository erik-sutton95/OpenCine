import Foundation
import Testing

@testable import OpenCineVirtualCamera

private final class Frame {
    let number: Int
    init(_ number: Int) { self.number = number }
}

@Test func latestFrameReplacesAndReleasesOldBuffer() throws {
    let policy = FramePolicy<Frame>()
    let producer = UUID()
    let epoch = try #require(policy.claim(producer))
    var first: Frame? = Frame(1)
    weak let released = first
    #expect(
        policy.offer(
            try #require(first), producer: producer, generation: epoch, timestamp: 1_000, now: 1_000
        ))
    first = nil
    #expect(released != nil)
    #expect(
        policy.offer(Frame(2), producer: producer, generation: epoch, timestamp: 2_000, now: 2_000))
    #expect(released == nil)
    guard case .frame(let frame, let repeated) = policy.output(now: 2_100) else {
        Issue.record("Missing newest frame")
        return
    }
    #expect(frame.number == 2)
    #expect(!repeated)
    #expect(policy.replaced == 1)
}

@Test func oneProducerAndRetiredGenerationCannotPublish() throws {
    let policy = FramePolicy<Frame>()
    let producer = UUID()
    let epoch = try #require(policy.claim(producer))
    #expect(policy.claim(UUID()) == nil)
    policy.retire(producer)
    let nextEpoch = try #require(policy.claim(producer))
    #expect(nextEpoch != epoch)
    #expect(
        !policy.offer(Frame(7), producer: producer, generation: epoch, timestamp: 100, now: 100))
    guard case .slate(.noFeed) = policy.output(now: 100) else {
        Issue.record("Retired frame escaped")
        return
    }
}

@Test func staleFrameBecomesSlateAndReleasesBuffer() throws {
    let policy = FramePolicy<Frame>()
    let producer = UUID()
    let epoch = try #require(policy.claim(producer))
    var frame: Frame? = Frame(1)
    weak let released = frame
    #expect(
        policy.offer(
            try #require(frame), producer: producer, generation: epoch, timestamp: 1_000_000_000,
            now: 1_000_000_000))
    frame = nil
    guard case .slate(.noFeed) = policy.output(now: 1_500_000_001) else {
        Issue.record("Stale picture froze")
        return
    }
    #expect(released == nil)
    policy.retire(producer)
    guard case .slate(.feedOff) = policy.output(now: 2_000_000_000) else {
        Issue.record("Producer exit did not turn feed off")
        return
    }
}

@Test func malformedOrReorderedTimestampsAreRejected() throws {
    let policy = FramePolicy<Frame>()
    let producer = UUID()
    let epoch = try #require(policy.claim(producer))
    #expect(
        policy.offer(
            Frame(1), producer: producer, generation: epoch, timestamp: 2_000_000_000,
            now: 2_000_000_000))
    #expect(
        !policy.offer(
            Frame(2), producer: producer, generation: epoch, timestamp: 1_999_999_999,
            now: 2_000_000_000))
    #expect(
        !policy.offer(
            Frame(3), producer: producer, generation: epoch, timestamp: 2_200_000_000,
            now: 2_000_000_000))
    #expect(
        !policy.offer(
            Frame(4), producer: producer, generation: epoch, timestamp: 1, now: 2_000_000_000))
    #expect(policy.rejected == 3)
}

@Test func repeatedFramesCountWithoutChangingMonotonicClock() throws {
    let policy = FramePolicy<Frame>()
    let producer = UUID()
    let epoch = try #require(policy.claim(producer))
    #expect(policy.offer(Frame(1), producer: producer, generation: epoch, timestamp: 10, now: 10))
    _ = policy.output(now: 10)
    guard case .frame(_, repeated: true) = policy.output(now: 20) else {
        Issue.record("Repeat was hidden")
        return
    }
    #expect(policy.repeats == 1)
    #expect(policy.outputTimestamp(now: 30) == 30)
    #expect(policy.outputTimestamp(now: 25) == 31)
}
