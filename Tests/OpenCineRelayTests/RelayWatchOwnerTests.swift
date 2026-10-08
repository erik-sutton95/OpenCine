import Foundation
import OpenCineRelay
import Testing

@MainActor @Suite struct RelayWatchOwnerTests {
    private func state(
        recording: Bool = false, feed: Bool = true,
        connection: WatchConnectionState = .connected, timecode: String = "01:02:03:04"
    ) -> WatchRelayState {
        .init(
            isRecording: recording, timecode: timecode, media: "42 GB", cameraBatteryPercent: 60,
            cameraName: "Same displayed name", connection: connection, feedLive: feed,
            isPhotography: true, feedAspectRatio: 1.5)
    }
    private var policy: RelayWatchPhonePolicy {
        .init(
            pacing: .init(
                profiles: [
                    .init(maximumWidth: 832, qualityPercent: 50),
                    .init(maximumWidth: 672, qualityPercent: 45),
                    .init(maximumWidth: 512, qualityPercent: 40),
                ], roundTripThresholds: [0.2, 0.35], initialIndex: 0,
                initialRoundTripHint: 0.15, maximumSampleSeconds: 5),
            stateDelivery: .reachableMessage, maximumInFlight: 1,
            releasesOutstandingOnRetirement: true)
    }

    @Test func commandExpiryAndOldReplyCannotFinishReplacementCommand() throws {
        let clock = Clock()
        let wire = Wire()
        let receiver = RelayWatchReceiverOwner(
            codec: WatchRelayCodec(), scheduler: clock,
            send: wire.send)
        receiver.activate(reachable: true)
        receiver.receive(
            try RelayWatchEnvelope.encode(state(), kind: .state), source: receiver.source)
        receiver.send(.toggleRecord)
        #expect(receiver.isSendingCommand && wire.calls.count == 1)
        clock.fire(0)
        #expect(!receiver.isSendingCommand)
        receiver.send(.toggleRecord)
        let reply = try RelayWatchEnvelope.encode(
            WatchCommandResult(accepted: true, isRecording: true, error: nil), kind: .result)
        wire.calls[0].reply?(reply)
        #expect(receiver.isSendingCommand && receiver.state?.isRecording == false)
        wire.calls[1].reply?(reply)
        #expect(!receiver.isSendingCommand && receiver.state?.isRecording == true)
        #expect(receiver.state?.isPhotography == true && receiver.state?.feedAspectRatio == 1.5)
        clock.fire(1)  // Deliberately deliver the canceled timer too.
        #expect(receiver.state?.isRecording == true)
    }

    @Test func reachabilityABAAndIdenticalNameCannotAdmitOldControlOrFrame() throws {
        let clock = Clock()
        let wire = Wire()
        let receiver = RelayWatchReceiverOwner(
            codec: WatchRelayCodec(), scheduler: clock,
            send: wire.send)
        receiver.activate(reachable: true)
        receiver.receive(
            try RelayWatchEnvelope.encode(state(), kind: .state), source: receiver.source)
        let old = receiver.source
        let revision = receiver.presentationRevision
        receiver.send(.capture)
        receiver.acceptReachability(false, source: old)
        receiver.acceptReachability(true, source: receiver.source)
        #expect(receiver.presentationRevision == revision + 2 && !receiver.isSendingCommand)
        receiver.send(.capture)
        wire.calls[0].reply?(
            try RelayWatchEnvelope.encode(
                WatchCommandResult(accepted: false, isRecording: true, error: "old refusal"),
                kind: .result))
        receiver.receive(
            try RelayWatchEnvelope.encode(
                WatchRelayFrame(jpeg: Data([8]), timecode: "OLD", isRecording: true), kind: .frame),
            source: old)
        #expect(
            receiver.isSendingCommand && receiver.commandMessage == nil && receiver.frame == nil)
        wire.calls[1].failure?()
        #expect(!receiver.isSendingCommand && receiver.state?.cameraName == "Same displayed name")
    }

    @Test func malformedMessagesAndCloseCannotChangeStateOrDispatchCommands() throws {
        let wire = Wire()
        let receiver = RelayWatchReceiverOwner(
            codec: WatchRelayCodec(), scheduler: Clock(), send: wire.send)
        receiver.activate(reachable: true)
        receiver.receive(
            try RelayWatchEnvelope.encode(state(), kind: .state), source: receiver.source)
        let current = receiver.state
        for malformed in [Data(), Data([0xff]), Data([1, 123]), Data([2, 0])] {
            receiver.receive(malformed, source: receiver.source)
        }
        #expect(receiver.state == current && receiver.frame == nil)
        let old = receiver.source
        receiver.close()
        receiver.receive(
            try RelayWatchEnvelope.encode(state(recording: true), kind: .state), source: old)
        receiver.send(.capture)
        receiver.send(.toggleRecord)
        #expect(wire.calls.isEmpty && !receiver.isReachable && receiver.state == current)
    }

    @Test func stateFailureOnlyReleasesTheExactCoalescingReservation() {
        let wire = Wire()
        let phone = RelayWatchPhoneOwner<WatchRelayCodec, Int>(
            codec: WatchRelayCodec(), policy: policy,
            now: { 10 }, send: wire.send, encode: { _, _ in nil })
        phone.acceptLink(activated: true, reachable: true)
        phone.ingestState(state())
        phone.ingestState(state(timecode: "later"))
        #expect(wire.calls.count == 1)
        phone.ingestState(state(recording: true))
        wire.calls[0].failure?()
        phone.ingestState(state(recording: true))
        #expect(wire.calls.count == 2)
        wire.calls[1].failure?()
        phone.ingestState(state(recording: true))
        #expect(wire.calls.count == 3)
        let old = phone.source
        phone.retireSource()
        phone.ingestState(state())
        wire.calls[2].failure?()
        phone.ingestState(state())
        #expect(phone.source != old && wire.calls.count == 4)
    }

    @Test func unavailablePhoneCannotExecuteLateCommandAndResumeKeepsExactEnvelope() throws {
        let wire = Wire()
        let phone = RelayWatchPhoneOwner<WatchRelayCodec, Int>(
            codec: WatchRelayCodec(), policy: policy,
            now: { 10 }, send: wire.send, encode: { _, _ in nil })
        var commands: [RelayWatchAction] = []
        phone.onCommand = { action in
            commands.append(action)
            return .init(accepted: true, isRecording: true, error: nil)
        }
        phone.acceptLink(activated: true, reachable: true)
        phone.ingestState(state(recording: true))
        let old = phone.source
        let command = try RelayWatchEnvelope.encode(WatchRelayCommand.toggleRecord, kind: .command)
        phone.retireSource()
        let refused = phone.receiveCommand(command, source: old)
        #expect(refused.first == 0x11 && commands.isEmpty)
        #expect(
            try RelayWatchEnvelope.decode(WatchCommandResult.self, from: refused).accepted == false)
        phone.ingestState(state(recording: true))
        let resume = phone.receiveCommand(
            try RelayWatchEnvelope.encode(WatchRelayCommand.resume, kind: .command),
            source: phone.source)
        #expect(try RelayWatchEnvelope.decode(WatchCommandResult.self, from: resume).isRecording)
        #expect(commands.isEmpty)
        phone.close()
        _ = phone.receiveCommand(command, source: phone.source)
        #expect(commands.isEmpty)
    }

    @Test func encodedPreviewAndDuplicateOldAckCannotSpendSuccessorCredit() async throws {
        let wire = Wire()
        let encoder = Encoder()
        let phone = RelayWatchPhoneOwner<WatchRelayCodec, Int>(
            codec: WatchRelayCodec(), policy: policy,
            now: { 10 }, send: wire.send,
            encode: { value, profile in await encoder.encode(value, profile: profile) })
        phone.acceptLink(activated: true, reachable: true)
        phone.ingestPreview(1)
        #expect(await settles { encoder.calls.count == 1 })
        phone.retireSource()
        phone.ingestPreview(2)
        #expect(await settles { encoder.calls.count == 2 })
        encoder.complete(0)
        #expect(await settles { encoder.completed.count == 1 })
        #expect(wire.calls.isEmpty)
        encoder.complete(1)
        #expect(await settles { wire.calls.count == 1 })
        phone.ingestPreview(3)
        phone.ingestPreview(4)
        wire.calls[0].reply?(Data())
        #expect(await settles { encoder.calls.count == 3 })
        #expect(encoder.calls.map(\.value) == [1, 2, 4])
        wire.calls[0].reply?(Data())
        phone.ingestPreview(5)
        for _ in 0..<20 { await Task.yield() }
        #expect(encoder.calls.count == 3)
        phone.close()
        encoder.complete(2)
        for _ in 0..<20 { await Task.yield() }
        #expect(wire.calls.count == 1)
    }

    @Test func suppliedCommandReceiptCapturesExactSourceAndLocalRequestWithoutChangingWire()
        throws
    {
        let wire = Wire()
        let phone = RelayWatchPhoneOwner<WatchRelayCodec, Int>(
            codec: WatchRelayCodec(), policy: policy, now: { 10 }, send: wire.send,
            encode: { _, _ in nil })
        let other = RelayWatchPhoneOwner<WatchRelayCodec, Int>(
            codec: WatchRelayCodec(), policy: policy, now: { 10 }, send: wire.send,
            encode: { _, _ in nil })
        var receipts: [RelayWatchCommandAdmission] = []
        var directCalls = 0
        phone.onCommand = { _ in
            directCalls += 1
            return .init(accepted: true, isRecording: false, error: nil)
        }
        phone.onAdmittedCommand = { action, receipt in
            #expect(action == .capture && receipt.isCurrent)
            receipts.append(receipt)
            return .init(accepted: true, isRecording: false, error: nil)
        }
        phone.acceptLink(activated: true, reachable: true)
        other.acceptLink(activated: true, reachable: true)
        let command = try RelayWatchEnvelope.encode(WatchRelayCommand.capture, kind: .command)
        for _ in 0..<2 {
            let result = phone.receiveCommand(command, source: phone.source)
            #expect(try RelayWatchEnvelope.decode(WatchCommandResult.self, from: result).accepted)
        }
        let first = try #require(receipts.first)
        #expect(first.source == phone.source && first.request == 1)
        #expect(receipts[1].request == 2 && phone.admits(first) && !other.admits(first))
        #expect(directCalls == 0)
        #expect(try RelayWatchEnvelope.decode(WatchRelayCommand.self, from: command) == .capture)
        phone.onAdmittedCommand = nil
        _ = phone.receiveCommand(command, source: phone.source)
        #expect(directCalls == 1)
    }

    @Test func reachabilityABAAndSourceReplacementRevokeCapturedNativePredicates() async throws {
        let phone = RelayWatchPhoneOwner<WatchRelayCodec, Int>(
            codec: WatchRelayCodec(), policy: policy, now: { 10 }, send: Wire().send,
            encode: { _, _ in nil })
        var receipt: RelayWatchCommandAdmission?
        phone.onAdmittedCommand = { _, value in
            receipt = value
            return .init(accepted: true, isRecording: false, error: nil)
        }
        let command = try RelayWatchEnvelope.encode(WatchRelayCommand.toggleRecord, kind: .command)
        phone.acceptLink(activated: true, reachable: true)
        _ = phone.receiveCommand(command, source: phone.source)
        let old = try #require(receipt)
        #expect(await Task.detached { old.isCurrent }.value)
        phone.acceptLink(activated: true, reachable: false)
        phone.acceptLink(activated: true, reachable: true)
        let retiredNativeCurrent = await Task.detached { old.isCurrent }.value
        #expect(!phone.admits(old) && !retiredNativeCurrent)
        _ = phone.receiveCommand(command, source: phone.source)
        let replacement = try #require(receipt)
        #expect(replacement.source != old.source && replacement.isCurrent)
        phone.retireSource()
        #expect(!replacement.isCurrent)
        _ = phone.receiveCommand(command, source: phone.source)
        let current = try #require(receipt)
        phone.close()
        #expect(!current.isCurrent)
        _ = phone.receiveCommand(command, source: phone.source)
        #expect(receipt?.request == current.request)
    }

    @Test func waitingDispatchRefusesButEnteredWorkCompletesAndCloseSendsNoCommand() async throws {
        for hold in [DispatchPort.Hold.beforeSend, .afterSend] {
            let phone = RelayWatchPhoneOwner<WatchRelayCodec, Int>(
                codec: WatchRelayCodec(), policy: policy, now: { 10 }, send: Wire().send,
                encode: { _, _ in nil })
            var receipt: RelayWatchCommandAdmission?
            phone.onAdmittedCommand = { _, value in
                receipt = value
                return .init(accepted: true, isRecording: false, error: nil)
            }
            phone.acceptLink(activated: true, reachable: true)
            _ = phone.receiveCommand(
                try RelayWatchEnvelope.encode(WatchRelayCommand.capture, kind: .command),
                source: phone.source)
            let captured = try #require(receipt)
            let native = DispatchPort(hold: hold)
            let dispatch = Task { await native.dispatch(captured) }
            await native.waitUntilHeld()
            let entered = await native.sends
            #expect(entered == (hold == .beforeSend ? 0 : 1))
            phone.retireSource()
            await native.release()
            #expect(await dispatch.value == (hold == .afterSend))
            #expect(await native.sends == entered)
            phone.close()
            #expect(await native.sends == entered)
            await native.directDispatch()
            #expect(await native.sends == entered + 1)
        }
    }

    private actor DispatchPort {
        enum Hold: Equatable, Sendable { case beforeSend, afterSend }
        let hold: Hold
        private(set) var sends = 0
        private var held = false
        private var waiting: CheckedContinuation<Void, Never>?
        private var entered: CheckedContinuation<Void, Never>?
        init(hold: Hold) { self.hold = hold }
        func dispatch(_ receipt: RelayWatchCommandAdmission) async -> Bool {
            if hold == .beforeSend { await pause() }
            guard receipt.isCurrent else { return false }
            sends += 1
            if hold == .afterSend { await pause() }
            return true
        }
        private func pause() async {
            await withCheckedContinuation {
                waiting = $0
                held = true
                entered?.resume()
                entered = nil
            }
        }
        func waitUntilHeld() async {
            if held { return }
            await withCheckedContinuation { entered = $0 }
        }
        func release() {
            waiting?.resume()
            waiting = nil
        }
        func directDispatch() { sends += 1 }
    }

    private func settles(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
    @MainActor private final class Wire {
        struct Call {
            let data: Data
            let reply: (@MainActor (Data) -> Void)?
            let failure: (@MainActor () -> Void)?
        }
        var calls: [Call] = []
        func send(
            _ data: Data, _ reply: (@MainActor (Data) -> Void)?, _ failure: (@MainActor () -> Void)?
        ) {
            calls.append(.init(data: data, reply: reply, failure: failure))
        }
    }
    @MainActor private final class Clock: RelayWatchScheduler {
        @MainActor final class Timer: RelayWatchScheduled {
            let action: @MainActor () -> Void
            var canceled = false
            init(_ action: @escaping @MainActor () -> Void) { self.action = action }
            func cancel() { canceled = true }
        }
        var timers: [Timer] = []
        func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
            -> any RelayWatchScheduled
        {
            let timer = Timer(action)
            timers.append(timer)
            return timer
        }
        func fire(_ index: Int) { timers[index].action() }
    }
    @MainActor private final class Encoder {
        struct Call {
            let value: Int
            let profile: RelayPreviewProfile
            let reply: CheckedContinuation<WatchRelayFrame?, Never>
        }
        var calls: [Call] = []
        var completed: [Int] = []
        func encode(_ value: Int, profile: RelayPreviewProfile) async -> WatchRelayFrame? {
            await withCheckedContinuation {
                calls.append(.init(value: value, profile: profile, reply: $0))
            }
        }
        func complete(_ index: Int) {
            completed.append(index)
            let call = calls[index]
            call.reply.resume(
                returning: .init(
                    jpeg: Data([UInt8(call.value)]), timecode: "\(call.value)", isRecording: false))
        }
    }
}
