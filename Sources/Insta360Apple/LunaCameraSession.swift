import Foundation
import Insta360Protocol
import OpenCineCore
import OpenCineMedia
import OpenCineMotion

/// The OpenCineCore session for one Luna camera: the single command path for its common
/// controls and the only source of their reported state.
///
/// Common controls: link and status, ISO, shutter, white balance, lens and explicit record start/stop.
/// ISO and shutter travel in one Luna exposure message (program + ISO + shutter), so the
/// session owns both and composes each write from the other's pending or reported value.
///
/// Luna settles slowly and not always: a SET is acknowledged at once, but the stored value can
/// change seconds later (fw 1.1.15 stores WB Kelvin 3.5 to 3.9 s after the SET) or never (fw
/// 1.1.15 drops the ISO when the ISO top-limit sentinel rides along). An acknowledged write
/// therefore stays `awaitingObservation` until a readback shows it (`confirmed`). When the
/// settle window closes, a readback that still disagrees ends it `failed(.notApplied)`; no
/// readback at all ends it `timedOut`. Nothing is ever written into the snapshot on request.
@MainActor
public final class LunaCameraSession: OpenCineCore.CameraSession {
    public nonisolated static let integration = IntegrationID("com.opencapture.insta360.luna")
    /// Official Video ISO wheel.
    public nonisolated static let isoValues = [100, 160, 200, 400, 800, 1600, 3200, 6400]
    /// What every Luna body lacks: a fixed-aperture lens (MULTI-03 F6). Other undescribed keys stay
    /// unknown.
    public nonisolated static let unsupported: Set<SettingKey> = [.aperture]
    /// What Luna Ultra (fw 1.1.15) declares to shared motion: handle-frame pan and tilt
    /// (cmd 226 SET_ANGLE), pitch -57...90, yaw one arc from about -125 through 180 to -58.5
    /// (unwrapped -58.5...235), no zoom in moves, no client rate cap (each SET re-plans), its
    /// GET_ANGLE is the pose (older than 0.3 s is not feedback), aim ends within 0.5 degrees.
    public nonisolated static let motion = MotionCapabilities(
        axes: [.pan, .tilt], frame: .handle,
        bounds: MotionBounds(pan: -58.5...235, tilt: -57...90),
        maxRateDegPerSec: nil, feedbackMaxAge: .milliseconds(300), arrivalToleranceDeg: 0.5,
        pose: .supported)
    /// Official Video shutter wheel, slowest last. fw 1.1.15 adds 1/15 to 1/5.
    public nonisolated static let shutterDenominators = [
        8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250,
        200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 15, 10, 5,
    ]

    /// How long an acknowledged write may take to show in readback, and how often to ask.
    /// ponytail: settle windows are the pin windows the app used plus readback margin; tune them
    /// on hardware (record stop includes the file save).
    public struct Timing: Sendable {
        public var settle: [SettingKey: Duration]
        public var readbackInterval: Duration

        public init(settle: [SettingKey: Duration], readbackInterval: Duration) {
            self.settle = settle
            self.readbackInterval = readbackInterval
        }

        public static let luna = Timing(
            settle: [
                .iso: .seconds(4), .shutter: .seconds(4), .whiteBalance: .seconds(6),
                .recording: .seconds(10),
            ],
            readbackInterval: .seconds(1))
    }

    public nonisolated let id: CameraSessionID
    public nonisolated let commandOwner = LunaCommandOwner()
    public private(set) var current: CameraSnapshot
    /// Recording colour profile (photography option 35) as a namespaced id. Camera-reported or
    /// unknown; never inferred from the preview. Lives here until `CameraSnapshot` has a slot.
    public private(set) var recordingProfile: ObservedValue<String> = .unknown

    private struct Awaiting {
        var intent: CameraCommandIntent
        var acceptedAt: MonotonicInstant
        var deadline: MonotonicInstant
        var shutterDenominator: Int?
    }

    private let send: @MainActor (LunaRequest) async throws -> Data
    private let sendWithin: (@MainActor (LunaRequest, Duration) async throws -> Data)?
    private let sendAdmitted: LunaAdmittedCommandSend?
    private let sendAdmittedWithin: LunaAdmittedCommandSendWithin?
    private let functionMode: @MainActor () -> UInt32
    private let readSettings: @MainActor () async -> Void
    private let readCapture: @MainActor () async -> Void
    private let timing: Timing
    /// The shared host clock (`MonotonicInstant.now`); tests inject their own.
    private let now: @Sendable () -> MonotonicInstant
    private var shootingMode: LunaShootingMode?
    private var shutterPresentation: HostShutterPresentation = .cameraValue
    private var reportedShutter: ObservedValue<ShutterValue> = .unknown
    private var reportedCadence: ObservedValue<Double> = .unknown
    /// The last card list and when it arrived; option 99 rebuilds the volumes from it.
    private var reportedCards: (cards: [LunaStorage], at: MonotonicInstant)?
    /// Photography option 99: remaining record time per card location, and when it arrived.
    private var reportedRemaining: (seconds: [UInt64: UInt64], at: MonotonicInstant)?
    private var zoomDomain: ClosedRange<Double>?
    /// When each key last had a known camera report.
    private var reportedAt: [SettingKey: MonotonicInstant] = [:]
    private var receipts: [OperationID: CommandReceipt] = [:]
    private var awaiting: [OperationID: Awaiting] = [:]
    /// The newest unfinished write per setting, used to compose the shared exposure message.
    private var targets: [SettingKey: (operation: OperationID, value: SettingValue)] = [:]
    private var subscribers: [UUID: AsyncStream<CameraSnapshot>.Continuation] = [:]
    private var waiters: [OperationID: [UUID: CheckedContinuation<CommandReceipt?, Never>]] = [:]
    let backendCapabilities: @MainActor () -> CameraCapabilities?
    private var pump: Task<Void, Never>?
    private var closed = false

    /// `send` returns the camera's 200 body and throws on a 500 or a lost link; `sendWithin` does
    /// the same within a caller timeout (`control(_:timeout:)`), else a timeout falls back to
    /// `send`. `readSettings` and `readCapture` ask the camera to report again; answers arrive
    /// through `ingest`.
    public init(
        send: @escaping @MainActor (LunaRequest) async throws -> Data,
        sendWithin: (@MainActor (LunaRequest, Duration) async throws -> Data)? = nil,
        functionMode: @escaping @MainActor () -> UInt32,
        readSettings: @escaping @MainActor () async -> Void,
        readCapture: @escaping @MainActor () async -> Void,
        sendAdmitted: LunaAdmittedCommandSend? = nil,
        sendAdmittedWithin: LunaAdmittedCommandSendWithin? = nil,
        timing: Timing = .luna,
        backendCapabilities: @escaping @MainActor () -> CameraCapabilities? = { nil },
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now
    ) {
        let id = CameraSessionID()
        self.id = id
        self.send = send
        self.sendWithin = sendWithin
        self.sendAdmitted = sendAdmitted
        self.sendAdmittedWithin = sendAdmittedWithin
        self.functionMode = functionMode
        self.readSettings = readSettings
        self.readCapture = readCapture
        self.timing = timing
        self.now = now
        self.backendCapabilities = backendCapabilities
        current = CameraSnapshot(session: id, connection: .connecting(ConnectionAttemptID(), .link))
        refreshCapabilities()
    }

    // MARK: - Link and telemetry (from the backend)

    /// The operator's display choice changes no camera setting. Angle emulation uses only
    /// camera-reported native duration and cadence, and remains unavailable without either.
    public func configureShutter(presentation: HostShutterPresentation) {
        guard !closed, shutterPresentation != presentation else { return }
        shutterPresentation = presentation
        projectShutter()
        refreshCapabilities()
        publish()
    }

    /// The connection's configured lens range. Without a valid range zoom stays undescribed;
    /// neither an unknown report nor a missing configuration invents a widest-lens value.
    /// A changed domain invalidates commands prepared against the previous capability revision.
    public func configureLens(zoomDomain: ClosedRange<Double>?) {
        guard !closed else { return }
        self.zoomDomain = zoomDomain.flatMap { range in
            range.lowerBound.isFinite && range.upperBound.isFinite
                && range.lowerBound >= 1 && range.upperBound <= LunaProtocol.maximumZoomScale
                ? range : nil
        }
        refreshCapabilities()
        publish()
    }

    /// The backend's link phase. `.streaming` is a usable control link and a new control epoch.
    public func linkChanged(_ phase: CameraConnectionPhase, serial: String?) {
        guard !closed else { return }
        switch phase {
        case .scanning:
            return
        case .idle:
            guard current.connection == .ready else { return }
            commandOwner.replaceSource()
            endInFlight()
            current.connection = .recovering(ConnectionAttemptID())
            current.authority = .unavailable(.link)
        case .connecting, .negotiating: connecting(.negotiating)
        case .awaitingApproval: connecting(.awaitingApproval)
        case .readingWiFi, .joiningWiFi: connecting(.joiningNetwork)
        case .openingVideo: connecting(.link)
        case .streaming:
            commandOwner.replaceSource()
            if let serial, !serial.isEmpty {
                current.device = .durable(serial, integration: Self.integration)
            }
            current.connection = .ready
            current.authority = .owner
            current.epoch = current.epoch.next()
        }
        // Frame-derived clock observations belong to this link, never its predecessor.
        current.timecodeReading = .unknown
        publish()
    }

    public func ingest(device: LunaDeviceStatus) {
        guard !closed else { return }
        let at = now()
        if let mode = device.shootingMode {
            // Remaining time is per function mode: another bank's report no longer applies.
            if mode.functionMode != shootingMode?.functionMode { reportedRemaining = nil }
            shootingMode = mode
            current.mode = ObservedValue(Self.captureMode(mode), origin: .cameraReported, at: at)
        }
        if let battery = device.battery {
            current.power.battery = ObservedValue(
                Double(min(battery.percent, 100)) / 100, origin: .cameraReported, at: at,
                precision: .quantized(step: 0.01))
            // Power type names the adapter; "charging" itself is not reported.
            current.power.externalPower = ObservedValue(
                battery.powerType != 0, origin: .protocolDerived, at: at)
        }
        let volumes =
            device.storageList.isEmpty ? device.storage.map { [$0] } ?? [] : device.storageList
        if !volumes.isEmpty {
            reportedCards = (volumes, at)
            projectStorage()
        }
        projectShutter()
        refreshCapabilities()
        publish()
    }

    public func ingest(settings: LunaPhotographySettings) {
        guard !closed else { return }
        // A reply for another mode's settings bank says nothing about the active one.
        if let bank = settings.functionMode, bank != functionMode() { return }
        let at = now()
        func carries(_ type: UInt32) -> Bool {
            settings.types.isEmpty || settings.types.contains(type)
        }
        let photo = shootingMode?.isPhoto == true
        // Option 99 rides its own poll; a reply that does not carry it keeps the last report.
        if settings.types.contains(LunaPhotographyType.remainingTime.rawValue)
            || !settings.remainingRecordTime.isEmpty
        {
            reportedRemaining = (
                Dictionary(
                    settings.remainingRecordTime.map { ($0.location, $0.seconds) },
                    uniquingKeysWith: { _, last in last }), at)
            projectStorage()
        }
        if carries(31), settings.recordResolution != nil || settings.types.contains(31) {
            let cadence = settings.videoResolution?.framesPerSecond
            if reportedCadence.value != cadence {
                current.capabilities.revision = current.capabilities.revision.next()
            }
            reportedCadence = cadence.map { ObservedValue($0, origin: .cameraReported, at: at) } ?? .unknown
        }
        let exposure =
            photo
            ? (carries(20) ? settings.stillExposure : nil)
                ?? (carries(21) ? settings.videoExposure : nil)
            : (carries(21) ? settings.videoExposure : nil)
                ?? (carries(20) ? settings.stillExposure : nil)
        if exposure != nil || settings.types.contains(20) || settings.types.contains(21) {
            let iso = exposure.flatMap(Self.iso)
            let shutter = exposure.flatMap(Self.shutter)
            current.settings[.iso] = iso.map { ObservedValue(.iso($0), origin: .cameraReported, at: at) } ?? .unknown
            reportedShutter = shutter.map { ObservedValue($0, origin: .cameraReported, at: at) } ?? .unknown
            current.exposureProgram = exposure.flatMap(Self.exposureProgram).map {
                ObservedValue($0, origin: .cameraReported, at: at)
            } ?? .unknown
            reportedAt[.iso] = iso == nil ? nil : at
            reportedAt[.shutter] = shutter == nil ? nil : at
        }
        if carries(39) {
            // proto3 may omit a zero: a requested type 39 without a value is Auto.
            let kelvin = settings.whiteBalanceKelvin
            if let reported = kelvin ?? (settings.types.contains(39) ? 0 : nil) {
                current.settings[.whiteBalance] = ObservedValue(
                    .whiteBalance(reported == 0 ? .auto : .kelvin(Int(reported))),
                    origin: kelvin == nil ? .protocolDerived : .cameraReported, at: at)
                reportedAt[.whiteBalance] = at
            }
        }
        // Option 31 declares recording dimensions and cadence, not the preview's encoding.
        if carries(31), settings.recordResolution != nil || settings.types.contains(31) {
            let resolution = settings.videoResolution
            let rate = resolution.flatMap { Rational.frameRate($0.framesPerSecond) }
            current.settings[.frameRate] = rate.map {
                ObservedValue(.frameRate($0), origin: .cameraReported, at: at)
            } ?? .unknown
            reportedAt[.frameRate] = rate == nil ? nil : at
            current.recordingFormat.dimensions = resolution.flatMap {
                CameraRecordingFormat.Dimensions(width: $0.width, height: $0.height)
            }.map { ObservedValue($0, origin: .cameraReported, at: at) } ?? .unknown
        }
        if carries(35), settings.colorMode != nil || settings.types.contains(35) {
            recordingProfile = settings.color.map {
                ObservedValue(Self.profileID($0), origin: .cameraReported, at: at)
            } ?? .unknown
            current.recordingFormat.profile = settings.color.map {
                ObservedValue($0.label, origin: .cameraReported, at: at)
            } ?? .unknown
        }
        if carries(53), settings.zoom != nil || settings.types.contains(53) {
            if let zoom = settings.zoom, zoom.isFinite,
                (1...LunaProtocol.maximumZoomScale).contains(zoom)
            {
                current.settings[.zoom] = ObservedValue(
                    .zoom(zoom), origin: .cameraReported, at: at)
                reportedAt[.zoom] = at
            } else {
                current.settings[.zoom] = .unknown
                reportedAt[.zoom] = nil
            }
        }
        if carries(93), settings.afMode != nil || settings.types.contains(93) {
            let focus: FocusMode? =
                switch settings.afMode {
                case LunaAFMode.single.rawValue?: .single
                case LunaAFMode.continuous.rawValue?: .continuous
                default: nil  // Product Showcase is an integration-owned extension.
                }
            current.settings[.focusMode] =
                focus.map {
                    ObservedValue(.focusMode($0), origin: .cameraReported, at: at)
                } ?? .unknown
            reportedAt[.focusMode] = focus == nil ? nil : at
        }
        projectShutter()
        refreshCapabilities()
        settle()
        publish()
    }

    public func ingest(capture: LunaCaptureStatus) {
        guard !closed else { return }
        let at = now()
        // Photo and pano capture states say nothing about video recording: unknown.
        let state: RecordingState? = capture.isRecording ? .recording : capture.isIdle ? .idle : nil
        if let state {
            current.recording = ObservedValue(state, origin: .cameraReported, at: at)
            reportedAt[.recording] = at
        } else {
            current.recording = .unknown
        }
        settle()
        publish()
    }

    /// Time of day the host derives for the live picture: the phone sets the camera clock and
    /// pins frame stamps to its own, so the value is `.clockDerived`, never a camera counter.
    public func ingest(timecode: CameraTimecode) {
        ingest(timecode: CameraTimecodeReading(timecode))
    }

    public func ingest(timecode: CameraTimecodeReading) {
        guard !closed, current.connection == .ready else { return }
        current.timecodeReading = ObservedValue(timecode, origin: .clockDerived, at: now())
        publish()
    }

    /// What a monitor lays out for this camera: a view of the one control model
    /// (`controlCapabilities()`), so the zoom chip follows Luna's declared zoom before the live
    /// range arrives. `base` carries what Core has no vocabulary for yet.
    public func layout(base: MonitorLayoutCapabilities = .init()) -> MonitorLayoutCapabilities {
        MonitorLayoutCapabilities(controls: controlCapabilities(), base: base)
    }

    // MARK: - CameraSession

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

    public func submit(_ command: CameraCommand) async -> CommandReceipt {
        await submit(command, suppliedAdmission: nil)
    }

    public func submit(_ command: CameraCommand, admission: LunaCommandAdmission) async
        -> CommandReceipt
    {
        await submit(command, suppliedAdmission: admission)
    }

    private struct DeferredCommandRejection: Error { let rejection: CommandRejection }

    private func submit(
        _ command: CameraCommand, suppliedAdmission admission: LunaCommandAdmission?
    )
        async -> CommandReceipt
    {
        let operation = command.operation
        if let known = receipts[operation] { return known }
        let key = command.intent.key
        receipts[operation] = CommandReceipt(
            operation: operation, session: id, intent: command.intent,
            confirmation: current.capabilities[key]?.semantics.confirmation ?? .readback)
        if closed { return transition(operation, .rejected(.sessionClosed)) }
        if let admission, !admission.admits(commandOwner) {
            return transition(operation, .rejected(.authorityExpired))
        }
        if let rejection = current.rejection(of: command, at: now()) {
            return transition(operation, .rejected(rejection))
        }
        transition(operation, .admitted)
        // Idempotency: a start while the camera reports recording (or a stop while idle) is
        // already satisfied, so a retry can never undo the first success.
        if alreadyReported(command.intent) { return transition(operation, .confirmed) }
        let request: LunaRequest
        do {
            // A described key without a request here is the old silent `apply` hole; the
            // capability test submits every writable key to catch it.
            guard let built = try self.request(for: command.intent) else {
                return transition(operation, .rejected(.unsupported))
            }
            request = built
        } catch {
            return transition(operation, .rejected(.outOfDomain))
        }
        let expectedShutter: Int?
        if case .set(.shutter(.angle(let degrees))) = command.intent {
            expectedShutter = HostShutterAngle.denominator(degrees: degrees,
                framesPerSecond: reportedCadence.value, available: Self.shutterDenominators)
        } else { expectedShutter = nil }
        do {
            if let admission {
                guard let sendAdmitted else { throw LunaCommandAdmissionError.expired }
                let epoch = current.epoch
                _ = try await sendAdmitted(
                    { [self] in
                        try admission.require(owner: commandOwner)
                        guard !closed, current.epoch == epoch,
                            receipts[operation]?.isFinished == false
                        else { throw LunaCommandAdmissionError.expired }
                        if let rejection = current.rejection(of: command, at: now()) {
                            throw DeferredCommandRejection(rejection: rejection)
                        }
                        do {
                            guard let built = try self.request(for: command.intent) else {
                                throw DeferredCommandRejection(rejection: .unsupported)
                            }
                            return built
                        } catch let error as DeferredCommandRejection { throw error } catch {
                            throw DeferredCommandRejection(rejection: .outOfDomain)
                        }
                    }, admission,
                    { [self] in
                        // The SDK already entered. Later receipt expiry cannot retract this write.
                        guard !closed, current.epoch == epoch,
                            receipts[operation]?.isFinished == false
                        else { return }
                        commitDispatch(command)
                    })
            } else {
                commitDispatch(command)
                _ = try await send(request)
            }
        } catch let error as DeferredCommandRejection {
            return transition(operation, .rejected(error.rejection))
        } catch LunaCommandAdmissionError.expired {
            let entered = receipts[operation]?.stage != .admitted
            return transition(operation, entered ? .outcomeUnknown : .rejected(.authorityExpired))
        } catch LunaProtocolError.cameraRejectedRequest {
            return transition(operation, .rejected(.cameraRefused))
        } catch {
            // Timeout or dropped link: the camera may have acted.
            let unsent = admission != nil && receipts[operation]?.stage == .admitted
            return transition(operation, unsent ? .failed(.notSent) : .outcomeUnknown)
        }
        // The link dropped or the session closed while the write was out.
        if let finished = receipts[operation], finished.isFinished { return finished }
        transition(operation, .accepted)
        let acceptedAt = now()
        var deadline = acceptedAt + (timing.settle[key] ?? .seconds(4))
        if let limit = command.preconditions.deadline, limit < deadline { deadline = limit }
        awaiting[operation] = Awaiting(
            intent: command.intent, acceptedAt: acceptedAt, deadline: deadline,
            shutterDenominator: expectedShutter)
        transition(operation, .awaitingObservation)
        settle()
        if pump == nil { pump = Task { [weak self] in await self?.readBackUntilSettled() } }
        return receipts[operation]!
    }

    private func commitDispatch(_ command: CameraCommand) {
        if case .set(let value) = command.intent {
            // An older unfinished write may have landed. Supersede it only when this
            // supplied successor actually enters; the original direct call enters here first.
            if let older = targets[value.key]?.operation { transition(older, .failed(.superseded)) }
            targets[value.key] = (command.operation, value)
        }
        transition(command.operation, .sent)
    }

    /// Integration-owned media commands share the actual session lifetime and transport path.
    /// No result from a replaced epoch can authorize a subsequent browse/return command.
    func mediaRequest(_ request: LunaRequest, epoch: ControlEpoch) async throws -> Data {
        try Task.checkCancellation()
        guard !closed, current.connection == .ready, current.authority == .owner,
            current.epoch == epoch
        else { throw CancellationError() }
        let reply = try await send(request)
        try Task.checkCancellation()
        guard !closed, current.connection == .ready, current.authority == .owner,
            current.epoch == epoch
        else { throw CancellationError() }
        return reply
    }

    /// Whether `control(_:timeout:)` sends now: the session is open, ready and owned.
    public var admitsControl: Bool {
        !closed && current.connection == .ready && current.authority == .owner
    }

    /// Luna requests the common model does not describe (Deep Track, tap focus, gimbal, clock and
    /// photography options) go out on this session's link only while it admits control. The
    /// camera's 200 body is success; `timeout` bounds the wait when the backend supports it.
    public func control(_ request: LunaRequest, timeout: Duration? = nil) async throws -> Data {
        guard admitsControl else { throw CancellationError() }
        if let timeout, let sendWithin { return try await sendWithin(request, timeout) }
        return try await send(request)
    }

    public func control(
        _ request: LunaRequest, admission: LunaCommandAdmission,
        timeout: Duration? = nil
    ) async throws -> Data {
        try admission.require(owner: commandOwner)
        guard admitsControl else { throw LunaCommandAdmissionError.expired }
        if let timeout, let sendAdmittedWithin {
            return try await sendAdmittedWithin({ request }, admission, timeout, {})
        }
        guard let sendAdmitted else { throw LunaCommandAdmissionError.expired }
        return try await sendAdmitted({ request }, admission, {})
    }

    /// Backend retirement publishes before native cancellation, without changing link policy.
    func retireCommandSource() { commandOwner.replaceSource() }

    /// The function mode (bank) a photography SET is built for now.
    var requestFunctionMode: UInt32 { functionMode() }

    /// The Luna's timecode is time of day from its own clock, which the phone is expected to set.
    /// Sets it like the official app on connect (options 12/13/175), then to the millisecond with
    /// cmd 214 twice, each stamped at send (a GET round trip on the camera AP is about 4 ms; the
    /// clock SET takes about 220 ms of camera processing). False when the camera refused the SET.
    /// Android: `LunaBackend.syncClock`.
    @discardableResult
    public func syncClock(zone: TimeZone = .current, now: () -> Date = Date.init) async -> Bool {
        let date = now()
        guard
            let request = try? LunaProtocol.setClockRequest(
                unixSeconds: UInt64(date.timeIntervalSince1970),
                timeZoneSeconds: Int32(zone.secondsFromGMT(for: date)), zone: zone.identifier),
            (try? await control(request, timeout: .seconds(2))) != nil
        else { return false }
        for count: UInt32 in 0..<2 {
            let milliseconds = UInt64((now().timeIntervalSince1970 * 1000).rounded())
            if let request = try? LunaProtocol.syncTimeAccurateRequest(
                unixMilliseconds: milliseconds, count: count)
            {
                _ = try? await control(request, timeout: .seconds(2))
            }
        }
        return true
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
            Task { @MainActor in self.stopWaiting(operation, token) }
        }
    }

    public func receipt(of operation: OperationID) -> CommandReceipt? { receipts[operation] }

    /// Never sends a camera command; in particular it never stops a recording.
    public func close(_ reason: SessionCloseReason) {
        guard !closed else { return }
        commandOwner.retire()
        endInFlight()
        closed = true
        pump?.cancel()
        pump = nil
        current.connection = .disconnected(reason)
        current.authority = .unavailable(.link)
        publish()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: - Requests

    private func request(for intent: CameraCommandIntent) throws -> LunaRequest? {
        let bank = functionMode()
        switch intent {
        case .set(.iso(let iso)):
            return try exposure(
                iso: iso, shutter: target(.shutter).flatMap(Self.shutterValue), bank)
        case .set(.shutter(let shutter)):
            return try exposure(iso: target(.iso).flatMap(Self.isoValue), shutter: shutter, bank)
        case .set(.whiteBalance(.auto)):
            return try LunaProtocol.setWhiteBalanceAuto(functionMode: bank)
        case .set(.whiteBalance(.kelvin(let kelvin))):
            return try LunaProtocol.setWhiteBalanceKelvin(
                UInt64(max(kelvin, 0)), functionMode: bank)
        case .set(.zoom(let factor)):
            return try LunaProtocol.setZoomScale(factor, functionMode: bank)
        case .set(.focusMode(.single)):
            return try LunaProtocol.setAFMode(.single, functionMode: bank)
        case .set(.focusMode(.continuous)):
            return try LunaProtocol.setAFMode(.continuous, functionMode: bank)
        case .startRecording:
            return try shootingMode.map(LunaProtocol.startCaptureRequest(for:))
        case .stopRecording:
            return try shootingMode.map(LunaProtocol.stopCaptureRequest(for:))
        default:
            return nil
        }
    }

    /// The newest unfinished write for `key`, else the reported value.
    private func target(_ key: SettingKey) -> SettingValue? {
        targets[key]?.value ?? current.value(of: key).value
    }

    private func exposure(iso: ISOValue?, shutter: ShutterValue?, _ bank: UInt32) throws
        -> LunaRequest?
    {
        var manualISO: UInt64?
        if case .manual(let value)? = iso { manualISO = UInt64(max(value, 0)) }
        var seconds: Double?
        switch shutter ?? reportedShutter.value {
        case .angle(let degrees)?:
            // An angle from Auto is the first manual shutter; the reported cadence composes it.
            guard shutterPresentation == .emulatedAngle,
                shootingMode.map({ !$0.isPhoto }) == true,
                let denominator = HostShutterAngle.denominator(degrees: degrees,
                    framesPerSecond: reportedCadence.value, available: Self.shutterDenominators)
            else { return nil }
            seconds = 1 / Double(denominator)
        case .duration(let duration)?: seconds = duration.doubleValue
        case .auto?: break
        case nil: return nil
        }
        let program: LunaExposureProgram =
            switch (manualISO, seconds) {
            case (nil, nil): .automatic
            case (.some, nil): .isoPriority
            case (nil, .some): .shutterPriority
            case (.some, .some): .manual
            }
        return try LunaProtocol.setVideoExposure(
            program: program, iso: manualISO, shutterSeconds: seconds, functionMode: bank)
    }

    // MARK: - Settling

    private func alreadyReported(_ intent: CameraCommandIntent) -> Bool {
        switch intent {
        case .startRecording: current.recording.value == .recording
        case .stopRecording: current.recording.value == .idle
        case .set, .focusPoint: false
        }
    }

    private func reportShows(_ intent: CameraCommandIntent, shutterDenominator: Int?) -> Bool {
        switch intent {
        case .set(.zoom(let target)):
            guard case .zoom(let reported)? = current.value(of: .zoom).value else { return false }
            // Preserve the established app tolerance while the physical lens ramps.
            return abs(target - reported) < 0.05
        case .set(.shutter(.angle)):
            guard let shutterDenominator, case .duration(let reported)? = reportedShutter.value else { return false }
            return reported == Rational(1, shutterDenominator)
        // An angle projection never equals a duration or Auto: the camera's own value confirms.
        case .set(.shutter(let target)): return reportedShutter.value == target
        case .set(let value): return current.value(of: value.key).value == value
        case .startRecording: return current.recording.value == .recording
        case .stopRecording: return current.recording.value == .idle
        case .focusPoint: return false
        }
    }

    /// Confirms what a readback shows; ends what its settle window has closed on.
    private func settle() {
        let at = now()
        for (operation, write) in awaiting {
            if reportShows(write.intent, shutterDenominator: write.shutterDenominator) {
                transition(operation, .confirmed)
            } else if at >= write.deadline {
                let heard = reportedAt[write.intent.key].map { $0 > write.acceptedAt } ?? false
                transition(operation, heard ? .failed(.notApplied) : .timedOut)
            }
        }
    }

    private func readBackUntilSettled() async {
        while !awaiting.isEmpty, !closed, !Task.isCancelled {
            let keys = Set(awaiting.values.map(\.intent.key))
            if keys.contains(.recording) { await readCapture() }
            if !keys.subtracting([.recording]).isEmpty { await readSettings() }
            try? await Task.sleep(for: timing.readbackInterval)
            settle()
        }
        pump = nil
    }

    /// Link lost or session closed: unsent work never left; sent work may have acted.
    private func endInFlight() {
        for (operation, receipt) in receipts where !receipt.isFinished {
            switch receipt.stage {
            case .created, .admitted: transition(operation, .failed(.notSent))
            default: transition(operation, .outcomeUnknown)
            }
        }
    }

    private func connecting(_ phase: ConnectionPhase) {
        let attempt: ConnectionAttemptID
        switch current.connection {
        case .connecting(let existing, _), .recovering(let existing):
            attempt = existing
        default:
            commandOwner.replaceSource()
            endInFlight()
            attempt = ConnectionAttemptID()
        }
        current.connection =
            current.epoch == ControlEpoch() ? .connecting(attempt, phase) : .recovering(attempt)
        current.authority = .unavailable(.link)
    }

    @discardableResult
    private func transition(_ operation: OperationID, _ stage: CommandStage) -> CommandReceipt {
        guard var receipt = receipts[operation] else {
            preconditionFailure("unknown operation \(operation)")
        }
        // A late completion never rewrites a finished outcome.
        if receipt.isFinished { return receipt }
        receipt.stage = stage
        receipts[operation] = receipt
        if receipt.isFinished {
            awaiting[operation] = nil
            let key = receipt.intent.key
            if targets[key]?.operation == operation { targets[key] = nil }
            for continuation in (waiters.removeValue(forKey: operation) ?? [:]).values {
                continuation.resume(returning: receipt)
            }
        }
        return receipt
    }

    private func stopWaiting(_ operation: OperationID, _ token: UUID) {
        waiters[operation]?.removeValue(forKey: token)?.resume(returning: receipts[operation])
    }

    private func publish() {
        current.revision = current.revision.next()
        for (token, continuation) in subscribers {
            if case .terminated = continuation.yield(current) { subscribers[token] = nil }
        }
    }

    // MARK: - Capabilities and mapping

    private func projectShutter() {
        guard let value = reportedShutter.value else { current.settings[.shutter] = .unknown; return }
        // Photo has no cadence to emulate against: it keeps the camera's own duration.
        if shutterPresentation == .emulatedAngle, case .duration(let seconds) = value,
            shootingMode?.isPhoto != true {
            guard shootingMode.map({ !$0.isPhoto }) == true,
                let cadence = reportedCadence.value,
                let angle = HostShutterAngle.reported(seconds: seconds, framesPerSecond: cadence)
            else { current.settings[.shutter] = .unknown; return }
            let at = [reportedShutter.observedAt, reportedCadence.observedAt].compactMap { $0 }.min()
            current.settings[.shutter] = ObservedValue(.shutter(.angle(angle)), origin: .protocolDerived, at: at)
        } else {
            current.settings[.shutter] = ObservedValue(.shutter(value), origin: reportedShutter.origin,
                at: reportedShutter.observedAt)
        }
    }

    private func refreshCapabilities() {
        // A write carries ISO and shutter together, so neither is safe before both are known. A
        // withdrawn report keeps its key with an unknown value, so the value decides.
        let exposure: Availability =
            current.settings[.iso]?.isKnown == true ? .available : .unavailable(.notReady)
        let recording: Availability =
            switch shootingMode {
            case nil: .unavailable(.notReady)
            case let mode? where mode.isPhoto: .unavailable(.mode)
            default: .available
            }
        var iso = SettingDomain(choices: Self.isoValues.map { .iso(.manual($0)) })
        iso.choices.insert(.iso(.auto), at: 0)
        var shutter = SettingDomain(
            choices: Self.shutterDenominators.map { .shutter(.duration(Rational(1, $0))) })
        shutter.choices.insert(.shutter(.auto), at: 0)
        let emulated = shutterPresentation == .emulatedAngle
        // Angles are offered only where `exposure(iso:shutter:_:)` can compose them: video with a
        // reported cadence. Photo keeps the camera's durations (CodeRabbit on #114).
        if emulated, shootingMode.map({ !$0.isPhoto }) == true, reportedCadence.value != nil {
            shutter.choices = HostShutterAngle.choices + shutter.choices
        }
        // Angle is a presentation: the camera's durations and Auto stay writable (an angle pick,
        // Manual from Auto, AE-L), so Auto never blocks the first manual shutter, and a missing
        // cadence withholds only the angles (CodeRabbit on #114).
        let shutterAvailability: Availability =
            emulated && shootingMode == nil ? .unavailable(.notReady) : exposure
        var descriptors = [
            SettingDescriptor(.iso, domain: iso, availability: exposure),
            SettingDescriptor(.shutter, domain: shutter, availability: shutterAvailability,
                semantics: SettingSemantics(implementation: emulated ? .emulated : .native)),
            SettingDescriptor(
                .whiteBalance,
                domain: SettingDomain(choices: [.whiteBalance(.auto)], range: 2000...10000)),
            SettingDescriptor(.recording, availability: recording),
            SettingDescriptor(
                .focusMode,
                domain: SettingDomain(choices: [.focusMode(.single), .focusMode(.continuous)])),
            // The record rate is a common read-only observation; the format picker stays native.
            SettingDescriptor(.frameRate, access: .readOnly),
        ]
        if let zoomDomain {
            descriptors.append(SettingDescriptor(.zoom, domain: SettingDomain(range: zoomDomain)))
        }
        // Timecode is host-derived time of day (`ingest(timecode:)`); Luna reports no audio levels.
        var declared = CapabilitySnapshot(
            revision: current.capabilities.revision, descriptors: descriptors,
            unsupported: Self.unsupported, timecodeCapability: .supported(.seconds), audioLevels: .unsupported)
        guard declared != current.capabilities else { return }
        declared.revision = declared.revision.next()
        current.capabilities = declared
    }

    private static func exposureProgram(_ exposure: LunaExposure) -> CameraExposureProgram? {
        switch exposure.exposureProgram {
        case .manual?: .manual
        case .isoPriority?: .isoPriority
        case .shutterPriority?: .shutterPriority
        case .automatic?, .adaptive?, .fullAuto?: .automatic
        case nil: nil
        }
    }

    /// A recognized automatic circuit is a fact; an unrecognized program is unknown.
    static func iso(_ exposure: LunaExposure) -> ISOValue? {
        guard exposureProgram(exposure) != nil else { return nil }
        switch exposure.exposureProgram {
        case .isoPriority?, .manual?:
            guard exposure.iso <= UInt64(Int32.max) else { return nil }
            return exposure.iso > 0 ? .manual(Int(exposure.iso)) : .auto
        default: return .auto
        }
    }

    static func shutter(_ exposure: LunaExposure) -> ShutterValue? {
        guard exposureProgram(exposure) != nil else { return nil }
        switch exposure.exposureProgram {
        case .shutterPriority?, .manual?:
            if exposure.shutterSeconds == 0 { return .auto }
            return HostShutterAngle.readback(seconds: exposure.shutterSeconds).map(ShutterValue.duration)
        default: return .auto
        }
    }

    private static func isoValue(_ value: SettingValue) -> ISOValue? {
        if case .iso(let iso) = value { return iso }
        return nil
    }

    private static func shutterValue(_ value: SettingValue) -> ShutterValue? {
        if case .shutter(let shutter) = value { return shutter }
        return nil
    }

    static func captureMode(_ mode: LunaShootingMode) -> CaptureMode {
        let (name, title): (String, String) =
            switch mode {
            case .video: ("video", "Video")
            case .timelapse: ("timelapse", "Timelapse")
            case .timeShift: ("timeshift", "TimeShift")
            case .slowMotion: ("slow-motion", "Slow Motion")
            case .pureVideo: ("purevideo", "PureVideo")
            case .photo: ("photo", "Photo")
            case .pano: ("pano", "Pano")
            }
        return CaptureMode(
            role: mode.isPhoto ? .photo : .video, id: "\(integration.rawValue).mode.\(name)",
            title: title)
    }

    /// Native recording content; a profile never declares the preview curve or its codec.
    static func profileID(_ color: LunaColorMode) -> String {
        let name =
            switch color {
            case .standard: "standard"
            case .iLog: "i-log"
            case .vivid: "vivid"
            case .hdr: "hdr"
            case .dolbyVision: "dolby-vision"
            }
        return "\(integration.rawValue).profile.\(name)"
    }

    /// One volume per reported card, each with its own camera-reported remaining record time.
    private func projectStorage() {
        guard let reportedCards else { return }
        current.storage = ObservedValue(
            reportedCards.cards.map { card in
                Self.volume(
                    card, at: reportedCards.at,
                    remaining: reportedRemaining.flatMap { remaining in
                        remaining.seconds[card.location].map { ($0, remaining.at) }
                    })
            }, origin: .cameraReported, at: reportedCards.at)
    }

    private static func volume(
        _ storage: LunaStorage, at: MonotonicInstant,
        remaining: (seconds: UInt64, at: MonotonicInstant)? = nil
    ) -> StorageVolume {
        let media: MediaState? =
            switch storage.cardState {
            case 0: .ready
            case 1: .absent
            case 2: .full
            case 3, 4, 5: .error
            default: nil
            }
        return StorageVolume(
            id: "location-\(storage.location)",
            media: media.map { ObservedValue($0, origin: .cameraReported, at: at) } ?? .unknown,
            // Free space only means something on a usable card.
            freeBytes: storage.isUsable
                ? ObservedValue(storage.freeBytes, origin: .cameraReported, at: at) : .unknown,
            totalBytes: storage.isUsable && storage.totalBytes > 0
                ? ObservedValue(storage.totalBytes, origin: .cameraReported, at: at) : .unknown,
            // Zero is a known full card; no entry for this location stays unknown.
            remainingRecordingTime: storage.isUsable
                ? remaining.flatMap { entry in
                    Int64(exactly: entry.seconds).map {
                        ObservedValue(Duration.seconds($0), origin: .cameraReported, at: entry.at)
                    }
                } ?? .unknown : .unknown)
    }
}
