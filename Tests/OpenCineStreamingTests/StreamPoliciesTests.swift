import Foundation
import OpenCineCore
import Testing

import OpenCineStreaming

@Suite struct StreamPoliciesTests {
    private func at(_ seconds: Double) -> MonotonicInstant { .zero + .milliseconds(Int(seconds * 1000)) }

    @Test func bitrateHoldsWhileTheQueueIsShort() {
        var p = StreamBitratePolicy(targetBps: 3_000_000, floorBps: 1_000_000)
        for second in 0..<30 { #expect(p.observe(queuedDuration: .milliseconds(400), at: at(Double(second))) == 3_000_000) }
    }

    @Test func bitrateStepsDownWhenQueueStaysBehindAndNeverBelowFloor() {
        var p = StreamBitratePolicy(targetBps: 3_000_000, floorBps: 1_000_000)
        var rates: [Int] = []
        for second in 0..<30 { rates.append(p.observe(queuedDuration: .milliseconds(1_500), at: at(Double(second)))) }
        #expect(rates[0] < 3_000_000)
        #expect(zip(rates, rates.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(rates.last == 1_000_000)
        #expect(rates.allSatisfy { $0 >= 1_000_000 })
    }

    @Test func bitrateRecoversSlowlyAfterClearNetwork() {
        var p = StreamBitratePolicy(targetBps: 3_000_000, floorBps: 1_000_000)
        for second in 0..<10 { _ = p.observe(queuedDuration: .seconds(2), at: at(Double(second))) }
        let low = p.observe(queuedDuration: .zero, at: at(10))
        #expect(p.observe(queuedDuration: .zero, at: at(19.9)) == low)
        let first = p.observe(queuedDuration: .zero, at: at(20))
        #expect(first > low)
        #expect(first - low <= 300_000)
        var rate = first
        for second in 21..<400 { rate = p.observe(queuedDuration: .zero, at: at(Double(second))) }
        #expect(rate == 3_000_000)
    }

    @Test func reconnectBacksOffThenGivesUpAtTwoMinutes() {
        var p = StreamReconnectPolicy(startedAt: .zero)
        #expect(p.decide(after: .closedByServer, at: at(1)) == .retry(after: .seconds(1)))
        #expect(p.decide(after: .closedByServer, at: at(2)) == .retry(after: .seconds(2)))
        #expect(p.decide(after: nil, at: at(5)) == .retry(after: .seconds(4)))
        #expect(p.decide(after: .protocolError, at: at(10)) == .retry(after: .seconds(8)))
        #expect(p.decide(after: nil, at: at(20)) == .retry(after: .seconds(15)))
        #expect(p.decide(after: nil, at: at(40)) == .retry(after: .seconds(15)))
        #expect(p.decide(after: .closedByServer, at: at(121)) == .giveUp)
    }

    @Test func refusalNeverRetries() {
        var p = StreamReconnectPolicy(startedAt: .zero)
        #expect(p.decide(after: .refused(reason: "NetStream.Publish.BadName"), at: at(1)) == .giveUp)
    }

    @Test func goingLiveResetsTheWindow() {
        var p = StreamReconnectPolicy(startedAt: .zero)
        _ = p.decide(after: nil, at: at(1))
        _ = p.decide(after: nil, at: at(3))
        p.wentLive()
        #expect(p.decide(after: nil, at: at(600)) == .retry(after: .seconds(1)))
        #expect(p.decide(after: nil, at: at(719)) == .retry(after: .seconds(2)))
        #expect(p.decide(after: nil, at: at(720)) == .giveUp)
    }
}
