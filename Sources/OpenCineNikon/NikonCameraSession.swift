import Foundation
import OpenCineCore

// CORE-02 (OpenCine platform plan, section 13): the Nikon PTP control slice behind the common
// camera-session seam. Connect/status, movie exposure, white balance and explicit record start/stop.
//
// The adapter owns admission, operation receipts and the PTP-to-common mapping. Its
// integration-owned NikonMonitorRuntime keeps the command queue and wire safe point; a legacy
// driver remains supported during app migration. Picture
// presentation is not a precondition: ISO and white balance are admitted with no live picture,
// while record keeps its existing live-view preflight as `.unavailable(.notReady)`.

/// Camera facts the adapter maps, read from its integration-owned driver on demand.
public struct NikonControlFacts: Equatable, Sendable {
    /// Control-link state. Recovery keeps the common session and its last reported values.
    public var connection: ConnectionState = .ready
    /// False while a relay viewer holds control of this session.
    public var holdsControl = true
    /// The body's own live view runs (picture frames or the control pump). Record needs it.
    public var liveViewReady = false
    /// Values exactly as read from the camera; never the picker's optimistic bytes.
    public var reported = PTPCameraPropertySnapshot()
    /// Camera-reported recording (live-view header or record events). `nil` until it says.
    public var recording: Bool?
    /// White-balance presets the body advertises for the active chrome, or the picker's list
    /// before the descriptor has been read.
    public var whiteBalancePresets: [String] = []
    /// Actual descriptor choices for active movie shutter and aperture, excluding UI fallbacks.
    public var shutterLabels: [String] = []
    public var apertureLabels: [String] = []
    /// The live-view header's running timecode, frames included. `nil` while the body's header
    /// says timecode is off or no header has been read: never a frozen counter.
    public var timecode: CameraTimecode?
    /// The active card's storage readback, `nil` until read.
    public var storage: PTPStorageInfo?

    public init(
        holdsControl: Bool = true, liveViewReady: Bool = false,
        reported: PTPCameraPropertySnapshot = PTPCameraPropertySnapshot(), recording: Bool? = nil,
        whiteBalancePresets: [String] = [], connection: ConnectionState = .ready,
        shutterLabels: [String] = [], apertureLabels: [String] = [], timecode: CameraTimecode? = nil,
        storage: PTPStorageInfo? = nil
    ) {
        self.holdsControl = holdsControl
        self.liveViewReady = liveViewReady
        self.reported = reported
        self.recording = recording
        self.whiteBalancePresets = whiteBalancePresets
        self.shutterLabels = shutterLabels
        self.apertureLabels = apertureLabels
        self.connection = connection
        self.timecode = timecode
        self.storage = storage
    }
}

extension Timecode {
    /// The header timecode as a common observation: unknown unless the body says it runs.
    public var running: CameraTimecode? {
        on ? CameraTimecode(hours: hour, minutes: minute, seconds: second, frames: frame) : nil
    }
}

/// The settings this slice writes, each with the PTP control its write queue encodes.
public enum NikonControlSetting: Sendable, Equatable {
    case iso
    case whiteBalance
    case shutter
    case aperture

    /// The common capability/editor key, distinct from the Nikon wire property family.
    public var key: SettingKey {
        switch self {
        case .iso: .iso
        case .whiteBalance: .whiteBalance
        case .shutter: .shutter
        case .aperture: .aperture
        }
    }

    /// The control the write encoder (`PTPCameraPropertyWrite.requests`) takes for this setting.
    public var cameraControl: PTPCameraControl {
        switch self {
        case .iso: .iso
        case .whiteBalance: .whiteBalanceKelvin
        case .shutter: .shutter
        case .aperture: .iris
        }
    }
}

/// The Nikon wire service the common adapter drives. Production uses `NikonMonitorRuntime`.
@MainActor
public protocol NikonControlDriver: AnyObject {
    var nikonControlFacts: NikonControlFacts { get }
    /// Encodes `label` for `setting` onto the coalescing write queue. Returns the number of
    /// property writes queued; 0 means nothing could be encoded and nothing was queued.
    func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?
    ) -> Int
    /// Queues an explicit record start (`true`) or stop for the next safe point.
    func queueRecord(start: Bool, operation: OperationID)
    /// Supplied authority is always bound to the driver's actual established link.
    func admits(_ admission: NikonCommandAdmission) -> Bool
    func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?,
        admission: NikonCommandAdmission
    ) -> Int
    func queueRecord(start: Bool, operation: OperationID, admission: NikonCommandAdmission)
}

extension NikonControlDriver {
    public func admits(_ admission: NikonCommandAdmission) -> Bool { false }
    public func queueSettingWrites(
        _ label: String, for setting: NikonControlSetting, operation: OperationID?,
        admission: NikonCommandAdmission
    ) -> Int { 0 }
    public func queueRecord(start: Bool, operation: OperationID, admission: NikonCommandAdmission) {
    }
}

/// A native command predicate copies this value without entering the main actor.
private final class NikonCommandSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CameraSnapshot
    private var authority = NikonCommandOwner()
    init(_ value: CameraSnapshot) { self.value = value }
    func read() -> CameraSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func replace(_ value: CameraSnapshot) {
        lock.lock()
        if self.value.session != value.session || self.value.epoch != value.epoch
            || self.value.connection != value.connection || self.value.authority != value.authority
        {
            authority.retire()
            authority = NikonCommandOwner()
        }
        self.value = value
        lock.unlock()
    }
    func captureAuthority() -> @Sendable () -> Bool {
        lock.lock()
        let captured = authority
        lock.unlock()
        return { captured.isActive }
    }
}

/// One Nikon monitor lifetime as an `OpenCineCore.CameraSession`. A replacement link during
/// recovery advances its control epoch while preserving this session ID and the held monitor.
@MainActor
public final class NikonCameraSession: CameraSession {
    public nonisolated static let integration = IntegrationID("org.opencapture.nikon-ptp")

    public nonisolated let id: CameraSessionID
    private weak var driver: (any NikonControlDriver)?
    /// The shared host clock (`MonotonicInstant.now`); tests inject their own.
    private let now: @Sendable () -> MonotonicInstant
    private let recordObservationTimeout: Duration
    private var current: CameraSnapshot
    /// The facts `current` was mapped from. `refresh()` with the same facts reuses it.
    private var mappedFacts: NikonControlFacts?
    /// Snapshot mappings run so far. A test holds unchanged facts to one mapping.
    private(set) var snapshotBuilds = 0
    private nonisolated let commandState: NikonCommandSnapshot
    /// The last published observation, safe to copy at a queued native transaction gate.
    /// Reading it performs no refresh, callbacks or transport work.
    public nonisolated var commandSnapshot: CameraSnapshot { commandState.read() }
    /// Captures source/authority publication lifetime, independent of ordinary property reports.
    public nonisolated func captureCommandAuthority() -> @Sendable () -> Bool {
        commandState.captureAuthority()
    }
    private var receipts: [OperationID: CommandReceipt] = [:]
    /// Property writes each setting operation still owes a readback for.
    private var owedWrites: [OperationID: Int] = [:]
    /// Accepted record targets waiting for the camera to report them.
    private var recordTargets: [OperationID: Bool] = [:]
    private var subscribers: [UUID: AsyncStream<CameraSnapshot>.Continuation] = [:]
    private var waiters: [OperationID: [UUID: CheckedContinuation<CommandReceipt?, Never>]] = [:]
    private let onClose: @MainActor (SessionCloseReason) -> Void

    public init(
        driver: any NikonControlDriver, serialNumber: String,
        recordObservationTimeout: Duration = .seconds(5),
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now,
        onClose: @escaping @MainActor (SessionCloseReason) -> Void = { _ in }
    ) {
        let session = CameraSessionID()
        id = session
        self.driver = driver
        self.now = now
        self.recordObservationTimeout = recordObservationTimeout
        self.onClose = onClose
        let device =
            Self.durableDevice(serialNumber: serialNumber)
            ?? .provisional(integration: Self.integration)
        let initial = CameraSnapshot(
            session: session, epoch: ControlEpoch(1), device: device, connection: .ready,
            authority: .owner)
        current = initial
        commandState = NikonCommandSnapshot(initial)
        refresh()
    }

    /// The body's lasting identity: its serial (trimmed), `nil` when none is known yet. Saved
    /// records stamp the same serial, so a group entry and its session name the same device.
    public nonisolated static func durableDevice(serialNumber: String?) -> CameraDeviceID? {
        let serial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return serial.isEmpty ? nil : .durable(serial, integration: integration)
    }

    private var isClosed: Bool {
        if case .disconnected = current.connection { return true }
        return false
    }

    // MARK: CameraSession

    public func snapshots() -> AsyncStream<CameraSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: CameraSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(refresh())
        if isClosed {
            continuation.finish()
        } else {
            subscribers[UUID()] = continuation
        }
        return stream
    }

    public func submit(_ command: CameraCommand) -> CommandReceipt {
        submit(command, suppliedAdmission: nil)
    }

    public func submit(_ command: CameraCommand, admission: NikonCommandAdmission) -> CommandReceipt
    {
        submit(command, suppliedAdmission: admission)
    }

    private func submit(_ command: CameraCommand, suppliedAdmission: NikonCommandAdmission?)
        -> CommandReceipt
    {
        let operation = command.operation
        if let known = receipts[operation] { return known }
        let snapshot = refresh()
        receipts[operation] = CommandReceipt(
            operation: operation, session: id, intent: command.intent,
            confirmation: snapshot.capabilities[command.intent.key]?.semantics.confirmation
                ?? .readback)
        var operationSnapshot = snapshot
        if let admission = suppliedAdmission {
            guard driver?.admits(admission) == true else {
                return transition(operation, .rejected(.authorityExpired))
            }
            // This explicit holder receipt admits one operation while the local operator's
            // controls remain surrendered. It never changes the published camera authority.
            operationSnapshot.authority = .owner
        }
        if let rejection = operationSnapshot.rejection(of: command, at: now()) {
            return transition(operation, .rejected(rejection))
        }
        transition(operation, .admitted)
        switch command.intent {
        case .set(let value):
            guard let (setting, label) = Self.settingValue(for: value), let driver else {
                return transition(operation, .failed(.notSent))
            }
            let writes: Int
            if let admission = suppliedAdmission {
                writes = driver.queueSettingWrites(
                    label, for: setting, operation: operation, admission: admission)
            } else {
                writes = driver.queueSettingWrites(label, for: setting, operation: operation)
            }
            guard writes > 0 else { return transition(operation, .failed(.notSent)) }
            owedWrites[operation] = writes
            return receipts[operation]!
        case .startRecording, .stopRecording:
            let start = command.intent == .startRecording
            // Idempotent: a target the camera already reports is confirmed without a command, so
            // a confirmed or retried press can never undo itself. Not while another record
            // command is in flight: this one must replace or follow it, or the earlier one wins.
            if recordTargets.isEmpty, snapshot.recording.value == (start ? .recording : .idle) {
                return transition(operation, .confirmed)
            }
            guard let driver else { return transition(operation, .failed(.notSent)) }
            recordTargets[operation] = start
            if let admission = suppliedAdmission {
                driver.queueRecord(start: start, operation: operation, admission: admission)
            } else {
                driver.queueRecord(start: start, operation: operation)
            }
            return receipts[operation]!
        case .focusPoint:
            // Not advertised, so admission already rejected it as `.supportUnknown`.
            return transition(operation, .failed(.notSent))
        }
    }

    public func receipt(of operation: OperationID) -> CommandReceipt? { receipts[operation] }

    public func outcome(of operation: OperationID) async -> CommandReceipt? {
        guard let receipt = receipts[operation] else { return nil }
        if receipt.isFinished || Task.isCancelled { return receipt }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[operation, default: [:]][token] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.stopWaiting(operation, token) }
        }
    }

    /// Never sends a camera command; in particular it never stops a recording.
    public func close(_ reason: SessionCloseReason) {
        guard !isClosed else { return }
        for (operation, receipt) in receipts where !receipt.isFinished {
            transition(operation, receipt.stage == .admitted ? .failed(.notSent) : .outcomeUnknown)
        }
        owedWrites.removeAll()
        recordTargets.removeAll()
        current.connection = .disconnected(reason)
        current.authority = .unavailable(.link)
        current.revision = current.revision.next()
        commandState.replace(current)
        for continuation in subscribers.values {
            continuation.yield(current)
            continuation.finish()
        }
        subscribers.removeAll()
        onClose(reason)
    }

    // MARK: App entry and command-path hooks

    /// The operator acting on what the camera reports right now.
    public func request(_ intent: CameraCommandIntent) -> CommandReceipt {
        submit(CameraCommand(intent, preconditions: CommandPreconditions(refresh())))
    }

    public func request(_ intent: CameraCommandIntent, admission: NikonCommandAdmission)
        -> CommandReceipt
    {
        submit(
            CameraCommand(intent, preconditions: CommandPreconditions(refresh())),
            admission: admission)
    }

    /// No new wire work is sent. An earlier accepted part of a multi-write operation may remain.
    public func commandAdmissionExpired(_ operation: OperationID) {
        guard let receipt = receipts[operation], !receipt.isFinished else { return }
        switch receipt.stage {
        case .accepted, .awaitingObservation:
            finish(operation, .outcomeUnknown)
        default:
            finish(operation, .rejected(.authorityExpired))
        }
    }

    /// The safe point is putting this operation's command on the wire.
    public func operationSent(_ operation: OperationID) {
        guard receipts[operation]?.stage == .admitted else { return }
        transition(operation, .sent)
    }

    /// A queued command of this operation will never be sent: a newer value coalesced it away or
    /// a newer press replaced it (`superseded`), or the queue was reset.
    public func operationDropped(_ operation: OperationID, superseded: Bool = false) {
        guard let receipt = receipts[operation], !receipt.isFinished else { return }
        owedWrites[operation] = nil
        recordTargets[operation] = nil
        transition(
            operation,
            superseded
                ? .failed(.superseded)
                : receipt.stage == .admitted ? .failed(.notSent) : .outcomeUnknown)
    }

    /// The camera accepted one property write of a setting operation. `readback` is what it
    /// reports afterwards, `nil` when that read failed: the write may have landed, so the outcome
    /// is unknown, never success.
    public func writeLanded(
        _ operation: OperationID, write: PTPCameraPropertyWrite, readback: Data?
    ) {
        guard let owed = owedWrites[operation] else { return }
        guard let readback else { return finish(operation, .outcomeUnknown) }
        guard Self.readbackMatches(write, readback) else {
            return finish(operation, .failed(.notApplied))
        }
        if receipts[operation]?.stage == .sent { transition(operation, .accepted) }
        if owed > 1 {
            owedWrites[operation] = owed - 1
        } else {
            finish(operation, .confirmed)
        }
    }

    /// A command of this operation failed on the wire. A camera refusal is a rejection; anything
    /// else (timeout, closed link) may have reached the camera, so its outcome is unknown.
    /// A queued command failed. `cameraRefused` is true when the body answered with a PTP refusal
    /// (the app maps its transport error); anything else leaves the outcome unknown.
    public func commandFailed(_ operation: OperationID, cameraRefused: Bool) {
        guard let receipt = receipts[operation], !receipt.isFinished else { return }
        finish(operation, cameraRefused ? .rejected(.cameraRefused) : .outcomeUnknown)
    }

    /// The camera accepted a record start or stop; the operation now waits for the camera to
    /// report the target, and times out (never succeeds) if it does not.
    public func recordAccepted(_ operation: OperationID) {
        guard receipts[operation]?.stage == .sent, recordTargets[operation] != nil else { return }
        transition(operation, .accepted)
        transition(operation, .awaitingObservation)
        refresh()
        Task { [weak self, recordObservationTimeout] in
            try? await Task.sleep(for: recordObservationTimeout)
            guard let self, self.receipts[operation]?.stage == .awaitingObservation else { return }
            self.finish(operation, .timedOut)
        }
    }

    /// Re-reads the camera facts, publishes a changed snapshot and confirms record operations the
    /// camera now reports. The model calls this whenever camera-reported state changes; app
    /// getters read it from view code too, so unchanged facts reuse the mapped snapshot.
    @discardableResult
    public func refresh() -> CameraSnapshot {
        guard !isClosed, let facts = driver?.nikonControlFacts else { return current }
        if facts != mappedFacts {
            mappedFacts = facts
            map(facts)
        }
        for (operation, start) in recordTargets
        where receipts[operation]?.stage == .awaitingObservation
            && current.recording.value == (start ? .recording : .idle)
        {
            finish(operation, .confirmed)
        }
        return current
    }

    private func map(_ facts: NikonControlFacts) {
        snapshotBuilds += 1
        let at = now()
        var next = current
        if current.connection != .ready, facts.connection == .ready {
            next.epoch = current.epoch.next()
        }
        next.connection = facts.connection
        next.authority =
            facts.connection != .ready
            ? .unavailable(.link)
            : facts.holdsControl ? .owner : .unavailable(.authority)
        if current.connection == .ready, facts.connection != .ready {
            for (operation, receipt) in receipts where !receipt.isFinished {
                operationDropped(operation)
            }
        }
        // Nothing is listed unsupported: every common key exists on Z bodies (lens-, mode- or
        // firmware-dependent, tint as WB fine-tune), so what this slice does not describe is
        // unknown, not unsupported (MULTI-03 F6).
        let descriptors = Self.descriptors(facts)
        let timecode = Self.timecodeCapability(facts.reported)
        let revision = next.capabilities.revision
        if CapabilitySnapshot(revision: revision, descriptors: descriptors, timecodeCapability: timecode)
            != next.capabilities
        {
            next.capabilities = CapabilitySnapshot(
                revision: revision.next(), descriptors: descriptors, timecodeCapability: timecode)
        }
        Self.observe(&next.timecode, facts.timecode, at: at)
        Self.observe(&next.mode, Self.mode(facts.reported), at: at)
        Self.observe(&next.recording, facts.recording.map { $0 ? .recording : .idle }, at: at)
        Self.observe(
            &next.power.battery, facts.reported.batteryPercent.flatMap(Self.batteryFraction), at: at,
            // BatteryLevel is the body's five-step gauge, never a percent (A5-01).
            precision: .quantized(step: 1.0 / Double(NikonCameraBatteryGauge.barCount)))
        Self.observe(&next.power.exhausted,
            facts.reported.batteryPercent.flatMap { NikonCameraBatteryGauge.gauge(rawBatteryLevel: $0).exhaustion },
            at: at)
        Self.observe(&next.power.externalPower, facts.reported.onExternalPower, at: at)
        Self.observe(&next.storage, Self.storageVolumes(facts, previous: next.storage.value, at: at), at: at)
        for (key, value) in Self.reportedSettings(facts.reported) {
            var observation = next.value(of: key)
            Self.observe(&observation, value, at: at)
            next.settings[key] = observation.isKnown ? observation : nil
        }
        Self.observe(&next.exposureProgram, Self.exposureProgram(facts.reported.exposureMode), at: at)
        let dimensions = Self.recordingDimensions(facts.reported.resolution)
        Self.observe(&next.recordingFormat.dimensions, dimensions, at: at)
        let codec = facts.reported.fileType?.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.observe(&next.recordingFormat.codec, codec.flatMap { $0.isEmpty ? nil : $0 }, at: at)
        let profile = codec.flatMap(PTPCameraPropertyDecoders.toneLabel(fromCodec:))
        Self.observe(&next.recordingFormat.profile, profile, at: at)
        if profile != nil { next.recordingFormat.profile.origin = .protocolDerived }
        if next != current {
            next.revision = current.revision.next()
            current = next
            commandState.replace(current)
            for (token, continuation) in subscribers {
                if case .terminated = continuation.yield(current) { subscribers[token] = nil }
            }
        }
    }

    // MARK: PTP to common mapping

    /// Movie ISO (the picker's enumerated ladder plus the camera's current value), white balance
    /// (advertised presets plus the documented Kelvin range) and record. All readback-confirmed
    /// and not yet hardware-qualified.
    /// Every Z body's live-view header carries a frame-counting timecode field, at the movie rate
    /// the body reports (its screen-size token encodes whole frames per second). Whether it runs
    /// is the observation, not the capability.
    /// The body's gauge as a fraction on its declared fifths; an absent reading stays unknown.
    /// The integration publishes exact bytes and a separately marked estimate. An unknown
    /// recording format contributes no duration; valid zero remains a known empty capacity.
    static func storageVolumes(
        _ facts: NikonControlFacts, previous: [StorageVolume]? = nil, at: MonotonicInstant? = nil
    ) -> [StorageVolume]? {
        guard let storage = facts.storage, storage.readout != nil else { return nil }
        let old = previous?.first { $0.id == "active" }
        func observation<T: Equatable & Sendable>(
            _ value: T?, _ previous: ObservedValue<T>?, origin: ObservationOrigin
        ) -> ObservedValue<T> {
            guard let value else { return .unknown }
            if let previous, previous.value == value, previous.origin == origin { return previous }
            return ObservedValue(value, origin: origin, at: at)
        }
        let minutes = facts.reported.captureSelector == .video
            ? RecordDurationEstimator.estimateMinutes(
                codec: facts.reported.fileType, resolution: facts.reported.resolution,
                frameRate: facts.reported.fps, freeBytes: storage.freeSpaceBytes) : nil
        return [StorageVolume(
            id: "active",
            freeBytes: observation(storage.freeSpaceBytes, old?.freeBytes, origin: .cameraReported),
            totalBytes: observation(storage.totalCapacityBytes > 0 ? storage.totalCapacityBytes : nil,
                old?.totalBytes, origin: .cameraReported),
            remainingRecordingTime: observation(minutes.map { Duration.seconds($0 * 60) },
                old?.remainingRecordingTime, origin: .estimated))]
    }

    public static func batteryFraction(_ rawBatteryLevel: Int) -> Double? {
        let gauge = NikonCameraBatteryGauge.gauge(rawBatteryLevel: rawBatteryLevel)
        return gauge == .unknown ? nil : Double(gauge.filledBars) / Double(NikonCameraBatteryGauge.barCount)
    }

    static func timecodeCapability(_ reported: PTPCameraPropertySnapshot) -> TimecodeCapability {
        .supported(frameRate(reported).map { .frames(rate: $0, dropFrame: nil) })
    }

    private static func exposureProgram(_ label: String?) -> CameraExposureProgram? {
        switch label {
        case "M": .manual
        case "P": .program
        case "A": .aperturePriority
        case "S": .shutterPriority
        case "Auto": .automatic
        default: nil
        }
    }

    private static func recordingDimensions(_ value: String?) -> CameraRecordingFormat.Dimensions? {
        guard let value else { return nil }
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return CameraRecordingFormat.Dimensions(width: width, height: height)
    }

    /// The movie rate as the screen-size token reports it, in whole frames per second. Whether a
    /// body's "24p" token records 24000/1001 is unverified on hardware, so none is assumed.
    static func frameRate(_ reported: PTPCameraPropertySnapshot) -> Rational? {
        reported.fps.flatMap { $0 > 0 ? Rational($0) : nil }
    }

    public static func descriptors(_ facts: NikonControlFacts) -> [SettingDescriptor] {
        let reported = facts.reported
        let codec = reported.fileType ?? ""
        let iso: Availability =
            if StillCapturePolicy.prefersPhotographyChrome(selector: reported.captureSelector) {
                // Photo chrome edits the stills ISO, a separate camera setting outside this slice.
                .unavailable(.mode)
            } else if !ISOPickerPolicy.allowsManualISO(
                codec: codec, exposureMode: reported.exposureMode)
            {
                .unavailable(.mode)
            } else if ISOPickerPolicy.blocksISOChangeWhileRecording(
                codec: codec, isRecording: facts.recording == true)
            {
                .unavailable(.recordingActive)
            } else {
                .available
            }
        // Only presets the write encoder can express; Kelvin is the colour-temperature mode.
        let presets = facts.whiteBalancePresets
            .filter { PTPCameraPropertyDecoders.wbModeCode(for: $0) != nil && $0 != "Color temp" }
            .map(whiteBalance(preset:))
        // The ladder the picker offers, plus the camera's own current value: Auto can park ISO
        // off the ladder (51200), and leaving Auto writes that value back.
        var isoLadder = ISOPickerPolicy.unifiedOptions.compactMap { Int($0) }
        if let live = reported.iso.map({ Int($0) }), !isoLadder.contains(live) {
            isoLadder.append(live)
        }
        return [
            SettingDescriptor(
                .iso, domain: SettingDomain(choices: isoLadder.map { .iso(.manual($0)) }),
                availability: iso),
            SettingDescriptor(
                .whiteBalance,
                domain: SettingDomain(
                    choices: presets,
                    range: Double(
                        WhiteBalanceKelvinPolicy.minimumKelvin)...Double(
                            WhiteBalanceKelvinPolicy.maximumKelvin),
                    step: Double(WhiteBalanceKelvinPolicy.fineStepKelvin))),
            SettingDescriptor(
                .recording,
                availability: facts.liveViewReady ? .available : .unavailable(.notReady)),
            // The movie rate is a common read-only observation; the format picker stays native.
            SettingDescriptor(.frameRate, access: .readOnly),
        ]
            + NikonExposureSettings.descriptors(
                reported, shutterLabels: facts.shutterLabels, apertureLabels: facts.apertureLabels)
    }

    /// The setting and label the app's write encoder takes for a common value.
    public static func settingValue(for value: SettingValue) -> (NikonControlSetting, String)? {
        switch value {
        case .iso(.manual(let iso)): (.iso, String(iso))
        case .whiteBalance(.auto): (.whiteBalance, "Auto")
        case .whiteBalance(.preset(let label)): (.whiteBalance, label)
        case .whiteBalance(.kelvin(let kelvin)):
            (.whiteBalance, WhiteBalanceKelvinPolicy.label(for: kelvin))
        case .shutter:
            NikonExposureSettings.label(value).map { (.shutter, $0) }
        case .aperture:
            NikonExposureSettings.label(value).map { (.aperture, $0) }
        default: nil
        }
    }

    /// The common value for a selection of `setting`, or `nil` when `label` does not parse.
    public nonisolated static func setting(
        _ setting: NikonControlSetting, label: String
    ) -> SettingValue? {
        switch setting {
        case .iso:
            Int(label.trimmingCharacters(in: .whitespaces)).map { .iso(.manual($0)) }
        case .whiteBalance:
            WhiteBalanceKelvinPolicy.kelvin(from: label).map { .whiteBalance(.kelvin($0)) }
                ?? whiteBalance(preset: label)
        case .shutter: NikonExposureSettings.shutter(label)
        case .aperture: NikonExposureSettings.aperture(label)
        }
    }

    /// Whether the camera's readback carries the requested value. Compared decoded where the
    /// snapshot decodes the property (so width or padding differences do not matter), byte-exact
    /// otherwise.
    public static func readbackMatches(_ write: PTPCameraPropertyWrite, _ readback: Data) -> Bool {
        let blank = PTPCameraPropertySnapshot()
        let requested = blank.applying(property: write.property, data: write.data)
        guard requested != blank else { return readback == write.data }
        return blank.applying(property: write.property, data: readback) == requested
    }

    private nonisolated static func whiteBalance(preset label: String) -> SettingValue {
        .whiteBalance(label == "Auto" ? .auto : .preset(label))
    }

    private static func reportedSettings(
        _ reported: PTPCameraPropertySnapshot
    ) -> [SettingKey: SettingValue?] {
        let photography = StillCapturePolicy.prefersPhotographyChrome(
            selector: reported.captureSelector)
        let iso: SettingValue? =
            ISOPickerPolicy.isAutoISOActive(
                isoAuto: reported.isoAuto, codec: reported.fileType ?? "")
            ? .iso(.auto) : reported.iso.map { .iso(.manual(Int($0))) }
        let wbMode = reported.activeWBMode(photography: photography)
        let whiteBalance: SettingValue? =
            wbMode == "Color temp"
            ? reported.wbKelvin.map { .whiteBalance(.kelvin(Int($0))) }
            : wbMode.map(whiteBalance(preset:))
        // Photo chrome reports the stills ISO, which is not this slice's movie ISO setting.
        return [
            .iso: photography ? nil : iso, .whiteBalance: whiteBalance,
            .frameRate: frameRate(reported).map(SettingValue.frameRate),
        ]
            .merging(NikonExposureSettings.reported(reported)) { _, exposure in exposure }
    }

    private static func mode(_ reported: PTPCameraPropertySnapshot) -> CaptureMode? {
        reported.captureSelector.map {
            $0 == .photo
                ? CaptureMode(role: .photo, id: "\(integration.rawValue).photo", title: "Photo")
                : CaptureMode(role: .video, id: "\(integration.rawValue).movie", title: "Movie")
        }
    }

    /// Keeps an unchanged observation and its timestamp; a new value is camera-reported now, and
    /// no value is unknown.
    private static func observe<Value: Equatable>(
        _ observation: inout ObservedValue<Value>, _ value: Value?, at instant: MonotonicInstant,
        precision: ObservationPrecision? = nil
    ) {
        guard observation.value != value else { return }
        observation =
            value.map {
                ObservedValue($0, origin: .cameraReported, at: instant, precision: precision)
            }
            ?? .unknown
    }

    // MARK: Receipts

    private func finish(_ operation: OperationID, _ stage: CommandStage) {
        owedWrites[operation] = nil
        recordTargets[operation] = nil
        transition(operation, stage)
    }

    @discardableResult
    private func transition(_ operation: OperationID, _ stage: CommandStage) -> CommandReceipt {
        var receipt = receipts[operation]!
        receipt.stage = stage
        receipts[operation] = receipt
        if receipt.isFinished, let waiting = waiters.removeValue(forKey: operation) {
            for continuation in waiting.values { continuation.resume(returning: receipt) }
        }
        return receipt
    }

    private func stopWaiting(_ operation: OperationID, _ token: UUID) {
        waiters[operation]?.removeValue(forKey: token)?.resume(returning: receipts[operation])
    }
}
