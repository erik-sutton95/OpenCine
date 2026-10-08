import Foundation
import OpenCineDJI

/// Queue admission is not a camera acknowledgement; zero is a valid sequence.
public enum DjiAppleCommandWrite: Equatable, Sendable {
    case queued(UInt16)
    case skipped
}

/// One control endpoint. Real transports and SIMULATED semantic peers use this same seam.
@MainActor
public struct DjiAppleControlEndpoint {
    public var writeBLE: @MainActor (Duml.Frame) -> Void
    public var writeDatalink: @MainActor (Duml.Frame) -> DjiAppleCommandWrite
    public var writeAdmittedDatalink:
        (@MainActor (Duml.Frame, DJICommandAdmission) -> DjiAppleCommandWrite)?
    public init(
        writeBLE: @escaping @MainActor (Duml.Frame) -> Void = { _ in },
        writeDatalink: @escaping @MainActor (Duml.Frame) -> DjiAppleCommandWrite = { _ in .skipped
        },
        writeAdmittedDatalink: (
            @MainActor (Duml.Frame, DJICommandAdmission) -> DjiAppleCommandWrite
        )? = nil
    ) {
        self.writeBLE = writeBLE
        self.writeDatalink = writeDatalink
        self.writeAdmittedDatalink = writeAdmittedDatalink
    }
}

/// Explicit host policy and source facts. The compatibility projection is never an observation.
public struct DjiAppleControlContext: Sendable {
    /// Current operator/borrow authority; OS write readiness remains the endpoint's fact.
    public var canTransmit: Bool
    public var browsingMedia: Bool
    public var controlsOnly: Bool
    public var reported: CameraStatus?
    /// Retains pre-extraction mailbox/busy policy until its later migration.
    public var legacySettlement: CameraStatus
    public init(
        canTransmit: Bool = false, browsingMedia: Bool = false, controlsOnly: Bool = false,
        reported: CameraStatus? = nil, legacySettlement: CameraStatus = .init()
    ) {
        self.canTransmit = canTransmit
        self.browsingMedia = browsingMedia
        self.controlsOnly = controlsOnly
        self.reported = reported
        self.legacySettlement = legacySettlement
    }
}

/// Production deadlines start at scheduling, on detached tasks. Tests advance a manual scheduler.
@MainActor
public struct DjiAppleExchangeTiming {
    public var now: () -> TimeInterval
    public var schedule: (Duration, @escaping @MainActor @Sendable () -> Void) -> Void
    public init(
        now: @escaping () -> TimeInterval,
        schedule: @escaping (Duration, @escaping @MainActor @Sendable () -> Void) -> Void
    ) {
        self.now = now
        self.schedule = schedule
    }
    public static var continuous: Self {
        .init(
            now: { Date.timeIntervalSinceReferenceDate },
            schedule: { delay, completion in
                Task.detached {
                    try? await Task.sleep(for: delay)
                    await completion()
                }
            })
    }
}

/// Actual packet routing and transaction lifetime, independent of UI or session recovery.
@MainActor
public final class DjiAppleControlExchange {
    public enum Event {
        case bleActivity, bleEnded
        case selfieFlip(Duml.Frame)
        case replyReceived
        case reply(Duml.Frame, request: SetRequest, late: Bool)
        case refused(name: String, message: String)
        case legacySettlementMatched(name: String)
        case timeoutEvidence(SetRequest, key: UInt16)
    }
    public enum Error: Swift.Error { case timeout, disconnected }
    public enum SetEvent {
        case stage(ControlWireEvent)
        case settled(Bool)
        case failed
    }

    public struct SetRequest {
        public let frame: Duml.Frame
        public let name: String
        public let expectation: DjiAppleControlExpectation?
        public let retransmits: Bool
        public let coalesce: Bool
        public let admission: DJICommandAdmission?
        public init(
            _ frame: Duml.Frame, name: String, expectation: DjiAppleControlExpectation? = nil,
            retransmits: Bool = true, coalesce: Bool = false, admission: DJICommandAdmission? = nil
        ) {
            self.frame = frame
            self.name = name
            self.expectation = expectation
            self.retransmits = retransmits
            self.coalesce = coalesce
            self.admission = admission
        }
    }

    /// Registration precedes writing. The captured operation owns cancellation and completion.
    @MainActor public final class Request {
        fileprivate let keys: Set<UInt16>
        fileprivate let generation: Int
        fileprivate weak var owner: DjiAppleControlExchange?
        private var result: Result<Duml.Frame, Swift.Error>?
        private var continuations: [CheckedContinuation<Duml.Frame, Swift.Error>] = []
        fileprivate init(keys: Set<UInt16>, owner: DjiAppleControlExchange) {
            self.keys = keys
            self.owner = owner
            generation = owner.generation
        }
        public func cancel() { owner?.cancel(self) }
        public func value() async throws -> Duml.Frame {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result {
                        continuation.resume(with: result)
                    } else {
                        self.continuations.append(continuation)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel() }
            }
        }
        fileprivate func finish(_ result: Result<Duml.Frame, Swift.Error>) {
            guard self.result == nil else { return }
            self.result = result
            for continuation in continuations { continuation.resume(with: result) }
            continuations.removeAll()
        }
    }

    private final class Send {
        let request: SetRequest
        let event: (SetEvent) -> Void
        var retransmitted = false
        init(_ request: SetRequest, event: @escaping (SetEvent) -> Void) {
            self.request = request
            self.event = event
        }
    }
    private struct LaunchState {
        let mailbox: CameraSetMailbox
        let inflight: Send?
        let pending: Send?
        let late: Send?
    }
    private final class PreparedLaunch {
        let registered: CameraSetMailbox
        let generation: Int
        var replies: [Duml.Frame] = []
        init(registered: CameraSetMailbox, generation: Int) {
            self.registered = registered
            self.generation = generation
        }
    }
    public private(set) var generation = 0
    public var endpoint: DjiAppleControlEndpoint
    private let context: () -> DjiAppleControlContext
    private let event: (Event) -> Void
    private let journal: (String) -> Void
    private let timing: DjiAppleExchangeTiming
    private var drain: Task<Void, Never>?
    private var drainIdentity: UUID?
    private var waiters: [UInt16: Request] = [:]
    private var pairingHold: [UInt16: Duml.Frame] = [:]
    private var inflight: [UInt16: Send] = [:]
    private var pending: [UInt16: Send] = [:]
    private var late: [UInt16: Send] = [:]
    private var scheduled: [UInt16: UUID] = [:]
    private var mailbox = CameraSetMailbox()
    /// Only the synchronous native admission decision is buffered. Entered predecessors and
    /// reentrant successors retain their own registrations; this creates no second queue.
    private var preparations: [UInt16: [PreparedLaunch]] = [:]

    public init(
        endpoint: DjiAppleControlEndpoint = .init(),
        timing: DjiAppleExchangeTiming = .continuous,
        context: @escaping () -> DjiAppleControlContext,
        event: @escaping (Event) -> Void = { _ in }, journal: @escaping (String) -> Void = { _ in }
    ) {
        self.endpoint = endpoint
        self.timing = timing
        self.context = context
        self.event = event
        self.journal = journal
    }

    public func startBLEDrain(_ frames: AsyncStream<Duml.Frame>) {
        stopBLEDrain()
        let identity = UUID()
        drainIdentity = identity
        drain = Task { [weak self] in
            for await frame in frames {
                guard let self, self.drainIdentity == identity else { return }
                self.event(.bleActivity)
                self.receive(frame)
            }
            guard let self, !Task.isCancelled, self.drainIdentity == identity else { return }
            self.failRequests(Error.disconnected)
            self.event(.bleEnded)
        }
    }
    public func stopBLEDrain() {
        drainIdentity = nil
        drain?.cancel()
        drain = nil
    }

    public func request(
        matching commands: [(UInt8, UInt8)], timeout: Duration = .seconds(8),
        consumeHold: Bool = true, send: (() -> Void)? = nil
    ) -> Request {
        let keys = Set(commands.map { Duml.opcodeKey(set: $0.0, cmd: $0.1) })
        let request = Request(keys: keys, owner: self)
        if consumeHold {
            for (set, cmd) in commands {
                if let frame = pairingHold.removeValue(forKey: Duml.opcodeKey(set: set, cmd: cmd)) {
                    request.finish(.success(frame))
                    return request
                }
            }
        } else {
            for key in keys { pairingHold[key] = nil }
        }
        for key in keys {
            if let old = waiters[key] { finish(old, .failure(Error.timeout)) }
        }
        for key in keys { waiters[key] = request }
        send?()
        timing.schedule(timeout) { [weak self, weak request] in
            guard let self, let request, self.current(request) else { return }
            self.finish(request, .failure(Error.timeout))
        }
        return request
    }
    private func current(_ request: Request) -> Bool {
        request.keys.contains { waiters[$0] === request }
    }
    private func finish(_ request: Request, _ result: Result<Duml.Frame, Swift.Error>) {
        for key in request.keys where waiters[key] === request { waiters[key] = nil }
        request.finish(result)
    }
    private func cancel(_ request: Request) {
        guard request.generation == generation, current(request) else { return }
        finish(request, .failure(CancellationError()))
    }
    public func failRequests(_ error: Swift.Error) {
        generation += 1
        let retired = waiters.values
        waiters.removeAll()
        for request in retired { request.finish(.failure(error)) }
    }

    /// SET sequence wins over an opcode GET; unsolicited Flip never consumes either.
    public func receive(_ frame: Duml.Frame) {
        if CameraParam.isSelfieFlipGetReply(
            set: frame.cmdSet, cmd: frame.cmdId, payload: frame.payload)
        {
            if !context().controlsOnly { event(.selfieFlip(frame)) }
            return
        }
        if !context().controlsOnly, frame.cmdSet == 7, frame.cmdId == 0x46,
            frame.flags == Duml.flagRequest
        {
            endpoint.writeBLE(Commands.pairApprovalAck(seq: frame.seq))
        }
        let key = Duml.opcodeKey(set: frame.cmdSet, cmd: frame.cmdId)
        let control = Duml.isLiveCameraControl(set: frame.cmdSet, cmd: frame.cmdId)
        if control, let preparation = preparations[key]?.last, preparation.generation == generation
        {
            preparation.replies.append(frame)
            return
        }
        if control && mailbox.isOpenSeq(key, seq: frame.seq) {
            routeACK(frame, key: key)
            return
        }
        if let waiter = waiters[key] {
            noteACK(frame, "match")
            finish(waiter, .success(frame))
            return
        }
        if control {
            routeACK(frame, key: key)
            return
        }
        if Duml.shouldHoldReply(set: frame.cmdSet, cmd: frame.cmdId) { pairingHold[key] = frame }
    }

    public func submit(_ request: SetRequest, event: @escaping (SetEvent) -> Void = { _ in }) {
        let policy = context()
        guard !Task.isCancelled, policy.canTransmit else {
            event(.stage(.notSent))
            event(.failed)
            event(.settled(false))
            return
        }
        if let admission = request.admission, !admission.isCurrent {
            event(.stage(.notSent))
            event(.failed)
            event(.settled(false))
            return
        }
        if policy.browsingMedia, request.frame.cmdSet == 2, request.frame.cmdId == 0x8e {
            event(.stage(.notSent))
            event(.settled(false))
            return
        }
        let key = Duml.opcodeKey(set: request.frame.cmdSet, cmd: request.frame.cmdId)
        pairingHold[key] = nil
        let send = Send(request, event: event)
        let previous = request.admission == nil ? nil : launchState(key)
        switch mailbox.offer(key: key, urgent: !request.coalesce, now: timing.now()) {
        case .coalescePending:
            pending[key]?.event(.stage(.notSent))
            pending[key] = send
            if inflight[key] == nil && late[key] == nil || CameraSetMailbox.pipelinesWhileOpen(key)
            {
                scheduleLaunch(key)
            }
        case .launch:
            if let previous {
                launchAdmitted(send, key: key, previous: previous)
            } else {
                late.removeValue(forKey: key)?.event(.settled(false))
                pending.removeValue(forKey: key)?.event(.stage(.notSent))
                launch(send, key: key)
            }
        }
    }
    private func launchState(_ key: UInt16) -> LaunchState {
        .init(mailbox: mailbox, inflight: inflight[key], pending: pending[key], late: late[key])
    }
    private func launch(_ send: Send, key: UInt16) {
        inflight[key] = nil
        mailbox.beginLaunch(key: key, now: timing.now())
        inflight[key] = send
        _ = transmit(send, key: key, kind: "send")
        send.event(.stage(.sent))
        watchEntered(send, key: key)
    }
    private func launchAdmitted(_ send: Send, key: UInt16, previous: LaunchState) {
        mailbox.beginLaunch(key: key, now: timing.now())
        inflight[key] = send
        pending[key] = nil
        late[key] = nil
        let preparation = PreparedLaunch(registered: mailbox, generation: generation)
        preparations[key, default: []].append(preparation)
        let write = transmit(send, key: key, kind: "send")
        let registered = preparations[key]?.last === preparation
        if case .skipped = write, registered, generation == preparation.generation,
            inflight[key] === send
        {
            let newerPending = pending[key]
            if mailbox.restore(
                key: key, from: previous.mailbox, ifUnchanged: preparation.registered,
                preservingPending: newerPending != nil)
            {
                inflight[key] = previous.inflight
                late[key] = previous.late
                if newerPending == nil { pending[key] = previous.pending }
            }
        }
        if let index = preparations[key]?.firstIndex(where: { $0 === preparation }) {
            preparations[key]?.remove(at: index)
            if preparations[key]?.isEmpty == true { preparations[key] = nil }
        }
        switch write {
        case .queued:
            previous.late?.event(.settled(false))
            previous.pending?.event(.stage(.notSent))
            send.event(.stage(.sent))
            watchEntered(send, key: key)
        case .skipped:
            send.event(.stage(.notSent))
            send.event(.failed)
            send.event(.settled(false))
        }
        if generation == preparation.generation {
            for reply in preparation.replies { receive(reply) }
        }
        if case .skipped = write, generation == preparation.generation, pending[key] != nil,
            inflight[key] == nil && late[key] == nil || CameraSetMailbox.pipelinesWhileOpen(key)
        {
            scheduleLaunch(key)
        }
    }
    private func watchEntered(_ send: Send, key: UInt16) {
        if send.request.retransmits {
            watch(send, key: key, delay: .milliseconds(300)) { owner, live in
                guard !live.retransmitted else { return }
                live.retransmitted = true
                _ = owner.transmit(live, key: key, kind: "retransmit")
            }
        }
        watch(send, key: key, delay: .seconds(2)) { owner, live in owner.timeout(live, key: key) }
    }
    private func transmit(_ send: Send, key: UInt16, kind: String) -> DjiAppleCommandWrite {
        guard context().canTransmit else { return .skipped }
        let epoch = generation
        let write: DjiAppleCommandWrite
        if let admission = send.request.admission {
            guard admission.isCurrent, let writeAdmitted = endpoint.writeAdmittedDatalink else {
                return .skipped
            }
            write = writeAdmitted(send.request.frame, admission)
        } else {
            write = endpoint.writeDatalink(send.request.frame)
        }
        if case .queued(let seq) = write,
            send.request.admission == nil || (generation == epoch && inflight[key] === send)
        {
            mailbox.noteTransmit(key: key, seq: seq)
        }
        let seq: String = if case .queued(let seq) = write { String(seq) } else { "0" }
        let frame = send.request.frame
        journal(
            "control: \(kind) \(send.request.name) \(opcode(frame)) seq=\(seq) flags=0x\(String(frame.flags, radix: 16)) payload=\(Duml.hex(frame.payload)) via=datalink"
        )
        return write
    }
    private func watch(
        _ send: Send, key: UInt16, delay: Duration,
        action: @escaping (DjiAppleControlExchange, Send) -> Void
    ) {
        timing.schedule(delay) { [weak self, weak send] in
            guard let self, let send, self.inflight[key] === send else { return }
            action(self, send)
        }
    }
    private func routeACK(_ frame: Duml.Frame, key: UInt16) {
        switch mailbox.decideAck(key: key, seq: frame.seq) {
        case .accept:
            event(.replyReceived)
            noteACK(frame, "inflight")
            if let send = inflight.removeValue(forKey: key) {
                finish(send, key: key, reply: frame, late: false)
            } else if let send = late.removeValue(forKey: key) {
                finish(send, key: key, reply: frame, late: true)
            }
        case .acceptLate:
            event(.replyReceived)
            noteACK(frame, "late")
            inflight[key] = nil
            if let send = late.removeValue(forKey: key) {
                finish(send, key: key, reply: frame, late: true)
            }
        case .dropSuperseded: noteACK(frame, "superseded")
        case .dropUnknown: noteACK(frame, "drop")
        }
    }
    private func finish(_ send: Send, key: UInt16, reply: Duml.Frame, late: Bool) {
        inflight[key] = nil
        self.late[key] = nil
        event(.reply(reply, request: send.request, late: late))
        let parsed = CameraReply.parse(reply.payload)
        let legacy =
            send.request.expectation?.matchesLegacySettlement(by: context().legacySettlement)
            == true
        let actual = send.request.expectation?.confirmedByReport(context().reported) == true
        let success = parsed.isSuccess || legacy
        send.event(.stage(parsed.isSuccess ? .acknowledged : actual ? .confirmed : .refused))
        if success {
            if !parsed.isSuccess {
                event(.legacySettlementMatched(name: send.request.name))
            }
        } else {
            event(.refused(name: send.request.name, message: parsed.message))
            send.event(.failed)
        }
        send.event(.settled(success))
        launchPending(key)
    }
    private func timeout(_ send: Send, key: UInt16) {
        inflight[key] = nil
        let matched =
            send.request.expectation?.matchesLegacySettlement(by: context().legacySettlement)
            == true
        let actual = send.request.expectation?.confirmedByReport(context().reported) == true
        send.event(.stage(actual ? .confirmed : .unconfirmed))
        let result = mailbox.timeout(key: key, subscribeMatches: matched)
        if CameraSetMailbox.timeoutImpliesUplinkFailure(result, key: key) {
            event(.timeoutEvidence(send.request, key: key))
        }
        switch result {
        case .subscribeMatches:
            event(.legacySettlementMatched(name: send.request.name))
            journal(
                "control: \(send.request.name) \(opcode(send.request.frame)) \u{2014} subscribe already matches"
            )
            send.event(.settled(true))
            launchPending(key)
        case .waitLate:
            late[key] = send
            journal(
                "control: \(send.request.name) \(opcode(send.request.frame)) \u{2014} awaiting late ACK"
            )
            send.event(.settled(true))
        case .launchPending:
            send.event(.settled(false))
            launchPending(key)
        case .idle: break
        }
    }
    private func launchPending(_ key: UInt16) {
        switch mailbox.pendingLaunch(key: key, now: timing.now()) {
        case .none: break
        case .immediate:
            if let next = pending.removeValue(forKey: key) {
                if next.request.admission != nil {
                    launchAdmitted(next, key: key, previous: launchState(key))
                } else {
                    launch(next, key: key)
                }
            }
        case .afterHold: scheduleLaunch(key)
        }
    }
    private func scheduleLaunch(_ key: UInt16) {
        guard scheduled[key] == nil else { return }
        let identity = UUID()
        scheduled[key] = identity
        let epoch = generation
        let remaining = mailbox.holdRemaining(key: key, now: timing.now())
        let delay: Duration =
            remaining > 0
            ? .milliseconds(Int((remaining * 1000).rounded(.up))) : .milliseconds(1)
        timing.schedule(delay) { [weak self] in
            guard let self, self.generation == epoch, self.scheduled[key] == identity else {
                return
            }
            self.scheduled[key] = nil
            let blocked = self.inflight[key] != nil && !CameraSetMailbox.pipelinesWhileOpen(key)
            guard !blocked else { return }
            self.launchPending(key)
        }
    }
    public func cancelSet(_ key: UInt16) {
        inflight[key] = nil
        pending[key] = nil
        late[key] = nil
        scheduled[key] = nil
        preparations[key] = nil
        mailbox.cancel(key)
    }
    /// Retirement completes local work before the caller resets/replaces its wire endpoint.
    /// It does not close a borrowed/owned transport or send any camera command.
    public func retire(_ error: Swift.Error, notifySets: Bool = false) {
        failRequests(error)
        let retired = Array(inflight.values) + Array(pending.values) + Array(late.values)
        inflight.removeAll()
        pending.removeAll()
        late.removeAll()
        scheduled.removeAll()
        preparations.removeAll()
        mailbox.reset()
        pairingHold.removeAll()
        if notifySets {
            var seen = Set<ObjectIdentifier>()
            for send in retired where seen.insert(ObjectIdentifier(send)).inserted {
                send.event(.failed)
                send.event(.settled(false))
            }
        }
    }
    public func settleFromReport() {
        let hits = late.filter {
            $0.value.request.expectation?.matchesLegacySettlement(by: context().legacySettlement)
                == true
        }
        for (key, send) in hits {
            late[key] = nil
            if mailbox.isAwaitingLate(key) { _ = mailbox.timeout(key: key, subscribeMatches: true) }
            event(.legacySettlementMatched(name: send.request.name))
            send.event(.settled(true))
        }
    }
    private func opcode(_ frame: Duml.Frame) -> String {
        String(format: "0x%02X/0x%02X", frame.cmdSet, frame.cmdId)
    }
    private func noteACK(_ frame: Duml.Frame, _ decision: String) {
        journal(
            "control: ack \(opcode(frame)) seq=\(frame.seq) flags=0x\(String(frame.flags, radix: 16)) payload=\(Duml.hex(frame.payload)) decision=\(decision) reply=\(Duml.isCommandReply(frame.flags))"
        )
    }
}

public enum DjiAppleControlExpectation: Sendable {
    case iso(IsoIndex)
    case shutter(Int)
    case ev(EvComp)
    case expo(ExpoMode)
    case focus(FocusMode)
    case wb(WhiteBalance)
    case format(VideoFormat)
    case color(ColorMode)
    case zoom(Double)
    /// Record telemetry lags the ACK by ~1 s; the settle window covers it.
    case recording(Bool)

    /// Missing telemetry and local compatibility pins cannot confirm a camera value.
    public func confirmedByReport(_ status: CameraStatus?) -> Bool {
        guard let status else { return false }
        if case .recording = self, !status.recordingReported { return false }
        return matchesLegacySettlement(by: status)
    }

    public func matchesLegacySettlement(by status: CameraStatus) -> Bool {
        switch self {
        case .recording(let active):
            return status.isRecording == active
        case .iso(let idx):
            if status.isoIndex == idx { return true }
            if let value = idx.isoValue, status.iso == value { return true }
            return false
        case .shutter(let denom):
            return status.shutterDenom == denom
        case .ev(let ev):
            return status.evComp == ev
        case .expo(let mode):
            return status.expoMode == mode
        case .focus(let mode):
            return status.focusMode == mode
        case .wb(let wb):
            guard status.whiteBalance?.mode == wb.mode else { return false }
            if wb.mode == .auto { return true }
            return status.whiteBalanceKelvin == wb.kelvin
                && status.whiteBalanceTint == wb.tint
        case .format(let format):
            if status.videoFormat == format { return true }
            return status.videoResolution == format.resolution
                && status.fps == format.frameRate.fps
        case .color(let mode):
            return status.colorMode == mode
        case .zoom(let factor):
            guard let live = status.zoomFactor else { return false }
            return CamFov.matches(live, factor)
        }
    }
}
