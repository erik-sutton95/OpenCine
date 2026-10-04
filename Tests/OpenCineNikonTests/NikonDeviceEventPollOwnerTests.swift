import Foundation
import Testing

@testable import OpenCineNikon

@MainActor @Suite("SIMULATED Nikon GetEventEx poll owner")
struct NikonDeviceEventPollOwnerTests {
    @Test func exactCadenceAndSingleFlight() async {
        let link = PollLink()
        let runtime = NikonMonitorRuntime(link: PollLink())
        runtime.replaceLink(link)
        let pollAdmission1: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 1, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil, receive: { _ in Issue.record("Non-due poll published") })
        #expect(!pollAdmission1)
        #expect(link.polls == 0)
        let pollAdmission2: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 4, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil, receive: { _ in Issue.record("Retired poll published") })
        #expect(pollAdmission2)
        await link.waitUntilPolling()
        let pollAdmission3: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 8, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil, receive: { _ in Issue.record("Duplicate poll published") })
        #expect(!pollAdmission3)
        #expect(link.polls == 1)
        let retirement = runtime.retirePumps()
        link.release([])
        await retirement?.value
        #expect(link.finishedPolls == 1)
    }

    @Test func replacementOldDeferCannotClearSuccessor() async throws {
        let old = PollLink()
        let next = PollLink()
        let runtime = NikonMonitorRuntime(link: PollLink())
        runtime.replaceLink(old)
        var seen: [PTPEvent] = []
        let pollAdmission4: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 4, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil, receive: { seen.append($0) })
        #expect(pollAdmission4)
        await old.waitUntilPolling()
        let oldRetirement = runtime.retirePumps()
        runtime.replaceLink(next)
        let nextReceived = Signal()
        let pollAdmission5: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 4, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil,
            receive: {
                seen.append($0)
                nextReceived.fire()
            })
        #expect(pollAdmission5)
        await next.waitUntilPolling()
        old.release([try event(1)])
        await oldRetirement?.value
        #expect(seen.isEmpty)
        let pollAdmission6: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 8, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil, receive: { seen.append($0) })
        #expect(!pollAdmission6)
        #expect(next.polls == 1)
        let successorEvent = try event(2)
        next.release([successorEvent])
        await nextReceived.wait()
        await runtime.retirePumps()?.value
        #expect(seen == [successorEvent])
        #expect(next.finishedPolls == 1)
    }

    @Test func recoveryDropsBoundedOldResult() async throws {
        let link = PollLink()
        let runtime = NikonMonitorRuntime(link: PollLink())
        runtime.replaceLink(link)
        var seen: [PTPEvent] = []
        let pollAdmission7: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 4, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil, receive: { seen.append($0) })
        #expect(pollAdmission7)
        await link.waitUntilPolling()
        let retirement = runtime.retirePumps()
        runtime.recovering()
        link.release([try event(3)])
        await retirement?.value
        #expect(seen.isEmpty)
        #expect(link.finishedPolls == 1)
        let pollAdmission8: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 8, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil, receive: { seen.append($0) })
        #expect(!pollAdmission8)
    }

    @Test func receiveReplacementRetiresRemainingEvents() async throws {
        let link = PollLink()
        let runtime = NikonMonitorRuntime(link: PollLink())
        runtime.replaceLink(link)
        var seen: [PTPEvent] = []
        let received = Signal()
        let pollAdmission9: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 4, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil,
            receive: {
                seen.append($0)
                runtime.replaceLink(PollLink())
                received.fire()
            })
        #expect(pollAdmission9)
        await link.waitUntilPolling()
        let first = try event(4)
        link.release([first, try event(5)])
        await received.wait()
        await runtime.retirePumps()?.value
        #expect(seen == [first])
        #expect(link.finishedPolls == 1)
    }

    @Test func expensiveLinkUsesOriginalMeasuredStride() async {
        let link = PollLink()
        let runtime = NikonMonitorRuntime(link: PollLink())
        runtime.replaceLink(link)
        let stride = LiveViewPollPacing.eventPollStride(
            roundTripMilliseconds: 100, framePeriodMilliseconds: 33)
        #expect(stride > 4)
        let pollAdmission10: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 4, framePeriodMilliseconds: 33,
            roundTripMilliseconds: 100, receive: { _ in })
        #expect(!pollAdmission10)
        let pollAdmission11: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: stride, framePeriodMilliseconds: 33,
            roundTripMilliseconds: 100, receive: { _ in })
        #expect(pollAdmission11)
        await link.waitUntilPolling()
        let retirement = runtime.retirePumps()
        link.release([])
        await retirement?.value
        #expect(link.polls == 1)
    }

    @Test func borrowedRetirementDrainsPollWithoutClosingNativeLink() async {
        let link = PollLink()
        let runtime = NikonMonitorRuntime(link: PollLink(), ownsLink: false)
        runtime.replaceLink(link)
        let pollAdmission12: Bool = runtime.pollDeviceEventsAtSafePoint(
            frameCounter: 4, framePeriodMilliseconds: 33,
            roundTripMilliseconds: nil, receive: { _ in Issue.record("Retired loan published") })
        #expect(pollAdmission12)
        await link.waitUntilPolling()
        let retirement = runtime.retirePumps()
        #expect(link.finishedPolls == 0)
        link.release([])
        await retirement?.value
        #expect(link.finishedPolls == 1)
        #expect(link.closes == 0)
        #expect(link.liveStops == 0)
    }

    private func event(_ handle: UInt8) throws -> PTPEvent {
        try .init(payloadBytes: [0x02, 0x40, 0, 0, 0, 0, handle, 0, 0, 0])
    }
}

@MainActor private final class Signal {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?
    func fire() {
        fired = true
        waiter?.resume()
        waiter = nil
    }
    func wait() async { if !fired { await withCheckedContinuation { waiter = $0 } } }
}

@MainActor private final class PollLink: NikonMonitorLink, NikonDeviceEventPollLink {
    let serialNumber = "SIMULATED"
    private(set) var polls = 0
    private(set) var finishedPolls = 0
    private(set) var closes = 0
    private(set) var liveStops = 0
    private let started = Signal()
    private var reply: CheckedContinuation<[PTPEvent], Never>?
    func pollDeviceEvents() async -> [PTPEvent] {
        polls += 1
        let value = await withCheckedContinuation {
            reply = $0
            started.fire()
        }
        finishedPolls += 1
        return value
    }
    func waitUntilPolling() async { await started.wait() }
    func release(_ events: [PTPEvent]) {
        let captured = reply
        reply = nil
        captured?.resume(returning: events)
    }
    func supportsProperty(_ property: PTPPropertyCode) -> Bool { true }
    func configureLiveView(size: UInt8, compression: UInt8) async {}
    func startLiveView() async throws {}
    func stopLiveView() async { liveStops += 1 }
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
        throw NativeCameraSessionError.connectionClosed
    }
    func readLastCommandRoundTripMilliseconds() -> Double? { nil }
    func sendKeepAlive() async throws {}
    func nextEvent() async throws -> PTPEvent { throw NativeCameraSessionError.connectionClosed }
    func pollStillReleaseReadiness() async throws -> StillReleaseReadiness { .complete }
    func shutdown() async { closes += 1 }
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {}
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data { Data() }
    func startRecording() async throws {}
    func stopRecording() async throws {}
}
