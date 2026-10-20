import Foundation
import OpenCineCore

/// One mode the fake camera can be in: its common identity and the descriptors it exposes.
public struct FakeMode: Sendable {
    public var mode: CaptureMode
    public var descriptors: [SettingDescriptor]
    public var unsupported: Set<SettingKey>
    public var timecode: SupportStatus {
        get { timecodeCapability.support }
        set {
            if newValue != timecodeCapability.support {
                timecodeCapability = TimecodeCapability(support: newValue)
            }
        }
    }
    public var timecodeCapability: TimecodeCapability
    public var audioLevels: SupportStatus

    public init(
        _ mode: CaptureMode, _ descriptors: [SettingDescriptor], unsupported: Set<SettingKey>,
        timecode: SupportStatus = .unknown, audioLevels: SupportStatus = .unknown
    ) {
        self.init(mode, descriptors, unsupported: unsupported,
            timecodeCapability: TimecodeCapability(support: timecode), audioLevels: audioLevels)
    }

    public init(
        _ mode: CaptureMode, _ descriptors: [SettingDescriptor], unsupported: Set<SettingKey>,
        timecodeCapability: TimecodeCapability, audioLevels: SupportStatus = .unknown
    ) {
        self.mode = mode
        self.descriptors = descriptors
        self.unsupported = unsupported
        self.timecodeCapability = timecodeCapability
        self.audioLevels = audioLevels
    }
}

/// Behavior knobs. Each fixture family is one combination; shared tests never ask which.
public struct FakeCameraBehavior: Sendable {
    public enum RecordWire: Sendable {
        /// One wire command flips recording, so it is only safe with a known reported state.
        case toggle
        case explicit
    }

    public var integration: IntegrationID
    /// Time from an accepted write until the camera reports the result.
    public var reportDelay: Duration
    /// How long an operation waits for its observation when it has no earlier deadline.
    public var observationTimeout: Duration
    public var recordWire: RecordWire
    /// Recording stays unavailable until the camera's own live view runs.
    public var recordNeedsLiveView: Bool
    /// Raw wire mode to common mode (the adapter-owned mapping). An unmapped raw mode is reported
    /// as an `.other` mode with unknown capabilities.
    public var modes: [UInt8: FakeMode]
    /// `.clockDerived` for a camera whose time of day the integration derives from a clock.
    public var timecodeOrigin: ObservationOrigin

    public init(
        integration: IntegrationID, reportDelay: Duration, observationTimeout: Duration,
        recordWire: RecordWire, recordNeedsLiveView: Bool = false, modes: [UInt8: FakeMode],
        timecodeOrigin: ObservationOrigin = .cameraReported
    ) {
        self.integration = integration
        self.reportDelay = reportDelay
        self.observationTimeout = observationTimeout
        self.recordWire = recordWire
        self.recordNeedsLiveView = recordNeedsLiveView
        self.modes = modes
        self.timecodeOrigin = timecodeOrigin
    }
}

/// The simulated camera's true state. The session learns it only through reports.
public struct FakeDevice: Sendable {
    public var rawMode: UInt8
    public var settings: [SettingKey: SettingValue]
    /// `nil`: the camera's status does not carry recording state (yet).
    public var recording: Bool?
    /// `nil`: this camera never reports battery.
    public var batteryPercent: Int?
    /// `nil`: this camera never reports storage.
    public var freeBytes: UInt64?
    /// Reported only in a mode that supports it.
    public var timecode: CameraTimecode? {
        get { timecodeReading?.frameTimecode }
        set { timecodeReading = newValue.map(CameraTimecodeReading.init) }
    }
    public var timecodeReading: CameraTimecodeReading?
    /// Reported only in a mode that supports it.
    public var audioLevels: AudioLevels?

    public init(
        rawMode: UInt8, settings: [SettingValue], recording: Bool? = false,
        batteryPercent: Int? = nil, freeBytes: UInt64? = nil, timecode: CameraTimecode? = nil,
        audioLevels: AudioLevels? = nil
    ) {
        self.rawMode = rawMode
        self.settings = Dictionary(settings.map { ($0.key, $0) }) { _, last in last }
        self.recording = recording
        self.batteryPercent = batteryPercent
        self.freeBytes = freeBytes
        self.timecodeReading = timecode.map(CameraTimecodeReading.init)
        self.audioLevels = audioLevels
    }

    public init(
        rawMode: UInt8, settings: [SettingValue], recording: Bool? = false,
        batteryPercent: Int? = nil, freeBytes: UInt64? = nil, timecodeReading: CameraTimecodeReading?,
        audioLevels: AudioLevels? = nil
    ) {
        self.init(rawMode: rawMode, settings: settings, recording: recording,
            batteryPercent: batteryPercent, freeBytes: freeBytes, audioLevels: audioLevels)
        self.timecodeReading = timecodeReading
    }

}

/// A deterministic `CameraSession` on a manual clock. Nothing happens between calls: tests move
/// time with `advance(by:)` and drive the camera side with the `camera...` and link methods.
public actor FakeCameraSession: CameraSession {
    public nonisolated let id = CameraSessionID()
    public nonisolated let behavior: FakeCameraBehavior
    public private(set) var device: FakeDevice
    public private(set) var now = MonotonicInstant.zero
    public private(set) var current: CameraSnapshot
    /// Every command that reached the camera, in order.
    public private(set) var wire: [String] = []
    public private(set) var liveViewReady = false

    private struct Write {
        var intent: CameraCommandIntent
        var dropped: Bool
    }

    private enum Event {
        case apply(OperationID)
        case timeout(OperationID)
    }

    private var attempt = ConnectionAttemptID()
    private var receipts: [OperationID: CommandReceipt] = [:]
    private var history: [OperationID: [CommandStage]] = [:]
    private var writes: [OperationID: Write] = [:]
    private var queue: [(at: MonotonicInstant, order: Int, event: Event)] = []
    private var order = 0
    private var subscribers: [UUID: AsyncStream<CameraSnapshot>.Continuation] = [:]
    private var waiters: [OperationID: [UUID: CheckedContinuation<CommandReceipt?, Never>]] = [:]
    private var refuseNext = false
    private var dropNext = false
    private var reportsSilenced = false

    /// A connected session (epoch 1) that has not heard from the camera yet: everything unknown.
    public init(behavior: FakeCameraBehavior, device: FakeDevice, authority: ControlAuthority = .owner) {
        self.behavior = behavior
        self.device = device
        current = CameraSnapshot(
            session: id, epoch: ControlEpoch(1),
            device: .provisional(integration: behavior.integration), connection: .ready,
            authority: authority)
    }

    public var subscriberCount: Int { subscribers.count }
    public func stages(of operation: OperationID) -> [CommandStage] { history[operation] ?? [] }

    // MARK: Camera side

    /// The camera pushes a full status report. A report from a superseded attempt is ignored.
    public func cameraReportsStatus(from reportAttempt: ConnectionAttemptID? = nil) {
        if let reportAttempt, reportAttempt != attempt { return }
        guard current.connection == .ready, !reportsSilenced else { return }
        report()
    }

    /// The camera's counter advances (a live-view header, a status push): only the timecode changes.
    public func cameraReportsTimecode(_ timecode: CameraTimecode?) {
        device.timecode = timecode
        cameraReportsStatus()
    }

    public func cameraReportsTimecodeReading(_ timecode: CameraTimecodeReading?) {
        device.timecodeReading = timecode
        cameraReportsStatus()
    }


    /// The camera reports a setting changed on its own side (a body dial, a format readback).
    public func cameraReportsSetting(_ value: SettingValue) {
        device.settings[value.key] = value
        cameraReportsStatus()
    }

    /// A camera-body recording report, independent of any app command.
    public func cameraReportsRecording(_ recording: Bool?) {
        device.recording = recording
        if recording == nil { current.recording = .unknown }
        cameraReportsStatus()
    }

    /// The operator turns the mode dial. Values the new mode cannot hold move to its first choice.
    public func cameraSwitchesMode(raw: UInt8) {
        device.rawMode = raw
        for descriptor in behavior.modes[raw]?.descriptors ?? [] {
            guard let domain = descriptor.domain, let value = device.settings[descriptor.key],
                !domain.contains(value), let first = domain.choices.first
            else { continue }
            device.settings[descriptor.key] = first
        }
        cameraReportsStatus()
    }

    public func setLiveViewReady(_ ready: Bool) {
        liveViewReady = ready
        guard current.mode.isKnown else { return }
        refreshCapabilities()
        publish()
    }

    public func setAuthority(_ authority: ControlAuthority) {
        current.authority = authority
        publish()
    }

    /// The camera NACKs the next command that reaches it.
    public func refuseNextCommand() { refuseNext = true }
    /// The camera acknowledges the next write but does not store it.
    public func dropNextWrite() { dropNext = true }
    /// The camera stops (or resumes) sending status reports.
    public func silenceReports(_ silenced: Bool) { reportsSilenced = silenced }

    // MARK: Link

    /// The link drops. Sent operations become `.outcomeUnknown` (the camera may still act);
    /// recovery starts with a new attempt. Reported values stay as last reported.
    @discardableResult
    public func loseLink() -> ConnectionAttemptID {
        for (operation, receipt) in receipts where !receipt.isFinished {
            transition(operation, .outcomeUnknown)
        }
        return beginAttempt()
    }

    /// A new recovery attempt supersedes the current one.
    @discardableResult
    public func beginAttempt() -> ConnectionAttemptID {
        attempt = ConnectionAttemptID()
        current.connection = .recovering(attempt)
        publish()
        return attempt
    }

    /// A link-up callback. Ignored unless it belongs to the current attempt. The replacement
    /// link advances the control epoch.
    public func completeAttempt(_ completed: ConnectionAttemptID) {
        guard completed == attempt, case .recovering = current.connection else { return }
        current.connection = .ready
        current.epoch = current.epoch.next()
        publish()
    }

    /// Moves the manual clock, delivering due camera reports and timeouts in time order.
    public func advance(by duration: Duration) {
        let end = now + duration
        while let index = queue.indices.min(by: {
            (queue[$0].at, queue[$0].order) < (queue[$1].at, queue[$1].order)
        }), queue[index].at <= end {
            let item = queue.remove(at: index)
            now = item.at
            switch item.event {
            case .apply(let operation):
                apply(operation)
            case .timeout(let operation):
                if receipts[operation]?.stage == .awaitingObservation {
                    transition(operation, .timedOut)
                }
            }
        }
        now = end
    }

    // MARK: CameraSession

    public func snapshots() -> AsyncStream<CameraSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: CameraSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(current)
        if case .disconnected = current.connection {
            continuation.finish()
        } else {
            subscribers[UUID()] = continuation
        }
        return stream
    }

    public func submit(_ command: CameraCommand) -> CommandReceipt {
        let operation = command.operation
        if let known = receipts[operation] { return known }
        receipts[operation] = CommandReceipt(
            operation: operation, session: id, intent: command.intent,
            confirmation: current.capabilities[command.intent.key]?.semantics.confirmation
                ?? .readback)
        history[operation] = [.created]

        if let rejection = current.rejection(of: command, at: now)
            ?? integrationRejection(command.intent)
        {
            return transition(operation, .rejected(rejection))
        }
        transition(operation, .admitted)
        supersedeEarlierWrites(to: command.intent, by: operation)
        if alreadyReported(command.intent) { return transition(operation, .confirmed) }

        wire.append(wireCommand(command.intent))
        transition(operation, .sent)
        if refuseNext {
            refuseNext = false
            return transition(operation, .rejected(.cameraRefused))
        }
        let accepted = transition(operation, .accepted)
        if accepted.isFinished { return accepted }

        writes[operation] = Write(intent: command.intent, dropped: dropNext)
        dropNext = false
        schedule(.apply(operation), at: now + behavior.reportDelay)
        var timeout = now + behavior.observationTimeout
        if let deadline = command.preconditions.deadline, deadline < timeout { timeout = deadline }
        schedule(.timeout(operation), at: timeout)
        return transition(operation, .awaitingObservation)
    }

    public func outcome(of operation: OperationID) async -> CommandReceipt? {
        guard let receipt = receipts[operation] else { return nil }
        if receipt.isFinished || Task.isCancelled { return receipt }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[operation, default: [:]][token] = continuation
            }
        } onCancel: {
            Task { await self.stopWaiting(operation, token) }
        }
    }

    public func receipt(of operation: OperationID) -> CommandReceipt? { receipts[operation] }

    public func close(_ reason: SessionCloseReason) {
        if case .disconnected = current.connection { return }
        for (operation, receipt) in receipts where !receipt.isFinished {
            switch receipt.stage {
            case .created, .admitted: transition(operation, .failed(.notSent))
            default: transition(operation, .outcomeUnknown)
            }
        }
        writes.removeAll()
        queue.removeAll()
        current.connection = .disconnected(reason)
        current.authority = .unavailable(.link)
        publish()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: Internals

    private func integrationRejection(_ intent: CameraCommandIntent) -> CommandRejection? {
        guard behavior.recordWire == .toggle else { return nil }
        switch intent {
        case .startRecording, .stopRecording:
            switch current.recording.value {
            case .idle?, .recording?: return nil
            default: return .recordingStateUnknown
            }
        case .set, .focusPoint:
            return nil
        }
    }

    /// Coalescing policy: an admitted write retires every unfinished write to the same setting.
    /// The camera still acts on what it already received; only the newest receipt can confirm.
    private func supersedeEarlierWrites(to intent: CameraCommandIntent, by newer: OperationID) {
        guard case .set(let value) = intent else { return }
        for (operation, receipt) in receipts
        where operation != newer && !receipt.isFinished && receipt.intent.key == value.key {
            if case .set = receipt.intent { transition(operation, .failed(.superseded)) }
        }
    }

    /// Idempotency policy: a start while the camera reports recording (or a stop while idle) is
    /// confirmed without touching the wire, so a retry can never undo the first success.
    private func alreadyReported(_ intent: CameraCommandIntent) -> Bool {
        switch intent {
        case .startRecording: current.recording.value == .recording
        case .stopRecording: current.recording.value == .idle
        case .set, .focusPoint: false
        }
    }

    private func wireCommand(_ intent: CameraCommandIntent) -> String {
        switch intent {
        case .set(let value): "set \(value)"
        case .startRecording: behavior.recordWire == .toggle ? "record-toggle" : "record-start"
        case .stopRecording: behavior.recordWire == .toggle ? "record-toggle" : "record-stop"
        case .focusPoint: "focus-point"
        }
    }

    private func schedule(_ event: Event, at instant: MonotonicInstant) {
        order += 1
        queue.append((instant, order, event))
    }

    /// The camera acts on a write, then (link and reports permitting) reports back.
    private func apply(_ operation: OperationID) {
        guard let write = writes.removeValue(forKey: operation) else { return }
        if !write.dropped {
            switch write.intent {
            case .set(let value):
                device.settings[value.key] = value
            case .startRecording:
                device.recording = behavior.recordWire == .toggle ? device.recording != true : true
            case .stopRecording:
                device.recording = behavior.recordWire == .toggle ? device.recording != true : false
            case .focusPoint:
                break
            }
        }
        guard current.connection == .ready, !reportsSilenced else { return }
        report()
        guard receipts[operation]?.stage == .awaitingObservation else { return }
        transition(operation, reportShows(write.intent) ? .confirmed : .failed(.notApplied))
    }

    private func reportShows(_ intent: CameraCommandIntent) -> Bool {
        switch intent {
        case .set(let value): current.value(of: value.key).value == value
        case .startRecording: current.recording.value == .recording
        case .stopRecording: current.recording.value == .idle
        case .focusPoint: true
        }
    }

    private func report() {
        let raw = device.rawMode
        let mode =
            behavior.modes[raw]?.mode
            ?? CaptureMode(
                role: .other, id: "\(behavior.integration.rawValue).raw.\(raw)",
                title: "Mode \(raw)")
        current.mode = ObservedValue(mode, origin: .cameraReported, at: now)
        refreshCapabilities()
        current.settings = [:]
        for (key, value) in device.settings where current.capabilities[key] != nil {
            current.settings[key] = ObservedValue(value, origin: .cameraReported, at: now)
        }
        if let recording = device.recording {
            current.recording = ObservedValue(
                recording ? .recording : .idle, origin: .cameraReported, at: now)
        }
        if let percent = device.batteryPercent {
            current.power.battery = ObservedValue(
                Double(percent) / 100, origin: .cameraReported, at: now,
                precision: .quantized(step: 0.01))
        }
        if let free = device.freeBytes {
            let volume = StorageVolume(
                id: "card", media: ObservedValue(.ready, origin: .cameraReported, at: now),
                freeBytes: ObservedValue(free, origin: .cameraReported, at: now))
            current.storage = ObservedValue([volume], origin: .cameraReported, at: now)
        }
        current.timecodeReading = .unknown
        if current.capabilities.timecode == .supported, let timecode = device.timecodeReading {
            current.timecodeReading = ObservedValue(timecode, origin: behavior.timecodeOrigin, at: now)
        }
        current.audioLevels = .unknown
        if current.capabilities.audioLevels == .supported, let levels = device.audioLevels {
            current.audioLevels = ObservedValue(levels, origin: .cameraReported, at: now)
        }
        publish()
    }

    private func refreshCapabilities() {
        var descriptors = behavior.modes[device.rawMode]?.descriptors ?? []
        let unsupported = behavior.modes[device.rawMode]?.unsupported ?? []
        if behavior.recordNeedsLiveView, !liveViewReady,
            let index = descriptors.firstIndex(where: { $0.key == .recording }),
            descriptors[index].availability == .available
        {
            descriptors[index].availability = .unavailable(.notReady)
        }
        let fakeMode = behavior.modes[device.rawMode]
        var next = CapabilitySnapshot(
            revision: current.capabilities.revision, descriptors: descriptors,
            unsupported: unsupported, timecodeCapability: fakeMode?.timecodeCapability ?? .unknown,
            audioLevels: fakeMode?.audioLevels ?? .unknown)
        guard next != current.capabilities else { return }
        next.revision = next.revision.next()
        current.capabilities = next
    }

    private func publish() {
        current.revision = current.revision.next()
        for (token, continuation) in subscribers {
            if case .terminated = continuation.yield(current) { subscribers[token] = nil }
        }
    }

    @discardableResult
    private func transition(_ operation: OperationID, _ stage: CommandStage) -> CommandReceipt {
        var receipt = receipts[operation]!
        receipt.stage = stage
        receipts[operation] = receipt
        history[operation, default: []].append(stage)
        if receipt.isFinished, let waiting = waiters.removeValue(forKey: operation) {
            for continuation in waiting.values { continuation.resume(returning: receipt) }
        }
        return receipt
    }

    private func stopWaiting(_ operation: OperationID, _ token: UUID) {
        waiters[operation]?.removeValue(forKey: token)?.resume(returning: receipts[operation])
    }
}
