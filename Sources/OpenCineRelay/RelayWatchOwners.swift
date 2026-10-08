import Foundation

/// Shared phone lifetime: state coalescing, source retirement, latest-frame admission, encode
/// reservations and acknowledged pacing. SDK message delivery and image encoding are bounded ports.
@MainActor public final class RelayWatchPhoneOwner<Codec: RelayWatchCodec, Preview: Sendable> {
    public typealias Send =
        @MainActor (
            Data, (@MainActor (Data) -> Void)?, (@MainActor () -> Void)?
        ) -> Void
    public var onCommand: (@MainActor (RelayWatchAction) -> Codec.Result)?
    public var onAdmittedCommand:
        (@MainActor (RelayWatchAction, RelayWatchCommandAdmission) -> Codec.Result)?
    public var onReachabilityChanged: (@MainActor () -> Void)?
    public var onSourceRetired: (@MainActor (UUID) -> Void)?
    public private(set) var source = UUID()
    public private(set) var isReady = false
    private var activated = false
    private var reachable = false
    private var lastSentState: Codec.State?
    private var stateSequence: UInt64 = 0
    private var commandSequence: UInt64 = 0
    private let commandGate = RelayWatchCommandGate()
    private let codec: Codec
    private let policy: RelayWatchPhonePolicy
    private var pacing: RelayPreviewPacing
    private let send: Send
    private let updateContext: @MainActor (Data) -> Void
    private let encode: @Sendable (Preview, RelayPreviewProfile) async -> Codec.Frame?
    private let now: @MainActor () -> TimeInterval
    private lazy var pump = RelayLatestPreviewPump<Preview>(
        maximumInFlight: policy.maximumInFlight,
        releasingOutstandingOnInvalidate: policy.releasesOutstandingOnRetirement,
        dispatch: { [weak self] in self?.encodePreview($0) })

    public init(
        codec: Codec, policy: RelayWatchPhonePolicy, now: @escaping @MainActor () -> TimeInterval,
        send: @escaping Send, updateContext: @escaping @MainActor (Data) -> Void = { _ in },
        encode: @escaping @Sendable (Preview, RelayPreviewProfile) async -> Codec.Frame?
    ) {
        self.codec = codec
        self.policy = policy
        pacing = RelayPreviewPacing(policy: policy.pacing)
        self.now = now
        self.send = send
        self.updateContext = updateContext
        self.encode = encode
    }

    public func acceptLink(activated: Bool, reachable: Bool) {
        let changed = self.activated != activated || self.reachable != reachable
        self.activated = activated
        self.reachable = reachable
        isReady = activated && reachable
        guard changed else { return }
        retireSource()
        onReachabilityChanged?()
    }

    /// A source is an actual producer lifetime, not a camera name or a recording state.
    public func retireSource() {
        source = UUID()
        stateSequence &+= 1
        lastSentState = nil
        pump.invalidate()
        commandGate.publish(source: source, active: activated && reachable)
        onSourceRetired?(source)
    }

    public func admits(_ admission: RelayWatchCommandAdmission) -> Bool {
        admission.belongs(to: commandGate) && admission.isCurrent
    }

    public func ingestState(_ state: Codec.State) {
        guard activated, lastSentState.map({ !codec.stateMatches(state, $0) }) ?? true,
            isReady || policy.stateDelivery == .contextAndMessage,
            let data = try? RelayWatchEnvelope.encode(state, kind: .state)
        else { return }
        lastSentState = state
        stateSequence &+= 1
        let sequence = stateSequence
        let window = source
        if policy.stateDelivery == .contextAndMessage { updateContext(data) }
        guard source == window, stateSequence == sequence, isReady else { return }
        send(
            data, nil,
            { [weak self] in
                guard let self, self.source == window, self.stateSequence == sequence else {
                    return
                }
                self.lastSentState = nil
            })
    }

    public func ingestPreview(_ preview: Preview) {
        guard isReady else { return }
        pump.offer(preview)
    }

    public func receiveCommand(_ data: Data, source window: UUID) -> Data {
        let unavailable = codec.result(accepted: false, isRecording: false, error: "unavailable")
        guard source == window, activated, reachable,
            (try? RelayWatchEnvelope.kind(data)) == .command,
            let command = try? RelayWatchEnvelope.decode(Codec.Command.self, from: data)
        else { return (try? RelayWatchEnvelope.encode(unavailable, kind: .result)) ?? Data() }
        let action = codec.action(command)
        let result: Codec.Result
        if action == .resume {
            let recording = lastSentState.map(codec.isRecording) ?? false
            retireSource()
            onReachabilityChanged?()
            result = codec.result(accepted: true, isRecording: recording, error: nil)
        } else {
            commandSequence &+= 1
            let admission = RelayWatchCommandAdmission(
                source: window, request: commandSequence, gate: commandGate)
            result = onAdmittedCommand?(action, admission) ?? onCommand?(action) ?? unavailable
        }
        return (try? RelayWatchEnvelope.encode(result, kind: .result)) ?? Data()
    }

    public func close() {
        activated = false
        reachable = false
        isReady = false
        retireSource()
    }

    private func encodePreview(_ item: RelayLatestPreviewPump<Preview>.Dispatch) {
        let window = source
        let profile = pacing.currentProfile
        let encode = self.encode
        Task { [weak self] in
            let frame = await encode(item.value, profile)
            guard let self else { return }
            guard self.source == window, self.pump.isActive(item.token), self.isReady,
                let frame, let data = try? RelayWatchEnvelope.encode(frame, kind: .frame)
            else {
                self.pump.complete(item.token)
                return
            }
            let sentAt = self.now()
            self.send(
                data,
                { [weak self] _ in
                    self?.finishPreview(item.token, source: window, sentAt: sentAt)
                },
                { [weak self] in
                    self?.finishPreview(item.token, source: window, sentAt: sentAt)
                })
        }
    }

    private func finishPreview(_ token: UInt64, source window: UUID, sentAt: TimeInterval) {
        guard pump.isActive(token) else {
            pump.complete(token)
            return
        }
        if source == window { pacing.acknowledge(roundTripSeconds: now() - sentAt) }
        pump.complete(token)
    }
}

/// Watch receiver lifetime. Replies and errors bind the command's exact local producer and
/// request, while the SDK bridge binds incoming messages before hopping onto the operator actor.
@MainActor public final class RelayWatchReceiverOwner<Codec: RelayWatchCodec> {
    public var onChange: (@MainActor () -> Void)?
    public var onSourceRetired: (@MainActor (UUID) -> Void)?
    public private(set) var source = UUID()
    public private(set) var presentationRevision: UInt64 = 0
    public private(set) var state: Codec.State?
    public private(set) var frame: Codec.Frame?
    public private(set) var isReachable = false
    public private(set) var isSendingCommand = false
    public private(set) var commandMessage: String?
    private var active = false
    private var sequence: UInt64 = 0
    private var pending: UInt64?
    private var expiry: (any RelayWatchScheduled)?
    private let codec: Codec
    private let deliver: RelayWatchPhoneOwner<Codec, Data>.Send
    private let scheduler: any RelayWatchScheduler
    private let commandTimeout: TimeInterval

    public init(
        codec: Codec, scheduler: any RelayWatchScheduler, commandTimeout: TimeInterval = 5,
        send: @escaping RelayWatchPhoneOwner<Codec, Data>.Send
    ) {
        precondition(commandTimeout.isFinite && commandTimeout > 0)
        self.codec = codec
        self.scheduler = scheduler
        self.commandTimeout = commandTimeout
        deliver = send
    }

    public func activate(reachable: Bool) {
        active = true
        retireWindow()
        isReachable = reachable
        onChange?()
    }
    public func acceptReachability(_ reachable: Bool, source window: UUID) {
        guard active, source == window, reachable != isReachable else { return }
        retireWindow()
        isReachable = reachable
        onChange?()
    }
    public func close() {
        active = false
        retireWindow()
        isReachable = false
        onChange?()
    }

    public func receive(_ data: Data, source window: UUID) {
        guard active, source == window, let kind = try? RelayWatchEnvelope.kind(data) else {
            return
        }
        switch kind {
        case .state:
            guard let decoded = try? RelayWatchEnvelope.decode(Codec.State.self, from: data) else {
                return
            }
            if state.map(codec.sourceFacts) != codec.sourceFacts(decoded) {
                retireWindow()
                if codec.sourceFacts(decoded).connection == .noCamera { frame = nil }
            }
            state = decoded
        case .frame:
            guard let decoded = try? RelayWatchEnvelope.decode(Codec.Frame.self, from: data) else {
                return
            }
            frame = decoded
        case .command, .result: return
        }
        onChange?()
    }

    public func send(_ action: RelayWatchAction) {
        guard active, isReachable, !isSendingCommand,
            let data = try? RelayWatchEnvelope.encode(codec.command(action), kind: .command)
        else { return }
        if action == .resume {
            deliver(data, { _ in }, {})
            return
        }
        sequence &+= 1
        let request = sequence
        let window = source
        pending = request
        isSendingCommand = true
        commandMessage = nil
        let timer = scheduler.schedule(after: commandTimeout) { [weak self] in
            self?.finish(request: request, source: window, reply: nil)
        }
        if pending == request { expiry = timer } else { timer.cancel() }
        onChange?()
        guard active, source == window, pending == request else { return }
        deliver(
            data,
            { [weak self] reply in
                self?.finish(request: request, source: window, reply: reply)
            }, { [weak self] in self?.finish(request: request, source: window, reply: nil) })
    }

    private func finish(request: UInt64, source window: UUID, reply: Data?) {
        guard active, source == window, pending == request else { return }
        pending = nil
        expiry?.cancel()
        expiry = nil
        isSendingCommand = false
        if let reply, (try? RelayWatchEnvelope.kind(reply)) == .result,
            let result = try? RelayWatchEnvelope.decode(Codec.Result.self, from: reply)
        {
            commandMessage = codec.error(result)
            if let state { self.state = codec.replacing(state, with: result) }
        }
        onChange?()
    }

    private func retireWindow() {
        source = UUID()
        presentationRevision &+= 1
        pending = nil
        expiry?.cancel()
        expiry = nil
        isSendingCommand = false
        commandMessage = nil
        onSourceRetired?(source)
    }
}
