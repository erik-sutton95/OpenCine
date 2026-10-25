import Foundation
import OpenCineCameraVocabulary
import OpenCineCore

/// The established Nikon link the monitor pumps. Production uses NativeCameraSession;
/// scripted links exercise exactly the same scheduler without a camera or UI framework.
@MainActor
public protocol NikonMonitorLink: NikonControlTransport {
    /// The camera's reported serial, or an empty string before it is identified.
    var serialNumber: String { get }
    /// Whether the body's advertisement permits polling this property.
    func supportsProperty(_ property: PTPPropertyCode) -> Bool
    /// Configures only the preview stream, never the card recording format.
    func configureLiveView(size: UInt8, compression: UInt8) async
    /// Starts the body's own live view and waits for its readiness.
    func startLiveView() async throws
    /// Ends the body's own live view without closing its control session.
    func stopLiveView() async
    /// One bounded, parsed camera frame.
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame
    /// Measured command RTT, unknown before the first sample.
    func readLastCommandRoundTripMilliseconds() -> Double?
    /// A side-effect-free idle command-channel ping.
    func sendKeepAlive() async throws
    /// The next pushed camera event; an idle timeout is benign.
    func nextEvent() async throws -> PTPEvent
    /// Whether a replaying stream still has a responsive body control channel.
    func pollStillReleaseReadiness() async throws -> StillReleaseReadiness
    /// Gracefully releases an owned session. Never stops recording.
    func shutdown() async
}

/// Optional real GetEventEx support; pushed event-socket draining remains a separate owner.
@MainActor public protocol NikonDeviceEventPollLink: AnyObject, Sendable {
    func pollDeviceEvents() async -> [PTPEvent]
}

/// Nikon monitor wire ownership: the common command queue and one control lifetime, retained
/// across replacement links. Its caller publishes images and chrome; this module sends and
/// confirms camera commands only at the pump's safe point.
@MainActor
public final class NikonMonitorRuntime: NikonControlDriver {
    /// The shell's common session. It is retained across recovery, with a new control epoch.
    public var session: NikonCameraSession { common }
    /// Last camera-authored control facts. Pending targets never enter this snapshot.
    public private(set) var nikonControlFacts: NikonControlFacts
    /// A readback from a completed common write, for a legacy display projection.
    public var onReadback: (PTPCameraPropertyWrite, Data?) -> Void = { _, _ in }
    /// A record command was accepted or refused. Confirmation still waits for observation.
    public var onRecordCommand: (Bool, Bool) -> Void = { _, _ in }
    /// An admitted record target now waits for the safe point; the legacy button can show it.
    public var onRecordQueued: (Bool) -> Void = { _ in }
    /// The common session closed; the app can retire its display projections.
    public var onClosed: (SessionCloseReason) -> Void = { _ in }
    /// Owned teardown, retained so the next connection can wait until the old channel closes.
    public private(set) var teardown: Task<Void, Never>?

    private var previewTask: Task<Void, Never>?
    private var previewPump: NikonLiveViewPump?
    private var previewGeneration = 0
    private var keepAliveTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var deviceEventPoll: (ticket: UUID, task: Task<Void, Never>)?
    private var startFailures = 0
    private var propertyBootstrap: NikonPropertyBootstrap?
    private var backgroundRetirement: Task<Void, Never>?

    private let serialNumber: String
    private let ownsLink: Bool
    private let backgroundSleep: @MainActor (Duration) async -> Void
    private let now: @Sendable () -> MonotonicInstant
    private lazy var common = NikonCameraSession(
        driver: self, serialNumber: serialNumber, now: now,
        onClose: { [weak self] reason in self?.closeLink(reason) })
    private var link: (any NikonMonitorLink)?
    private var generation = 0
    private var closed = false
    private var writes:
        [(
            write: PTPCameraPropertyWrite, operation: OperationID?,
            admission: NikonCommandAdmission?
        )] = []
    private var record: (start: Bool, operation: OperationID, admission: NikonCommandAdmission?)?
    private let recoveryAttempt = ConnectionAttemptID()

    /// `ownsLink` is false for a multicam loan; closing then retires only this monitor runtime.
    public init(
        link: any NikonMonitorLink, ownsLink: Bool = true,
        facts: NikonControlFacts = NikonControlFacts(),
        backgroundSleep:
            @escaping @MainActor (Duration) async -> Void = hostSleepUntilCancelled(for:),
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now
    ) {
        self.link = link
        serialNumber = link.serialNumber
        self.ownsLink = ownsLink
        self.backgroundSleep = backgroundSleep
        nikonControlFacts = facts
        self.now = now
    }

    /// Applies real camera observations, preserving the runtime's own link lifecycle.
    public func updateFacts(_ facts: NikonControlFacts) {
        guard !closed else { return }
        let connection = nikonControlFacts.connection
        // App projection resets during replacement are not new camera observations.
        if case .recovering = connection { return }
        if nikonControlFacts.holdsControl, !facts.holdsControl {
            dropCommands(preservingAdmitted: true)
        }
        // The link lifecycle and the header timecode are this runtime's own observations.
        let timecode = nikonControlFacts.timecode
        nikonControlFacts = facts
        nikonControlFacts.connection = connection
        nikonControlFacts.timecode = timecode
        common.refresh()
    }

    /// Retires queued commands and late callbacks while holding the monitor's reported values.
    public func recovering() {
        guard !closed else { return }
        generation += 1
        stopBackgroundTasks()
        dropCommands()
        link = nil
        propertyBootstrap = nil
        nikonControlFacts.connection = .recovering(recoveryAttempt)
        nikonControlFacts.liveViewReady = false
        nikonControlFacts.timecode = nil
        common.refresh()
    }

    /// A replacement link belongs to the same monitor. Returning to ready advances its epoch.
    public func replaceLink(_ link: any NikonMonitorLink) {
        guard !closed else { return }
        generation += 1
        stopBackgroundTasks()
        self.link = link
        propertyBootstrap = nil
        nikonControlFacts.connection = .ready
        common.refresh()
    }

    /// Whether there is interactive common work waiting for a wire safe point.
    public var hasQueuedCommands: Bool { record != nil || !writes.isEmpty }

    /// Sends at most one interactive operation at the pump's safe point, record before writes.
    /// Returns true when maintenance should yield this turn. Late results from a replaced link
    /// cannot publish into its successor, even when an old transport finishes after retirement.
    @discardableResult
    public func serviceControlSafePoint(allowWrites: Bool = true) async -> Bool {
        guard !closed, let link else { return false }
        let current = generation
        if let request = record {
            record = nil
            if let admission = request.admission, !admits(admission) {
                common.commandAdmissionExpired(request.operation)
                onRecordCommand(request.start, false)
                return true
            }
            common.operationSent(request.operation)
            do {
                if let admission = request.admission {
                    if request.start {
                        try await link.startRecording(admission: admission)
                    } else {
                        try await link.stopRecording(admission: admission)
                    }
                } else if request.start {
                    try await link.startRecording()
                } else {
                    try await link.stopRecording()
                }
                guard generation == current, !closed else { return true }
                common.recordAccepted(request.operation)
                onRecordCommand(request.start, true)
            } catch {
                guard generation == current, !closed else { return true }
                if case NativeCameraSessionError.commandAuthorityExpired = error {
                    common.commandAdmissionExpired(request.operation)
                } else {
                    common.commandFailed(
                        request.operation,
                        cameraRefused: NativeCameraSessionError.isCameraRefusal(error))
                }
                onRecordCommand(request.start, false)
            }
            return true
        }
        guard allowWrites, !writes.isEmpty else { return false }
        let (write, operation, admission) = writes.removeFirst()
        if let admission, !admits(admission) {
            if let operation {
                common.commandAdmissionExpired(operation)
                writes.removeAll { $0.operation == operation }
            }
            return true
        }
        // Movie exposure can wait behind another safe-point operation. The body's selector,
        // shutter convention, lock and advertised domain must still admit it before wire I/O.
        // Legacy writes retain their existing native admission path.
        if let operation, case .set(let value) = common.receipt(of: operation)?.intent,
            value.key == .shutter || value.key == .aperture
        {
            let descriptor = common.refresh().capabilities[value.key]
            guard descriptor?.availability == .available, descriptor?.accepts(value) == true else {
                common.operationDropped(operation)
                writes.removeAll { $0.operation == operation }
                return true
            }
        }
        if let operation { common.operationSent(operation) }
        do {
            if let admission {
                try await link.writeCameraProperty(write, admission: admission)
            } else {
                try await link.writeCameraProperty(write)
            }
            let readback = try? await link.readCameraProperty(write.property)
            guard generation == current, !closed else { return true }
            if let readback {
                nikonControlFacts.reported = nikonControlFacts.reported.applying(
                    property: write.property, data: readback)
            }
            if let operation { common.writeLanded(operation, write: write, readback: readback) }
            common.refresh()
            onReadback(write, readback)
        } catch {
            guard generation == current, !closed else { return true }
            if let operation {
                if case NativeCameraSessionError.commandAuthorityExpired = error {
                    common.commandAdmissionExpired(operation)
                    writes.removeAll { $0.operation == operation }
                } else {
                    common.commandFailed(
                        operation, cameraRefused: NativeCameraSessionError.isCameraRefusal(error))
                }
            }
            onReadback(write, nil)
        }
        return true
    }

    /// Performs camera reads in selector-first order before the first live-view start.
    public func bootstrapProperties(
        initial: PTPCameraPropertySnapshot,
        receive: @escaping @MainActor (NikonBootstrapObservation) -> Void
    ) async {
        guard !closed, let link = link as? any NikonBootstrapLink else { return }
        let current = generation
        let bootstrap = NikonPropertyBootstrap(link: link)
        propertyBootstrap = bootstrap
        await bootstrap.run(
            initial: initial, isCurrent: { !self.closed && self.generation == current },
            receive: receive)
    }

    /// Consumes a staged clock change only after an actual frame header reports recording state.
    public func consumeStagedClockSync(recording: Bool?) async {
        await propertyBootstrap?.consumeStagedClock(recording: recording)
    }

    /// Lifecycle decisions from the integration's bounded preview recovery loop.
    public enum PreviewEvent: Sendable {
        case opening
        case restart(reason: String, delay: Double)
        case reconnect(reason: String, delay: Double)
        case reconnectReady
        case recover(reason: String)
    }

    /// Starts the sole Nikon frame/header pump. The app consumes decoded presentation values
    /// and supplies its optional Nikon-domain safe-point work; wire cadence stays here.
    public func startPreview(
        bootstrap: @escaping @MainActor () async -> Void,
        demand: @escaping @MainActor () -> NikonPreviewDemand,
        consume: @escaping @MainActor (PTPLiveViewFrame, NikonLiveViewPump.Delivery) async -> Bool,
        safePoint: @escaping @MainActor (Int, Bool) async -> Void,
        applied: @escaping @MainActor (NikonPreviewDemand) -> Void,
        resetCadence: @escaping @MainActor () -> Void,
        health: @escaping @MainActor (NikonLiveViewPump.Health) -> Void,
        event: @escaping @MainActor (PreviewEvent) -> Void
    ) {
        guard !closed, let link else { return }
        let retirement = stopPreview()
        let current = previewGeneration
        let pump = NikonLiveViewPump(link: link)
        previewPump = pump
        previewTask = Task { [weak self] in
            await retirement?.value
            guard let self, previewIsCurrent(current) else { return }
            // Kept-link wire operations live in an unstructured child: retiring the scheduler
            // may cancel a delay, but must never interrupt the native transaction socket.
            let initialReads = Task { await bootstrap() }
            await initialReads.value
            guard previewIsCurrent(current) else { return }
            event(.opening)
            let backoff = ReconnectBackoff(
                baseSeconds: 1, maxSeconds: 8, multiplier: 2, jitterFraction: 0.3)
            var stallAttempt = 0
            var lastGood: Date?
            // Whether this link ever delivered a picture. The in-place reconnect below is for a
            // fresh session whose live view would not start; a link that streamed and then lost
            // its picture may have lost the camera to another phone (hardware pass 4.1), and
            // only recovery asks who holds it before dialing.
            var streamed = false
            while previewIsCurrent(current) {
                let began = Date()
                let attempt = Task {
                    await pump.run(
                        demand: demand, isCurrent: { self.previewIsCurrent(current) },
                        consume: { frame, delivery in
                            let accepted = await consume(frame, delivery)
                            if accepted { self.observeHeader(timecode: frame.timecode) }
                            if accepted, delivery.first {
                                self.startFailures = 0
                                lastGood = Date()
                                streamed = true
                            }
                            return accepted
                        },
                        safePoint: { count, poll in
                            guard self.previewIsCurrent(current) else { return }
                            await safePoint(count, poll)
                        },
                        applied: { value in
                            if self.previewIsCurrent(current) { applied(value) }
                        },
                        resetCadence: {
                            if self.previewIsCurrent(current) { resetCadence() }
                        },
                        health: { value in
                            lastGood = value.lastGoodFrameAt
                            if self.previewIsCurrent(current) { health(value) }
                        })
                }
                let outcome = await attempt.value
                await pump.drain()
                guard previewIsCurrent(current) else { return }
                let healthy = (lastGood ?? .distantPast).timeIntervalSince(began) > 30
                switch outcome {
                case .cancelled: return
                case .linkLost(let reason):
                    // Nothing more to this body: no EndLiveView, no restart, no in-place dial.
                    // Recovery owns the reconnect and stands down for a take-over.
                    startFailures = 0
                    event(.recover(reason: "camera link lost (\(reason))"))
                    return
                case .neverStarted(let reason) where streamed:
                    // A streamed link that cannot restart live view is not a cold start. Leave
                    // the body alone (EndLiveView could stop the picture of a phone that took
                    // it) and hand the decision to recovery.
                    startFailures = 0
                    event(.recover(reason: "live view could not restart (\(reason))"))
                    return
                case .neverStarted(let reason):
                    startFailures += 1
                    let end = Task { await link.stopLiveView() }
                    await end.value
                    if startFailures >= 3 {
                        startFailures = 0
                        event(.recover(reason: "live view never started"))
                        return
                    }
                    let delay = backoff.delaySeconds(
                        forAttempt: startFailures - 1, jitter: .random(in: 0...1))
                    event(.reconnect(reason: reason, delay: delay))
                    await backgroundSleep(.seconds(delay))
                    guard previewIsCurrent(current) else { return }
                    event(.reconnectReady)
                    return
                case .stalled(let reason):
                    if healthy { stallAttempt = 0 }
                    if stallAttempt >= 3 {
                        event(.recover(reason: "live view stall escalation"))
                        return
                    }
                    let delay = backoff.delaySeconds(
                        forAttempt: stallAttempt, jitter: .random(in: 0...1))
                    event(.restart(reason: reason, delay: delay))
                    await backgroundSleep(.seconds(delay))
                    guard previewIsCurrent(current) else { return }
                    stallAttempt += 1
                }
            }
        }
    }

    /// Publishes the header timecode per frame (A5-04). The common model observes the counter
    /// apart from the rest of the snapshot, so only the clock re-renders.
    func observeHeader(timecode: Timecode) {
        let running = timecode.running
        guard !closed, nikonControlFacts.timecode != running else { return }
        nikonControlFacts.timecode = running
        common.refresh()
    }

    /// Retires the sole reader. Its fetch drains without cancellation on a borrowed/kept link.
    /// Await the returned task before transferring that link back to a multicam tile.
    @discardableResult
    public func stopPreview() -> Task<Void, Never>? {
        previewGeneration += 1
        let previous = previewTask
        let pump = previewPump
        previewTask = nil
        previewPump = nil
        previous?.cancel()
        guard previous != nil || pump != nil else { return nil }
        return Task {
            await previous?.value
            await pump?.drain()
        }
    }

    /// Idle command-channel keepalive belongs to this link, never to an app screen lifetime.
    public func startKeepAlive(
        isBusy: @escaping @MainActor () -> Bool,
        failures: @escaping @MainActor (Int) -> Void,
        recover: @escaping @MainActor () -> Void
    ) {
        guard !closed, let link else { return }
        let previous = keepAliveTask
        previous?.cancel()
        let earlier = backgroundRetirement
        let sleep = backgroundSleep
        let current = generation
        keepAliveTask = Task { [weak self] in
            // Replacement retains the previous owner until its kept ping has drained.
            await previous?.value
            await earlier?.value
            var count = 0
            while !Task.isCancelled {
                await sleep(.seconds(10))
                guard let self, !Task.isCancelled, !closed, generation == current else { return }
                if isBusy() { continue }
                do {
                    let ping = Task { try await link.sendKeepAlive() }
                    try await ping.value
                    guard !Task.isCancelled, !closed, generation == current else { return }
                    count = max(0, count - 1)
                } catch {
                    guard !Task.isCancelled, !closed, generation == current else { return }
                    count = min(3, count + 1)
                }
                failures(count)
                if count >= 3 {
                    recover()
                    return
                }
            }
        }
    }

    /// Owns the pushed-event reader. Idle timeout is benign; retirement cannot publish late events.
    public func startEventDrain(
        receive: @escaping @MainActor (PTPEvent) async -> Void,
        unexpectedEnd: @escaping @MainActor () -> Void
    ) {
        guard !closed, let link else { return }
        let previous = eventTask
        previous?.cancel()
        let earlier = backgroundRetirement
        let current = generation
        eventTask = Task { [weak self] in
            // Foreground restarts cannot add a reader while the old bounded read drains.
            await previous?.value
            await earlier?.value
            while !Task.isCancelled {
                guard let self, !closed, generation == current else { return }
                do {
                    let read = Task { try await link.nextEvent() }
                    let event = try await read.value
                    guard !Task.isCancelled, !closed, generation == current else { return }
                    await receive(event)
                } catch let error as NativeCameraSessionError {
                    if case .timeout = error { continue }
                    guard !Task.isCancelled, !closed, generation == current else { return }
                    unexpectedEnd()
                    return
                } catch {
                    guard !Task.isCancelled, !closed, generation == current else { return }
                    unexpectedEnd()
                    return
                }
            }
        }
    }

    /// The exact existing GetEventEx cadence at an admitted app/control safe point.
    /// A ticket belongs to one link/runtime generation; late results cannot publish or clear a successor.
    @discardableResult
    public func pollDeviceEventsAtSafePoint(
        frameCounter: Int,
        framePeriodMilliseconds: Double, roundTripMilliseconds: Double?,
        receive: @escaping @MainActor (PTPEvent) -> Void
    ) -> Bool {
        guard !closed, let link, let polling = link as? any NikonDeviceEventPollLink,
            deviceEventPoll == nil
        else { return false }
        let stride = LiveViewPollPacing.eventPollStride(
            roundTripMilliseconds: roundTripMilliseconds,
            framePeriodMilliseconds: framePeriodMilliseconds)
        guard frameCounter.isMultiple(of: stride) else { return false }
        let ticket = UUID()
        let capturedGeneration = generation
        let capturedLink = ObjectIdentifier(link)
        let task = Task { [weak self] in
            defer { if self?.deviceEventPoll?.ticket == ticket { self?.deviceEventPoll = nil } }
            guard let self, deviceEventPoll?.ticket == ticket, generation == capturedGeneration,
                !closed, !Task.isCancelled, self.link.map(ObjectIdentifier.init) == capturedLink
            else { return }
            let events = await polling.pollDeviceEvents()
            for event in events {
                guard deviceEventPoll?.ticket == ticket, generation == capturedGeneration,
                    !closed, !Task.isCancelled, self.link.map(ObjectIdentifier.init) == capturedLink
                else { return }
                receive(event)
            }
        }
        deviceEventPoll = (ticket, task)
        return true
    }

    /// Whether the runtime still owns a keepalive, event drain or preview task: started and not
    /// yet retired. It does not observe a pump's natural exit or a retirement still draining, so
    /// production code awaits `retirePumps()`; the app's background transition tests read this.
    public var hasBackgroundPumps: Bool {
        keepAliveTask != nil || eventTask != nil || deviceEventPoll != nil || previewTask != nil
    }

    /// Drains every kept-link reader before returning a borrowed session to its member.
    @discardableResult
    public func retirePumps() -> Task<Void, Never>? { stopBackgroundTasks() }

    @discardableResult
    private func stopBackgroundTasks() -> Task<Void, Never>? {
        let keepAlive = keepAliveTask
        let events = eventTask
        let polledEvents = deviceEventPoll?.task
        deviceEventPoll = nil
        polledEvents?.cancel()
        keepAliveTask = nil
        eventTask = nil
        keepAlive?.cancel()
        events?.cancel()
        let preview = stopPreview()
        let earlier = backgroundRetirement
        guard keepAlive != nil || events != nil || polledEvents != nil || preview != nil else {
            return earlier
        }
        let retirement = Task {
            await keepAlive?.value
            await events?.value
            await polledEvents?.value
            await preview?.value
            await earlier?.value
        }
        backgroundRetirement = retirement
        return retirement
    }

    private func previewIsCurrent(_ current: Int) -> Bool {
        !Task.isCancelled && !closed && previewGeneration == current
    }

    // MARK: Integration-owned common command queue

    /// Encodes a common setting against the camera's own snapshot and coalesces per property.
    public func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?
    ) -> Int {
        queueSettingWrites(label, for: setting, operation: operation, suppliedAdmission: nil)
    }

    public func admits(_ admission: NikonCommandAdmission) -> Bool {
        !closed && admission.admits(link?.commandOwner)
    }

    public func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?,
        admission: NikonCommandAdmission
    ) -> Int {
        queueSettingWrites(label, for: setting, operation: operation, suppliedAdmission: admission)
    }

    private func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?,
        suppliedAdmission: NikonCommandAdmission?
    ) -> Int {
        guard !closed, link != nil else { return 0 }
        if let admission = suppliedAdmission, !admits(admission) { return 0 }
        let encoded = PTPCameraPropertyWrite.requests(
            control: setting.cameraControl, label: label, snapshot: nikonControlFacts.reported)
        for write in encoded {
            for queued in writes where queued.write.property == write.property {
                if let earlier = queued.operation {
                    common.operationDropped(earlier, superseded: true)
                }
            }
            writes.removeAll { $0.write.property == write.property }
            writes.append((write, operation, suppliedAdmission))
        }
        return encoded.count
    }

    /// Queues the explicit record target; a newer queued target supersedes the earlier one.
    public func queueRecord(start: Bool, operation: OperationID) {
        queueRecord(start: start, operation: operation, suppliedAdmission: nil)
    }

    public func queueRecord(start: Bool, operation: OperationID, admission: NikonCommandAdmission) {
        queueRecord(start: start, operation: operation, suppliedAdmission: admission)
    }

    private func queueRecord(
        start: Bool, operation: OperationID, suppliedAdmission: NikonCommandAdmission?
    ) {
        guard !closed, link != nil else { return common.operationDropped(operation) }
        if let admission = suppliedAdmission, !admits(admission) {
            return common.commandAdmissionExpired(operation)
        }
        if let earlier = record { common.operationDropped(earlier.operation, superseded: true) }
        record = (start, operation, suppliedAdmission)
        onRecordQueued(start)
    }

    private func dropCommands(preservingAdmitted: Bool = false) {
        writes.removeAll { write in
            if preservingAdmitted, let admission = write.admission, admits(admission) {
                return false
            }
            if let operation = write.operation { common.operationDropped(operation) }
            return true
        }
        if let record {
            if preservingAdmitted, let admission = record.admission, admits(admission) { return }
            common.operationDropped(record.operation)
            self.record = nil
        }
    }

    private func closeLink(_ reason: SessionCloseReason) {
        guard !closed else { return }
        closed = true
        generation += 1
        let previewRetirement = stopBackgroundTasks()
        dropCommands()
        let previous = link
        link = nil
        if ownsLink, let previous {
            teardown = Task {
                // Close the transport before awaiting a fetch only when this runtime owns it.
                await previous.stopLiveView()
                await previous.shutdown()
                await previewRetirement?.value
            }
        }
        onClosed(reason)
    }
}

#if canImport(Darwin) && canImport(os)
    extension NativeCameraSession: NikonMonitorLink, NikonDeviceEventPollLink {
        /// Serial reported during the session's identity exchange.
        public nonisolated var serialNumber: String { identity.serialNumber }
    }
#endif
