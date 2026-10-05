import Foundation
import OpenCineDJI

/// Pending native editor projection; sparse reports alone confirm requests.
@MainActor
public final class DjiAppleEditorReconciliation {
    public enum Origin { case acknowledgment, subscription }
    public struct Authority {
        fileprivate var generation: UInt64
        fileprivate var revision: UInt64
        fileprivate var binding: DjiAppleSettingsBinding
    }
    public struct Projection {
        public let status: CameraStatus
        public let rematchAngle: Double?
        public let formatExpired: Bool
        public let captureModeChanged: Bool
        public let authority: Authority
    }
    private var captureModeGeneration: UInt64 = 0
    private var formatRequestGeneration: UInt64 = 0
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private let binding: () -> DjiAppleSettingsBinding
    private let now: () -> Date
    private let whiteBalanceChanged: (WhiteBalance?, WhiteBalance?) -> Void
    private var pendingWhiteBalance: WhiteBalance?
    private var formatExpired = false
    private var expoPin: ExpoPin?
    private var expoGeneration: UInt64 = 0
    private var audioPin: AudioPin?
    private var formatPin:
        (expected: VideoFormat, deadline: Date, shutterAngle: Double?, angleDeadline: Date)?
    private var colorPin: (expected: ColorMode, deadline: Date)?
    private var shootingModePin: DjiAppleRequestedValue<Int>?
    private var whiteBalancePin: DjiAppleRequestedValue<WhiteBalance>?
    private var focusModePin: DjiAppleRequestedValue<FocusMode>?
    private var focusTrackPin: DjiAppleRequestedValue<FocusTrackMode>?
    private var isoLimitPin: DjiAppleRequestedValue<IsoLimit>?

    public init(
        binding: @escaping () -> DjiAppleSettingsBinding,
        now: @escaping () -> Date = { Date() },
        whiteBalanceChanged: @escaping (WhiteBalance?, WhiteBalance?) -> Void = { _, _ in }
    ) {
        self.binding = binding
        self.now = now
        self.whiteBalanceChanged = whiteBalanceChanged
    }
    public var captureGeneration: UInt64 { captureModeGeneration }
    public var formatGeneration: UInt64 { formatRequestGeneration }
    public func advanceCaptureGeneration() {
        captureModeGeneration &+= 1
        revision &+= 1
    }
    @discardableResult
    public func advanceFormatGeneration() -> UInt64 {
        formatRequestGeneration &+= 1
        revision &+= 1
        return formatRequestGeneration
    }
    public func hasFocusTrackRequest(id: UUID) -> Bool { focusTrackPin?.id == id }
    public func clearFormatAngle() {
        formatPin?.shutterAngle = nil
        revision &+= 1
    }
    public func expireFormatForOperatorAngle() {
        guard let pin = formatPin,
            now() >= (pin.shutterAngle == nil ? pin.deadline : pin.angleDeadline)
        else { return }
        formatPin = nil
        revision &+= 1
    }
    public func holdFormatAngle(_ value: Double) {
        guard formatPin != nil else { return }
        formatPin?.shutterAngle = value
        revision &+= 1
    }

    public var authority: Authority {
        .init(generation: generation, revision: revision, binding: binding())
    }
    /// Editor publication is narrower than the captured native receipt's source lifetime.
    public func admitsSource(_ value: Authority) -> Bool {
        value.generation == generation && value.binding == binding()
    }
    public func admits(_ value: Authority) -> Bool {
        admitsSource(value) && value.revision == revision
    }
    public var requestedWhiteBalance: WhiteBalance? { pendingWhiteBalance }
    public var hasFormat: Bool { formatPin != nil }
    public var requestedFormatAngle: Double? { formatPin?.shutterAngle }
    public var needsSparseReport: Bool {
        shootingModePin != nil || whiteBalancePin != nil || focusModePin != nil
            || focusTrackPin != nil || isoLimitPin != nil || expoPin != nil
            || audioPin != nil || formatPin != nil || colorPin != nil
    }
    public func project(
        incoming: CameraStatus, reported: CameraStatus,
        committed: CameraStatus, origin: Origin
    ) -> Projection {
        let previousWB = pendingWhiteBalance
        let committedMode = committed.shootingMode
        var next = incoming
        formatExpired = false
        absorbStaleChoices(&next, reported: reported, committed: committed)
        let modeChanged = next.shootingMode != committedMode
        if case .subscription = origin, modeChanged {
            captureModeGeneration &+= 1
            formatPin = nil
        }
        if case .acknowledgment = origin {
            absorbStaleAudio(&next, reported: reported, committed: committed)
            absorbStaleExpo(&next, reported: reported, committed: committed)
            absorbStaleColor(&next, reported: reported, committed: committed)
        } else {
            absorbStaleExpo(&next, reported: reported, committed: committed)
            if next.expoMode == .auto, formatPin?.shutterAngle != nil {
                formatPin?.shutterAngle = nil
                clearExpoPin(shutter: true)
            }
            absorbStaleAudio(&next, reported: reported, committed: committed)
        }
        let formatReported =
            reported.videoFormat != nil
            || reported.videoResolution != nil || reported.fps > 0
        let angle = absorbStaleFormat(&next, reportedThisFrame: formatReported)
        if case .subscription = origin {
            absorbStaleColor(&next, reported: reported, committed: committed)
        }
        revision &+= 1
        let accepted = authority
        let result = Projection(
            status: next, rematchAngle: angle, formatExpired: formatExpired,
            captureModeChanged: modeChanged, authority: accepted)
        if previousWB != pendingWhiteBalance {
            whiteBalanceChanged(previousWB, pendingWhiteBalance)
        }
        return result
    }
    public struct Request {
        public let id: UUID
        fileprivate var generation: UInt64
        fileprivate var binding: DjiAppleSettingsBinding
        fileprivate var field: Choice
    }
    fileprivate enum Choice { case shootingMode, whiteBalance, focusMode, focusTrack, isoLimit }

    private func request(_ id: UUID, field: Choice) -> Request {
        .init(id: id, generation: generation, binding: binding(), field: field)
    }
    public func isPending(_ value: Request) -> Bool {
        guard value.generation == generation, value.binding == binding() else { return false }
        switch value.field {
        case .shootingMode: return shootingModePin?.id == value.id
        case .whiteBalance: return whiteBalancePin?.id == value.id
        case .focusMode: return focusModePin?.id == value.id
        case .focusTrack: return focusTrackPin?.id == value.id
        case .isoLimit: return isoLimitPin?.id == value.id
        }
    }
    public func holdShootingMode(_ value: Int) -> Request {
        let pin = DjiAppleRequestedValue(value, now: now().timeIntervalSinceReferenceDate)
        shootingModePin = pin
        revision &+= 1
        return request(pin.id, field: .shootingMode)
    }
    public func holdWhiteBalance(_ value: WhiteBalance) -> Request {
        let previous = pendingWhiteBalance
        let pin = DjiAppleRequestedValue(value, now: now().timeIntervalSinceReferenceDate)
        whiteBalancePin = pin
        pendingWhiteBalance = value
        revision &+= 1
        let accepted = request(pin.id, field: .whiteBalance)
        if previous != value { whiteBalanceChanged(previous, value) }
        return accepted
    }
    public func holdFocusMode(_ value: FocusMode) -> Request {
        let pin = DjiAppleRequestedValue(value, now: now().timeIntervalSinceReferenceDate)
        focusModePin = pin
        revision &+= 1
        return request(pin.id, field: .focusMode)
    }
    public func holdFocusTrack(_ value: FocusTrackMode) -> Request {
        let pin = DjiAppleRequestedValue(value, now: now().timeIntervalSinceReferenceDate)
        focusTrackPin = pin
        revision &+= 1
        return request(pin.id, field: .focusTrack)
    }
    public func holdIsoLimit(_ value: IsoLimit) -> Request {
        let pin = DjiAppleRequestedValue(value, now: now().timeIntervalSinceReferenceDate)
        isoLimitPin = pin
        revision &+= 1
        return request(pin.id, field: .isoLimit)
    }
    /// Failure releases only the exact pending request; rollback values remain host policy.
    @discardableResult
    public func reject(_ value: Request) -> Bool {
        guard isPending(value) else { return false }
        let previous = pendingWhiteBalance
        switch value.field {
        case .shootingMode: shootingModePin = nil
        case .whiteBalance:
            whiteBalancePin = nil
            pendingWhiteBalance = nil
        case .focusMode: focusModePin = nil
        case .focusTrack: focusTrackPin = nil
        case .isoLimit: isoLimitPin = nil
        }
        revision &+= 1
        if previous != pendingWhiteBalance { whiteBalanceChanged(previous, pendingWhiteBalance) }
        return true
    }
    public var hasWhiteBalance: Bool { whiteBalancePin != nil }
    public func clearFocusTrack() {
        focusTrackPin = nil
        revision &+= 1
    }
    public func holdFormat(_ value: VideoFormat, shutterAngle: Double?) {
        let current = now()
        formatPin = (
            value, current.addingTimeInterval(2), shutterAngle, current.addingTimeInterval(8)
        )
        revision &+= 1
    }
    public func clearFormat() {
        formatPin = nil
        revision &+= 1
    }
    public func holdColor(_ value: ColorMode) {
        colorPin = (value, now().addingTimeInterval(2))
        revision &+= 1
    }
    public func clearColor() {
        colorPin = nil
        revision &+= 1
    }
    /// Local retirement; no wire, picture readiness or camera observation is created.
    public func retire() {
        let previous = pendingWhiteBalance
        generation &+= 1
        revision &+= 1
        expoPin = nil
        expoGeneration = 0
        audioPin = nil
        formatPin = nil
        colorPin = nil
        shootingModePin = nil
        whiteBalancePin = nil
        pendingWhiteBalance = nil
        focusModePin = nil
        focusTrackPin = nil
        isoLimitPin = nil
        if previous != nil { whiteBalanceChanged(previous, nil) }
    }
    private struct ExpoPin {
        var generation: UInt64
        var iso: Int?
        var isoIndex: IsoIndex?
        var shutter: Int?
        var ev: EvComp?
        var mode: ExpoMode?
        var deadline: Date
    }

    private struct AudioPin {
        var channel: AudioChannel?
        var vocal: VocalBoost?
        var wind: WindNoiseReduction?
        var directional: DirectionalAudio?
        var deadline: Date
    }

    public func pinAudio(
        channel: AudioChannel? = nil,
        vocal: VocalBoost? = nil,
        wind: WindNoiseReduction? = nil,
        directional: DirectionalAudio? = nil
    ) {
        var pin = audioPin ?? AudioPin(deadline: now().addingTimeInterval(2))
        pin.deadline = now().addingTimeInterval(2)
        if let channel { pin.channel = channel }
        if let vocal { pin.vocal = vocal }
        if let wind { pin.wind = wind }
        if let directional { pin.directional = directional }
        audioPin = pin
        revision &+= 1
    }

    private func audioPinIsEmpty(_ pin: AudioPin) -> Bool {
        pin.channel == nil && pin.vocal == nil && pin.wind == nil && pin.directional == nil
    }

    public func clearAudioPin(
        channel: Bool = false, vocal: Bool = false, wind: Bool = false, directional: Bool = false
    ) {
        guard var pin = audioPin else { return }
        if channel { pin.channel = nil }
        if vocal { pin.vocal = nil }
        if wind { pin.wind = nil }
        if directional { pin.directional = nil }
        audioPin = audioPinIsEmpty(pin) ? nil : pin
        revision &+= 1
    }

    private func absorbStaleChoices(
        _ incoming: inout CameraStatus, reported: CameraStatus, committed: CameraStatus
    ) {
        let now = now().timeIntervalSinceReferenceDate
        if let held = DjiAppleRequestedValue.reconcile(
            &shootingModePin, reported: reported.shootingMode >= 0 ? reported.shootingMode : nil,
            now: now)
        {
            if incoming.shootingMode != held {
                incoming.availableVideoFormats = committed.availableVideoFormats
                incoming.availableShutterDenoms = committed.availableShutterDenoms
                incoming.availableIsoIndices = committed.availableIsoIndices
                incoming.availableColorModes = committed.availableColorModes
            }
            incoming.shootingMode = held
        }
        let pendingWB = DjiAppleRequestedValue.reconcile(
            &whiteBalancePin, reported: reported.whiteBalance, now: now)
        if pendingWB != pendingWhiteBalance { pendingWhiteBalance = pendingWB }
        if let held = DjiAppleRequestedValue.reconcile(
            &focusModePin, reported: reported.focusMode, now: now)
        {
            incoming.focusMode = held
        }
        if let held = DjiAppleRequestedValue.reconcile(
            &focusTrackPin, reported: reported.focusTrack, now: now)
        {
            incoming.focusTrack = held
        }
        if let held = DjiAppleRequestedValue.reconcile(
            &isoLimitPin, reported: reported.isoLimit, now: now)
        {
            incoming.isoLimit = held
        }
    }

    private func absorbStaleAudio(
        _ incoming: inout CameraStatus, reported: CameraStatus, committed: CameraStatus
    ) {
        guard var pin = audioPin else { return }
        if now() >= pin.deadline {
            audioPin = nil
            return
        }
        if let expect = pin.channel {
            if reported.audioChannel == expect {
                pin.channel = nil
            } else if incoming.audioChannel != nil {
                incoming.audioChannel = committed.audioChannel
            }
        }
        if let expect = pin.vocal {
            if reported.vocalBoost == expect {
                pin.vocal = nil
            } else if incoming.vocalBoost != nil {
                incoming.vocalBoost = committed.vocalBoost
            }
        }
        if let expect = pin.wind {
            if reported.windNR == expect {
                pin.wind = nil
            } else if incoming.windNR != nil {
                incoming.windNR = committed.windNR
            }
        }
        if let expect = pin.directional {
            if reported.directionalAudio == expect {
                pin.directional = nil
            } else if incoming.directionalAudio != nil {
                incoming.directionalAudio = committed.directionalAudio
            }
        }
        audioPin = audioPinIsEmpty(pin) ? nil : pin
    }

    public func pinExpo(
        iso: Int? = nil, isoIndex: IsoIndex? = nil, shutter: Int? = nil,
        ev: EvComp? = nil, mode: ExpoMode? = nil
    ) {
        expoGeneration += 1
        var pin =
            expoPin ?? ExpoPin(generation: expoGeneration, deadline: now().addingTimeInterval(2))
        pin.generation = expoGeneration
        pin.deadline = now().addingTimeInterval(2)
        if iso != nil || isoIndex != nil {
            pin.iso = iso
            pin.isoIndex = isoIndex
        }
        if let shutter { pin.shutter = shutter }
        if let ev { pin.ev = ev }
        if let mode { pin.mode = mode }
        expoPin = pin
        revision &+= 1
    }

    private func pinIsEmpty(_ pin: ExpoPin) -> Bool {
        pin.isoIndex == nil && pin.shutter == nil && pin.ev == nil && pin.mode == nil
    }

    public func clearExpoPin(
        iso: Bool = false, shutter: Bool = false, ev: Bool = false, mode: Bool = false
    ) {
        guard var pin = expoPin else { return }
        if iso {
            pin.iso = nil
            pin.isoIndex = nil
        }
        if shutter { pin.shutter = nil }
        if ev { pin.ev = nil }
        if mode { pin.mode = nil }
        expoPin = pinIsEmpty(pin) ? nil : pin
        revision &+= 1
    }

    private func absorbStaleExpo(
        _ incoming: inout CameraStatus, reported: CameraStatus, committed: CameraStatus
    ) {
        defer {
            // Exposure reports cannot confirm the requested FORMAT, even when
            // an early report happens to contain the desired denominator.
            if let pin = formatPin, let angle = pin.shutterAngle,
                now() < pin.angleDeadline, incoming.expoMode == .manual
            {
                incoming.shutterDenom = ShutterAngle.denom(
                    degrees: angle, fps: pin.expected.frameRate.fps,
                    available: incoming.availableShutterDenoms)
            }
        }
        guard var pin = expoPin else { return }
        if now() >= pin.deadline {
            expoPin = nil
            return
        }
        if let expectIdx = pin.isoIndex {
            let matched =
                reported.isoIndex == expectIdx
                || (expectIdx.isoValue.map { reported.iso == $0 } ?? false)
            if matched {
                pin.isoIndex = nil
                pin.iso = nil
            } else {
                incoming.isoIndex = committed.isoIndex
                incoming.iso = committed.iso
            }
        }
        if let expectShutter = pin.shutter {
            if reported.shutterDenom == expectShutter {
                pin.shutter = nil
            } else {
                incoming.shutterDenom = committed.shutterDenom
            }
        }
        if let expectEv = pin.ev {
            if reported.evComp == expectEv {
                pin.ev = nil
            } else {
                incoming.evComp = committed.evComp
            }
        }
        if let expectMode = pin.mode {
            if reported.expoMode == expectMode {
                pin.mode = nil
            } else {
                incoming.expoMode = committed.expoMode
            }
        }
        expoPin = pinIsEmpty(pin) ? nil : pin
    }

    private func absorbStaleFormat(_ incoming: inout CameraStatus, reportedThisFrame: Bool)
        -> Double?
    {
        guard let pin = formatPin else { return nil }
        let deadline = pin.shutterAngle == nil ? pin.deadline : pin.angleDeadline
        if now() >= deadline {
            formatPin = nil
            if pin.shutterAngle != nil {
                formatExpired = true
            }
            return nil
        }
        if !VideoFormat.absorbStale(
            incoming: &incoming, expected: pin.expected, reportedThisFrame: reportedThisFrame)
        {
            formatPin = nil
            return pin.shutterAngle
        }
        return nil
    }

    private func absorbStaleColor(
        _ incoming: inout CameraStatus, reported: CameraStatus, committed: CameraStatus
    ) {
        guard let pin = colorPin else { return }
        if now() >= pin.deadline {
            colorPin = nil
            return
        }
        if reported.colorMode == pin.expected {
            colorPin = nil
            return
        }
        incoming.colorMode = committed.colorMode
    }
}

/// A requested camera value survives older telemetry for a bounded settle window.
/// `reported` must come from this frame, never from an optimistic merged status.
private struct DjiAppleRequestedValue<Value: Equatable & Sendable>: Sendable {
    let id = UUID()
    let expected: Value
    let deadline: TimeInterval

    init(_ expected: Value, now: TimeInterval, settle: TimeInterval = 2) {
        self.expected = expected
        self.deadline = now + settle
    }

    /// Returns the held value, or releases the pin on confirmation/expiry.
    ///
    /// `confirms` decides when the body has answered the ask. Exact equality
    /// suits the enum-shaped controls; zoom hands in `CamFov.matches`, because
    /// its live factor is derived from a lens position and lands a hair off the
    /// number that was asked for.
    static func reconcile(
        _ pin: inout Self?, reported: Value?, now: TimeInterval,
        confirms: (Value, Value) -> Bool = { $0 == $1 }
    ) -> Value? {
        guard let current = pin else { return nil }
        let answered = reported.map { confirms($0, current.expected) } ?? false
        guard now < current.deadline, !answered else {
            pin = nil
            return nil
        }
        return current.expected
    }
}
