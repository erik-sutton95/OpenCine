import Foundation
import OpenCineCore
import OpenCineMotion
import OpenCineMedia

/// Wire progress of one camera SET, reported by the app session's `fireCamera` so the
/// OpenCineCore seam can tell an ACK from a camera-reported value (CORE-02).
public enum ControlWireEvent: Equatable, Sendable {
    /// Refused locally, or replaced by a newer request before it reached the wire.
    case notSent
    case sent
    /// The camera ACKed. Its status may not show the value yet.
    case acknowledged
    /// The camera's own status shows the requested value.
    case confirmed
    /// NACK, and the camera's status does not show the value.
    case refused
    /// The settle window closed with no ACK and no matching status.
    case unconfirmed
}

/// Control-link state as the DJI session reports it to the seam.
public enum DJILinkState: Equatable, Sendable {
    /// A datalink is up and not rebuilding: a SET can go on the wire.
    case ready
    /// The datalink is rebuilding or session recovery is running.
    case recovering
    /// Connecting; the phase is the step the DJI connect pipeline is in.
    case connecting(OpenCineCore.ConnectionPhase)
    /// Idle, failed, or live without a datalink.
    case notLinked
}

/// What `DJICameraSessionAdapter` reads from and drives on the app's DJI session (the Kotlin
/// twin is `PocketControlPort`). The app session conforms; tests and harnesses use a fake.
@MainActor
public protocol DJIControlPort: AnyObject {
    /// The concrete native endpoint's thread-safe source identity, when an admitted port exists.
    var commandOwner: DJICommandOwner? { get }
    /// Camera-reported status.
    var status: CameraStatus { get }
    /// `status` with the white balance request in flight applied. DJI sends white balance
    /// and tint in one frame, so the next write is composed on it.
    var whiteBalanceDisplayStatus: CameraStatus { get }
    var currentShootingMode: ShootingMode? { get }
    /// Durable identity of the connected camera, if any.
    var connectedCameraID: String? { get }
    /// The connected body, if known. Its capability flags decide what the adapter lists as
    /// unsupported (plan 5.6); `nil` leaves those keys unknown.
    var connectedModel: CameraModel? { get }
    /// This app instance may control the camera (Multi View lease).
    var admitsMultiviewControl: Bool { get }
    /// A control write or a media browse holds the camera.
    var isBusy: Bool { get }
    var link: DJILinkState { get }
    /// Operator-facing note for a refused control.
    var controlNote: String? { get set }
    var captureControlState: DJICaptureControlState? { get }
    func writeShutter(
        _ denominator: Int, onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    func writeHostShutterAngle(
        _ degrees: Double, denominator: Int, admission: DJICommandAdmission?,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    func writeExposureCompensation(
        _ value: EvComp, onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    func writeFocusMode(
        _ value: OpenCineCameraVocabulary.FocusMode,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    func writeZoom(
        _ ratio: Double, onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    func takePhoto()
    func setISO(_ index: IsoIndex, onStage: (@MainActor (ControlWireEvent) -> Void)?)
    func setRecording(_ start: Bool, onStage: (@MainActor (ControlWireEvent) -> Void)?)
    func setWhiteBalanceAuto(tint: Int?, onStage: (@MainActor (ControlWireEvent) -> Void)?)
    func setWhiteBalanceCustom(
        kelvin: Int, tint: Int, onStage: (@MainActor (ControlWireEvent) -> Void)?)
    func writeShutter(
        _ denominator: Int, admission: DJICommandAdmission,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    func writeExposureCompensation(
        _ value: EvComp, admission: DJICommandAdmission,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    func writeFocusMode(
        _ value: OpenCineCameraVocabulary.FocusMode, admission: DJICommandAdmission,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    func writeZoom(
        _ ratio: Double, admission: DJICommandAdmission,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void)
    func takePhoto(admission: DJICommandAdmission)
    func setISO(
        _ index: IsoIndex, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?)
    func setRecording(
        _ start: Bool, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?)
    func setWhiteBalanceAuto(
        tint: Int?, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?)
    func setWhiteBalanceCustom(
        kelvin: Int, tint: Int, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?)
}

/// Original ports/fakes stay compatible. A supplied receipt never falls through an unknown
/// native implementation into a direct write.
extension DJIControlPort {
    public var commandOwner: DJICommandOwner? { nil }
    public func writeHostShutterAngle(
        _ degrees: Double, denominator: Int, admission: DJICommandAdmission?,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { onStage(.notSent) }

    public func writeShutter(
        _ denominator: Int, admission: DJICommandAdmission,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { onStage(.notSent) }
    public func writeExposureCompensation(
        _ value: EvComp, admission: DJICommandAdmission,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { onStage(.notSent) }
    public func writeFocusMode(
        _ value: OpenCineCameraVocabulary.FocusMode, admission: DJICommandAdmission,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { onStage(.notSent) }
    public func writeZoom(
        _ ratio: Double, admission: DJICommandAdmission,
        onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { onStage(.notSent) }
    public func takePhoto(admission: DJICommandAdmission) {}
    public func setISO(
        _ index: IsoIndex, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) { onStage?(.notSent) }
    public func setRecording(
        _ start: Bool, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) { onStage?(.notSent) }
    public func setWhiteBalanceAuto(
        tint: Int?, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) { onStage?(.notSent) }
    public func setWhiteBalanceCustom(
        kelvin: Int, tint: Int, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) { onStage?(.notSent) }
}

extension CameraStatus {
    /// Colour mode whose ISO lists apply. Photo must not reuse leftover Video color.
    public var isoPresentationColor: ColorMode { isPhoto ? .normal : (colorMode ?? .normal) }

    /// ISO wheel indices: the camera's capability push, else the colour mode's list.
    public var isoWheelIndices: [IsoIndex] {
        CamCapIso.wheelIndices(
            available: availableIsoIndices, fallback: isoPresentationColor.isoIndices)
    }
}

/// `OpenCineCore.CameraSession` over the Pocket session for the CORE-02 slice: ISO, white
/// balance and record start/stop. DUML, raw modes and ACK rules stay here and in
/// `CameraSession`; callers get common values and receipts that never claim more than the
/// camera reported.
///
/// One adapter per app session object (`session.control` in Pocket). The control epoch advances
/// whenever the datalink is replaced (connect, repair, another camera), so a command built
/// against one link can never reach the next, and work in flight on the old link ends as
/// `.outcomeUnknown` or `.failed(.notSent)`.
@MainActor
public final class DJICameraSessionAdapter: OpenCineCore.CameraSession {
    public nonisolated static let integration = IntegrationID("org.opencapture.openpocketcine.dji")

    public nonisolated let id: CameraSessionID
    /// ACK to camera-reported value. Record telemetry trails its ACK by about 1 s.
    // ponytail: hand-picked; tune against Pocket 3 / Pocket 4 record telemetry on hardware.
    public var readbackTimeout: Duration = .seconds(3)
    /// Admission to ACK or settle: the coalesce hold plus `CameraSession`'s 2 s settle window.
    /// A request the session dropped without a word ends here instead of hanging.
    public var wireTimeout: Duration = .seconds(4)

    private unowned let session: any DJIControlPort
    private let onClose: (@MainActor (SessionCloseReason) -> Void)?
    private var snapshot: CameraSnapshot
    /// The port state `snapshot` was mapped from. A read with the same state reuses it.
    private var mappedInputs: SnapshotInputs?
    /// Snapshot mappings run so far. A test holds repeated reads to one mapping per state change.
    private(set) var snapshotBuilds = 0
    private var epoch = ControlEpoch(1)
    private var attempt = ConnectionAttemptID()
    private var closed = false
    // ponytail: receipts live as long as the session (Core contract); prune finished ones if
    // a long shoot ever makes this measurable.
    private var receipts: [OperationID: CommandReceipt] = [:]
    private var open: [OperationID: Expectation] = [:]
    private var subscribers: [UUID: AsyncStream<CameraSnapshot>.Continuation] = [:]
    private var waiters: [OperationID: [UUID: CheckedContinuation<CommandReceipt?, Never>]] = [:]

    private struct Expectation {
        var deadline: MonotonicInstant
        /// The camera-reported status shows the request.
        let shows: (CameraStatus) -> Bool
        var permitsReportBeforeAck = false
    }

    /// The shared host clock (`MonotonicInstant.now`); tests inject their own.
    private let now: @Sendable () -> MonotonicInstant

    public convenience init(
        session: any DJIControlPort,
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now
    ) {
        self.init(session: session, now: now, onClose: nil)
    }

    /// A connection owner may retire its native transport when this seam closes.
    /// Borrowed presentation must release its lease without closing the seam.
    public init(
        session: any DJIControlPort,
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now,
        onClose: (@MainActor (SessionCloseReason) -> Void)?
    ) {
        let id = CameraSessionID()
        self.id = id
        self.session = session
        self.now = now
        self.onClose = onClose
        snapshot = CameraSnapshot(session: id, epoch: ControlEpoch(1))
    }

    /// The snapshot of the session right now. SwiftUI bodies read this many times per frame
    /// (OPENPOCKETCINE-IOS-44: a 27 s hang rebuilding it from a capture readout body), so it is
    /// mapped again only when something the mapping reads has changed.
    public var current: CameraSnapshot {
        refresh()
        return snapshot
    }

    // MARK: UI entry points

    /// One intent against a fresh snapshot: what every control in the app submits.
    @discardableResult
    public func request(_ intent: CameraCommandIntent) -> CommandReceipt {
        send(CameraCommand(intent, preconditions: CommandPreconditions(current)))
    }
    @discardableResult
    public func request(_ intent: CameraCommandIntent, admission: DJICommandAdmission)
        -> CommandReceipt
    {
        send(
            CameraCommand(intent, preconditions: CommandPreconditions(current)),
            suppliedAdmission: admission)
    }

    /// Record lamp, gamepad, Watch and watcher toggles. Photo fires a still; video resolves to
    /// an explicit start or stop from a fresh snapshot, never a blind toggle (plan 5.4).
    @discardableResult
    public func shutter() -> CommandReceipt? {
        if session.currentShootingMode?.isPhoto == true {
            session.takePhoto()
            return nil
        }
        return request(current.recording.value == .recording ? .stopRecording : .startRecording)
    }
    @discardableResult
    public func shutter(admission: DJICommandAdmission) -> CommandReceipt? {
        guard admission.admits(session.commandOwner) else { return nil }
        if session.currentShootingMode?.isPhoto == true {
            session.takePhoto(admission: admission)
            return nil
        }
        return request(
            current.recording.value == .recording ? .stopRecording : .startRecording,
            admission: admission)
    }

    // MARK: Session hooks

    /// Status or phase changed. Cheap unless someone listens or a request awaits readback.
    public func sessionDidChange() {
        guard !closed else { return }
        if !subscribers.isEmpty { refresh() }
        guard !open.isEmpty else { return }
        let status = session.status
        for (operation, expectation) in open
        where
            (receipts[operation]?.stage == .awaitingObservation
            || (expectation.permitsReportBeforeAck && receipts[operation]?.stage == .sent))
            && expectation.shows(status)
        {
            finish(operation, .confirmed)
        }
    }

    /// The datalink was replaced or dropped. Requests on the old link cannot be followed.
    public func linkDidChange() {
        guard !closed else { return }
        epoch = epoch.next()
        for operation in open.keys { abandon(operation) }
        if !subscribers.isEmpty { refresh() }
    }

    // MARK: OpenCineCore.CameraSession

    public func snapshots() -> AsyncStream<CameraSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: CameraSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(current)
        if closed {
            continuation.finish()
        } else {
            subscribers[UUID()] = continuation
        }
        return stream
    }

    public func submit(_ command: CameraCommand) -> CommandReceipt { send(command) }
    public func submit(_ command: CameraCommand, admission: DJICommandAdmission) -> CommandReceipt {
        send(command, suppliedAdmission: admission)
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

    /// Retires this seam and invokes the optional connection-owner callback once.
    /// The adapter never sends a camera command or stops a recording.
    public func close(_ reason: SessionCloseReason) {
        guard !closed else { return }
        for operation in open.keys { abandon(operation) }
        closed = true
        snapshot.connection = .disconnected(reason)
        snapshot.authority = .unavailable(.link)
        snapshot.revision = snapshot.revision.next()
        for continuation in subscribers.values {
            continuation.yield(snapshot)
            continuation.finish()
        }
        subscribers.removeAll()
        onClose?(reason)
    }

    // MARK: Commands

    @discardableResult
    func send(_ command: CameraCommand) -> CommandReceipt {
        send(command, suppliedAdmission: nil)
    }
    private func send(_ command: CameraCommand, suppliedAdmission admission: DJICommandAdmission?)
        -> CommandReceipt
    {
        let operation = command.operation
        if let known = receipts[operation] { return known }
        let snapshot = current
        receipts[operation] = CommandReceipt(
            operation: operation, session: id, intent: command.intent,
            confirmation: snapshot.capabilities[command.intent.key]?.semantics.confirmation
                ?? .readback)
        if let admission, !admission.admits(session.commandOwner) {
            return advance(operation, .rejected(.authorityExpired))
        }
        if let rejection = snapshot.rejection(of: command, at: now())
            ?? Self.integrationRejection(command.intent, snapshot)
        {
            noteRejection(rejection)
            return advance(operation, .rejected(rejection))
        }
        advance(operation, .admitted)
        if Self.alreadyReported(command.intent, snapshot) {
            return advance(operation, .confirmed)
        }
        guard let plan = wirePlan(command.intent, admission: admission) else {
            return advance(operation, .rejected(.unsupported))
        }
        open[operation] = Expectation(
            deadline: now() + wireTimeout, shows: plan.shows,
            permitsReportBeforeAck: plan.requiresReport)
        expire(after: wireTimeout)
        plan.fire { [weak self] event in
            self?.handle(
                plan.requiresReport && event == .confirmed ? .acknowledged : event, operation)
        }
        return receipts[operation]!
    }

    private struct WirePlan {
        let shows: (CameraStatus) -> Bool
        let fire: (@escaping @MainActor (ControlWireEvent) -> Void) -> Void
        var requiresReport = false
    }

    /// Common intent to the DUML call that carries it, plus what the camera's own status must
    /// show afterwards. Admission already checked the value against the declared domain. DJI
    /// sends white balance and tint in one frame, so each write fills the other half from the
    /// current (or pending) white balance.
    private func wirePlan(_ intent: CameraCommandIntent, admission: DJICommandAdmission?)
        -> WirePlan?
    {
        let session = session
        let display = session.whiteBalanceDisplayStatus
        switch intent {
        case .set(.shutter(.duration(let duration))):
            guard duration.numerator == 1,
                let denominator = Int(exactly: duration.denominator), denominator > 0
            else { return nil }
            return WirePlan(
                shows: { _ in session.captureControlState?.reported.shutterDenom == denominator },
                fire: {
                    if let admission {
                        session.writeShutter(denominator, admission: admission, onStage: $0)
                    } else {
                        session.writeShutter(denominator, onStage: $0)
                    }
                }, requiresReport: true)
        case .set(.shutter(.angle(let degrees))):
            guard let state = session.captureControlState, state.emulatesShutterAngle,
                let denominator = HostShutterAngle.denominator(degrees: degrees,
                    framesPerSecond: state.reported.fps > 0 ? Double(state.reported.fps) : nil,
                    available: state.offeredShutterDenoms) else { return nil }
            return WirePlan(
                shows: { _ in session.captureControlState?.reported.shutterDenom == denominator },
                fire: { session.writeHostShutterAngle(degrees, denominator: denominator,
                    admission: admission, onStage: $0) }, requiresReport: true)
        case .set(.exposureCompensation(let stops)):
            guard
                let value = EvComp.allCases.first(where: {
                    Rational($0.thirds, 3) == stops
                })
            else { return nil }
            return WirePlan(
                shows: { _ in session.captureControlState?.reported.evComp == value },
                fire: {
                    if let admission {
                        session.writeExposureCompensation(value, admission: admission, onStage: $0)
                    } else {
                        session.writeExposureCompensation(value, onStage: $0)
                    }
                },
                requiresReport: true)
        case .set(.focusMode(let mode)):
            let value: OpenCineCameraVocabulary.FocusMode
            switch mode {
            case .single: value = .single
            case .continuous: value = .continuous
            case .manual: return nil
            }
            return WirePlan(
                shows: { _ in session.captureControlState?.reported.focusMode == value },
                fire: {
                    if let admission {
                        session.writeFocusMode(value, admission: admission, onStage: $0)
                    } else {
                        session.writeFocusMode(value, onStage: $0)
                    }
                }, requiresReport: true)
        case .set(.zoom(let ratio)):
            return WirePlan(
                shows: { _ in
                    session.captureControlState?.reported.zoomFactor.map {
                        CamFov.matches($0, ratio)
                    } ?? false
                },
                fire: {
                    if let admission {
                        session.writeZoom(ratio, admission: admission, onStage: $0)
                    } else {
                        session.writeZoom(ratio, onStage: $0)
                    }
                }, requiresReport: true)
        case .set(.iso(let value)):
            guard let index = Self.isoIndex(value) else { return nil }
            return WirePlan(
                shows: { $0.isoIndex == index },
                fire: {
                    if let admission {
                        session.setISO(index, admission: admission, onStage: $0)
                    } else {
                        session.setISO(index, onStage: $0)
                    }
                })
        case .set(.whiteBalanceTint(let tint)):
            guard let wb = display.whiteBalance else { return nil }
            return whiteBalancePlan(Self.whiteBalance(wb), tint: Int(tint), admission: admission)
        case .set(.whiteBalance(let value)):
            return whiteBalancePlan(
                value, tint: display.whiteBalanceTint ?? 0, admission: admission)
        case .startRecording, .stopRecording:
            let start = intent == .startRecording
            return WirePlan(
                shows: { $0.recordingReported && $0.isRecording == start },
                fire: {
                    if let admission {
                        session.setRecording(start, admission: admission, onStage: $0)
                    } else {
                        session.setRecording(start, onStage: $0)
                    }
                })
        case .set, .focusPoint:
            return nil
        }
    }

    private func whiteBalancePlan(
        _ value: WhiteBalanceValue, tint: Int, admission: DJICommandAdmission?
    ) -> WirePlan? {
        let session = session
        let t = min(max(tint, -100), 100)
        switch value {
        case .auto:
            let wb = WhiteBalance.auto(tint: t)
            return WirePlan(
                shows: { $0.whiteBalance == wb },
                fire: {
                    if let admission {
                        session.setWhiteBalanceAuto(tint: t, admission: admission, onStage: $0)
                    } else {
                        session.setWhiteBalanceAuto(tint: t, onStage: $0)
                    }
                })
        case .kelvin(let kelvin):
            let wb = WhiteBalance.custom(kelvin: min(max(kelvin, 2_000), 10_000), tint: t)
            return WirePlan(
                shows: { $0.whiteBalance == wb },
                fire: {
                    if let admission {
                        session.setWhiteBalanceCustom(
                            kelvin: wb.kelvin, tint: t, admission: admission, onStage: $0)
                    } else {
                        session.setWhiteBalanceCustom(kelvin: wb.kelvin, tint: t, onStage: $0)
                    }
                }
            )
        case .preset:
            return nil
        }
    }

    private func handle(_ event: ControlWireEvent, _ operation: OperationID) {
        // A finished receipt is final: a late ACK never rewrites an outcome.
        guard open[operation] != nil else { return }
        switch event {
        case .notSent:
            finish(operation, .failed(.notSent))
        case .sent:
            advance(operation, .sent)
        case .acknowledged:
            advance(operation, .accepted)
            if open[operation]?.shows(session.status) == true {
                finish(operation, .confirmed)
            } else {
                advance(operation, .awaitingObservation)
                open[operation]?.deadline = now() + readbackTimeout
                expire(after: readbackTimeout)
            }
        case .confirmed:
            // The session's own match is looser for ISO (applied value); this one decides.
            let shown = open[operation]?.shows(session.status) == true
            finish(operation, shown ? .confirmed : .timedOut)
        case .refused:
            finish(operation, .rejected(.cameraRefused))
        case .unconfirmed:
            finish(operation, .timedOut)
        }
    }

    /// The DJI record frames are value-shaped (`0x02/0x02` 01/00) but the app has only ever
    /// sent them as a toggle of the reported state; how a body answers a start while it is
    /// already recording is not hardware-qualified. Unknown state is refused.
    private static func integrationRejection(
        _ intent: CameraCommandIntent, _ snapshot: CameraSnapshot
    ) -> CommandRejection? {
        switch intent {
        case .startRecording, .stopRecording:
            snapshot.recording.isKnown ? nil : .recordingStateUnknown
        case .set, .focusPoint:
            nil
        }
    }

    /// Idempotency: a start while the camera reports recording (or a stop while idle) finishes
    /// without touching the wire, so a retry can never undo the first success.
    private static func alreadyReported(_ intent: CameraCommandIntent, _ snapshot: CameraSnapshot)
        -> Bool
    {
        switch intent {
        case .startRecording: snapshot.recording.value == .recording
        case .stopRecording: snapshot.recording.value == .idle
        case .set, .focusPoint: false
        }
    }

    private func noteRejection(_ rejection: CommandRejection) {
        switch rejection {
        case .sessionClosed, .wrongSession, .notConnected, .staleEpoch, .noAuthority:
            session.controlNote = "not live"
        case .recordingStateUnknown:
            session.controlNote = "Waiting for the camera's record state"
        default:
            break
        }
    }

    private func expire(after delay: Duration) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.expireOverdue()
        }
    }

    private func expireOverdue() {
        let instant = now()
        for (operation, expectation) in open where expectation.deadline <= instant {
            if receipts[operation]?.stage == .awaitingObservation {
                finish(operation, .timedOut)
            } else {
                abandon(operation)
            }
        }
    }

    /// Unsent work fails; sent work may have reached the camera, so its outcome is unknown.
    private func abandon(_ operation: OperationID) {
        switch receipts[operation]?.stage {
        case .created?, .admitted?: finish(operation, .failed(.notSent))
        default: finish(operation, .outcomeUnknown)
        }
    }

    @discardableResult
    private func finish(_ operation: OperationID, _ stage: CommandStage) -> CommandReceipt {
        open[operation] = nil
        return advance(operation, stage)
    }

    @discardableResult
    private func advance(_ operation: OperationID, _ stage: CommandStage) -> CommandReceipt {
        receipts[operation]?.stage = stage
        let receipt = receipts[operation]!
        if receipt.isFinished, let waiting = waiters.removeValue(forKey: operation) {
            for continuation in waiting.values { continuation.resume(returning: receipt) }
        }
        return receipt
    }

    private func stopWaiting(_ operation: OperationID, _ token: UUID) {
        waiters[operation]?.removeValue(forKey: token)?.resume(returning: receipts[operation])
    }

    // MARK: Snapshot mapping (raw DJI status to common values)

    /// Everything the mapping reads from the port, plus the control epoch.
    private struct SnapshotInputs: Equatable {
        var epoch: ControlEpoch
        var status: CameraStatus
        var cameraID: String?
        var model: CameraModel?
        var link: DJILinkState
        var admitsControl: Bool
        var busy: Bool
        var capture: DJICaptureControlState?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.epoch == rhs.epoch && lhs.status == rhs.status && lhs.cameraID == rhs.cameraID
                && lhs.model == rhs.model && lhs.link == rhs.link
                && lhs.admitsControl == rhs.admitsControl && lhs.busy == rhs.busy
                && lhs.capture?.reported == rhs.capture?.reported
                && lhs.capture?.model == rhs.capture?.model
                && lhs.capture?.shutterPresentation == rhs.capture?.shutterPresentation
        }
    }

    /// Maps the port's state when it differs from what `snapshot` was mapped from.
    private func refresh() {
        guard !closed else { return }
        let inputs = SnapshotInputs(
            epoch: epoch, status: session.status, cameraID: session.connectedCameraID,
            model: session.connectedModel, link: session.link,
            admitsControl: session.admitsMultiviewControl, busy: session.isBusy,
            capture: session.captureControlState)
        guard inputs != mappedInputs else { return }
        mappedInputs = inputs
        rebuild(inputs)
    }

    private func rebuild(_ inputs: SnapshotInputs) {
        snapshotBuilds += 1
        let status = inputs.status
        let capture = inputs.capture
        var next = snapshot
        next.epoch = inputs.epoch
        next.device = inputs.cameraID.map { .durable($0, integration: Self.integration) }
        next.connection = connection(inputs.link)
        next.authority =
            next.connection != .ready
            ? .unavailable(.link)
            : inputs.admitsControl ? .owner : .unavailable(.authority)
        next.mode = Self.mode(status)
        next.recordingFormat = DJIRecordingObservations.recording(capture?.reported ?? status,
            labels: inputs.model?.captureProfile?.labels ?? .standard)
        next.exposureProgram = DJIRecordingObservations.exposureProgram(capture?.reported ?? status)
        next.settings = Self.settings(status)
        if let capture {
            next.settings.merge(capture.settings) { _, report in report }
        }
        next.recording =
            status.recordingReported
            ? ObservedValue(
                status.isRecording ? .recording : .idle, origin: .cameraReported, at: nil)
            : .unknown
        next.power = Self.power(status)
        next.storage = Self.storage(status)
        next.timecode = status.timecodeValue.map { ObservedValue($0, origin: .cameraReported, at: nil) } ?? .unknown
        next.audioLevels =
            status.audioMeters.map {
                ObservedValue(Self.audioLevels($0), origin: .cameraReported, at: nil)
            } ?? .unknown
        let model = inputs.model
        let declared = CapabilitySnapshot(
            revision: snapshot.capabilities.revision,
            descriptors: descriptors(status, busy: inputs.busy) + (capture?.descriptors ?? []),
            unsupported: Self.unsupported(model), timecodeCapability: Self.timecodeCapability(model),
            audioLevels: Self.audioLevelsSupport(model))
        if declared != snapshot.capabilities {
            next.capabilities = declared
            next.capabilities.revision = declared.revision.next()
        }
        guard next != snapshot else { return }
        next.revision = snapshot.revision.next()
        snapshot = next
        for (token, continuation) in subscribers {
            if case .terminated = continuation.yield(snapshot) { subscribers[token] = nil }
        }
    }

    private func connection(_ link: DJILinkState) -> ConnectionState {
        if link == .ready { return .ready }
        let continuing: Bool
        switch snapshot.connection {
        case .connecting, .recovering: continuing = true
        default: continuing = false
        }
        if !continuing { attempt = ConnectionAttemptID() }
        switch link {
        case .ready:
            return .ready
        case .recovering:
            return .recovering(attempt)
        case .connecting(let phase):
            return .connecting(attempt, phase)
        case .notLinked:
            // Core has no "open but not linked" state; this session object outlives links.
            return .discovered
        }
    }

    /// Declared support is exactly what `wirePlan` routes. A test holds the two together.
    private func descriptors(_ status: CameraStatus, busy: Bool) -> [SettingDescriptor] {
        var iso = status.isoWheelIndices.map { SettingValue.iso(Self.iso($0)) }
        if status.isoPresentationColor.offersIsoAuto, !iso.contains(.iso(.auto)) {
            iso.insert(.iso(.auto), at: 0)
        }
        let recording: Availability =
            status.isPhoto
            ? .unavailable(.mode)
            : busy ? .unavailable(.busy) : .available
        return [
            SettingDescriptor(.iso, domain: SettingDomain(choices: iso)),
            SettingDescriptor(
                .whiteBalance,
                domain: SettingDomain(
                    choices: [.whiteBalance(.auto)], range: 2_000...10_000, step: 100)),
            // Tint rides on the white balance frame, so it needs a known white balance.
            SettingDescriptor(
                .whiteBalanceTint, domain: SettingDomain(range: -100...100, step: 1),
                availability: status.whiteBalance == nil
                    ? .unavailable(.otherSetting(.whiteBalance)) : .available),
            SettingDescriptor(.recording, availability: recording),
        ]
    }

    /// What the connected body cannot do, from the same flags the app uses to hide the control
    /// (fixed aperture on Pocket and Nano, no AF or zoom outside the Pocket family). Unknown body:
    /// nothing is claimed.
    static func unsupported(_ model: CameraModel?) -> Set<SettingKey> {
        guard let model else { return [] }
        var keys: Set<SettingKey> = []
        if !model.supportsAperture { keys.insert(.aperture) }
        if !model.supportsFocusMode { keys.insert(.focusMode) }
        if !model.supportsTapFocus { keys.insert(.focusPoint) }
        if !model.supportsZoom { keys.insert(.zoom) }
        return keys
    }

    /// Every body reports `timecode_info` except Nano, whose live and Multi View readouts never
    /// showed one. Unknown body: unknown. Declared in whole seconds: the frame field rides the
    /// throttled status push and is not proven to count per frame (A5 runtime check).
    @available(*, deprecated, message: "Use timecodeCapability for declared precision.")
    static func timecodeSupport(_ model: CameraModel?) -> SupportStatus {
        timecodeCapability(model).support
    }

    static func timecodeCapability(_ model: CameraModel?) -> TimecodeCapability {
        guard let model else { return .unknown }
        return model.family == .nano ? .unsupported : .supported(.seconds)
    }

    /// The legacy frame-complete parser; a partial clock has no representable frame count.
    @available(*, deprecated, message: "Use CameraStatus.timecodeReading for source precision.")
    static func timecode(_ raw: String?) -> CameraTimecode? {
        guard let parts = raw?.split(separator: ":").compactMap({ Int($0) }), parts.count == 4
        else { return nil }
        return CameraTimecode(
            hours: parts[0], minutes: parts[1], seconds: parts[2], frames: parts[3])
    }

    /// `cam_audio_status_v2` levels. Unknown body: unknown.
    // ponytail: every body the app connects to has always shown the meter; narrow this per
    // body once one is captured without `cam_audio_status_v2`.
    static func audioLevelsSupport(_ model: CameraModel?) -> SupportStatus {
        model == nil ? .unknown : .supported
    }

    /// The camera-held meter in dBFS. `AudioMeterChannel.peakAge` is display ballistics, not a
    /// camera report, so it does not cross.
    static func audioLevels(_ meters: AudioMeterLevels) -> AudioLevels {
        AudioLevels(
            left: .init(level: meters.left.levelDB, peak: meters.left.peakDB),
            right: .init(level: meters.right.levelDB, peak: meters.right.peakDB))
    }

    static func iso(_ index: IsoIndex) -> ISOValue {
        index.isoValue.map(ISOValue.manual) ?? .auto
    }

    static func isoIndex(_ value: ISOValue) -> IsoIndex? {
        switch value {
        case .auto: .auto
        case .manual(let iso): IsoIndex.allCases.first { $0.isoValue == iso }
        case .autoLimited: nil
        }
    }

    static func whiteBalance(_ wb: WhiteBalance) -> WhiteBalanceValue {
        wb.mode == .auto ? .auto : .kelvin(wb.kelvin)
    }

    private static func mode(_ status: CameraStatus) -> ObservedValue<CaptureMode> {
        guard status.shootingMode >= 0 else { return .unknown }
        let raw = status.shootingMode
        let known = ShootingMode.fromStatus(raw)
        let mode = CaptureMode(
            role: known.map { $0.isPhoto ? .photo : .video } ?? .other,
            id: "\(integration.rawValue).mode.\(raw)", title: known?.label ?? "Mode \(raw)")
        return ObservedValue(mode, origin: .cameraReported, at: nil)
    }

    private static func settings(_ status: CameraStatus) -> [SettingKey: ObservedValue<
        SettingValue
    >] {
        var settings: [SettingKey: ObservedValue<SettingValue>] = [:]
        if let index = status.isoIndex {
            settings[.iso] = ObservedValue(.iso(iso(index)), origin: .cameraReported, at: nil)
        }
        if let wb = status.whiteBalance {
            settings[.whiteBalance] = ObservedValue(
                .whiteBalance(whiteBalance(wb)), origin: .cameraReported, at: nil)
            settings[.whiteBalanceTint] = ObservedValue(
                .whiteBalanceTint(Double(wb.tint)), origin: .cameraReported, at: nil)
        }
        return settings
    }

    private static func power(_ status: CameraStatus) -> PowerStatus {
        var power = PowerStatus.unknown
        if (0...100).contains(status.batteryPercent) {
            power.battery = ObservedValue(
                Double(status.batteryPercent) / 100, origin: .cameraReported, at: nil,
                precision: .quantized(step: 0.01))
        }
        if let charging = status.chargingReading {
            power.charging = ObservedValue(charging, origin: .cameraReported, at: nil)
        }
        return power
    }

    static func storage(_ status: CameraStatus) -> StorageStatus {
        let readout = status.storageReadout
        let remaining = status.recordRemainingSec > 0 ? Duration.seconds(status.recordRemainingSec) : nil
        guard readout != nil || remaining != nil else { return .unknown }
        return ObservedValue([StorageVolume(
            id: "active",
            freeBytes: readout.map { ObservedValue($0.freeBytes, origin: .cameraReported, at: nil) } ?? .unknown,
            totalBytes: readout?.totalBytes.map { ObservedValue($0, origin: .cameraReported, at: nil) } ?? .unknown,
            remainingRecordingTime: remaining.map { ObservedValue($0, origin: .cameraReported, at: nil) } ?? .unknown
        )], origin: .cameraReported, at: nil)
    }
}

extension DJICameraSessionAdapter {
    /// The one control model for the connected body: its declared profile and motion merged with
    /// the live capabilities. `codecColor` is what the codec and colour popup lists now, when the
    /// host has it. With no body known only the live snapshot speaks.
    public func controlCapabilities(codecColor: CaptureCodecColorChoices? = nil) -> ControlCapabilities {
        let model = session.connectedModel
        return ControlCapabilities(snapshot: current.capabilities, profile: model?.captureProfile,
            motion: model?.motion, codecColor: codecColor)
    }

    /// What a monitor lays out for the connected body: the Core projection of `current` plus the
    /// body's motion (`CameraModel.motion`). `base` carries what Core has no vocabulary for yet.
    /// With no body known, motion stays unknown and the Core projection keeps `base`.
    public func layout(base: MonitorLayoutCapabilities = .init()) -> MonitorLayoutCapabilities {
        let capabilities = current.capabilities
        guard let model = session.connectedModel else {
            return MonitorLayoutCapabilities(capabilities, base: base)
        }
        var layout = MonitorLayoutCapabilities(capabilities, motion: model.motion, base: base)
        if session.captureControlState == nil {
            // Compatibility for callers that have not supplied the additive capture port.
            layout.zoom = model.supportsZoom
            layout.focus = model.supportsFocusMode
        }
        // Variable iris strategy is a typed integration panel, not an f-number edit.
        layout.iris = model.supportsAperture
        return layout
    }
}

/// DJI-typed entry points for this app's own controls. They only translate the raw value;
/// admission, the wire call and the receipt are the seam's (`request`).
extension DJICameraSessionAdapter {
    @discardableResult
    public func setISO(_ index: IsoIndex) -> CommandReceipt {
        request(.set(.iso(Self.iso(index))))
    }

    @discardableResult
    public func setISO(_ index: IsoIndex, admission: DJICommandAdmission) -> CommandReceipt {
        request(.set(.iso(Self.iso(index))), admission: admission)
    }

    /// `nil` keeps the current (or pending) tint, as the Auto row always has.
    @discardableResult
    public func setWhiteBalanceAuto(tint: Int? = nil) -> CommandReceipt {
        setWhiteBalance(.auto, tint: tint)
    }

    @discardableResult
    public func setWhiteBalanceAuto(tint: Int? = nil, admission: DJICommandAdmission)
        -> CommandReceipt
    {
        setWhiteBalance(.auto, tint: tint, suppliedAdmission: admission)
    }

    /// Kelvin snaps to the 100 K drum the camera stores (`K/100` on the wire).
    @discardableResult
    public func setWhiteBalanceCustom(kelvin: Int, tint: Int) -> CommandReceipt {
        setWhiteBalance(
            .kelvin(WhiteBalance.snappedKelvin(min(max(kelvin, 2_000), 10_000))), tint: tint)
    }

    @discardableResult
    public func setWhiteBalanceCustom(kelvin: Int, tint: Int, admission: DJICommandAdmission)
        -> CommandReceipt
    {
        setWhiteBalance(
            .kelvin(WhiteBalance.snappedKelvin(min(max(kelvin, 2_000), 10_000))), tint: tint,
            suppliedAdmission: admission)
    }

    /// One Core write per setting that changes: white balance (keeping the pending tint), then
    /// tint (on the pending white balance). Returns the last receipt.
    private func setWhiteBalance(_ value: WhiteBalanceValue, tint: Int?) -> CommandReceipt {
        setWhiteBalance(value, tint: tint, suppliedAdmission: nil)
    }

    private func setWhiteBalance(
        _ value: WhiteBalanceValue, tint: Int?, suppliedAdmission admission: DJICommandAdmission?
    ) -> CommandReceipt {
        func write(_ value: SettingValue) -> CommandReceipt {
            if let admission { return request(.set(value), admission: admission) }
            return request(.set(value))
        }
        let pending = session.whiteBalanceDisplayStatus.whiteBalance
        guard let tint = tint.map({ min(max($0, -100), 100) }), tint != pending?.tint else {
            return write(.whiteBalance(value))
        }
        if pending.map(Self.whiteBalance) != value { _ = write(.whiteBalance(value)) }
        return write(.whiteBalanceTint(Double(tint)))
    }

    /// A confirmed start or stop: the target the operator approved, not a recomputed toggle.
    @discardableResult
    public func record(start: Bool) -> CommandReceipt {
        request(start ? .startRecording : .stopRecording)
    }
}

/// The camera control a remote surface (Apple Watch, watcher relay, a record confirmation) was
/// showing: one adapter's session and control epoch (STATE-01). A command aimed at a target is
/// refused (`.wrongSession` / `.staleEpoch`) once the app holds another camera session or another
/// link, instead of acting on whatever the app's current session is at that moment.
public struct ControlTarget: Hashable, Sendable {
    fileprivate let session: CameraSessionID
    fileprivate let epoch: ControlEpoch

    /// Same camera session, any link: what a long-lived relay is bound to.
    public func isSameSession(as other: ControlTarget) -> Bool { session == other.session }
}

extension DJICameraSessionAdapter {
    public var target: ControlTarget { ControlTarget(session: id, epoch: epoch) }

    /// `request` with the preconditions of what `target` showed, not of a fresh snapshot.
    @discardableResult
    public func request(_ intent: CameraCommandIntent, aimedAt target: ControlTarget)
        -> CommandReceipt
    {
        request(intent, aimedAt: target, suppliedAdmission: nil)
    }

    @discardableResult
    public func request(
        _ intent: CameraCommandIntent, aimedAt target: ControlTarget, admission: DJICommandAdmission
    ) -> CommandReceipt {
        request(intent, aimedAt: target, suppliedAdmission: admission)
    }

    private func request(
        _ intent: CameraCommandIntent, aimedAt target: ControlTarget,
        suppliedAdmission admission: DJICommandAdmission?
    ) -> CommandReceipt {
        let snapshot = current
        return send(
            CameraCommand(
                intent,
                preconditions: CommandPreconditions(
                    session: target.session, epoch: target.epoch,
                    capabilityRevision: snapshot.capabilities.revision,
                    lease: snapshot.authority.leaseID)), suppliedAdmission: admission)
    }

    /// `shutter()` aimed at `target`. A still fires only while `target` holds; otherwise the
    /// record request is refused at admission and nothing reaches the camera.
    @discardableResult
    public func shutter(aimedAt target: ControlTarget) -> CommandReceipt? {
        if session.currentShootingMode?.isPhoto == true, self.target == target {
            session.takePhoto()
            return nil
        }
        let recording = current.recording.value == .recording
        return request(recording ? .stopRecording : .startRecording, aimedAt: target)
    }

    @discardableResult
    public func shutter(aimedAt target: ControlTarget, admission: DJICommandAdmission)
        -> CommandReceipt?
    {
        if session.currentShootingMode?.isPhoto == true, self.target == target,
            admission.admits(session.commandOwner)
        {
            session.takePhoto(admission: admission)
            return nil
        }
        let recording = current.recording.value == .recording
        return request(
            recording ? .stopRecording : .startRecording, aimedAt: target, admission: admission)
    }

    /// A confirmed start or stop, refused if the approval was given for another session or link.
    @discardableResult
    public func record(start: Bool, aimedAt target: ControlTarget?) -> CommandReceipt {
        guard let target else { return record(start: start) }
        return request(start ? .startRecording : .stopRecording, aimedAt: target)
    }

    @discardableResult
    public func record(
        start: Bool, aimedAt target: ControlTarget?, admission: DJICommandAdmission
    ) -> CommandReceipt {
        let intent: CameraCommandIntent = start ? .startRecording : .stopRecording
        guard let target else { return request(intent, admission: admission) }
        return request(intent, aimedAt: target, admission: admission)
    }
}

extension CommandReceipt {
    /// Finished without the camera acting: refused at admission or by the camera, or not sent.
    public var didNotAct: Bool {
        switch stage {
        case .rejected, .failed: true
        default: false
        }
    }

    /// Refused because the command was aimed at another session or an older link.
    public var targetChanged: Bool {
        stage == .rejected(.wrongSession) || stage == .rejected(.staleEpoch)
    }
}
