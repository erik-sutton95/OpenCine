import Foundation
import OpenCineDJI

/// The existing two-format first-picture recovery sequence, independent of native editor pins.
@MainActor public final class DjiAppleFirstPictureFormat {
    public struct Facts {
        public var status: CameraStatus
        public var browsing: Bool
        public var formatPinned: Bool
        public init(status: CameraStatus, browsing: Bool, formatPinned: Bool) {
            self.status = status
            self.browsing = browsing
            self.formatPinned = formatPinned
        }
    }
    public struct Snapshot: Equatable, Sendable {
        public var poked = false
        public var running = false
        public init() {}
    }
    public enum Event {
        case changed(Snapshot, revision: UInt64)
        case preparing(original: VideoFormat, kick: VideoFormat, legal: Bool, availableCount: Int)
    }
    public private(set) var snapshot = Snapshot()
    public private(set) var revision: UInt64 = 0
    private let binding: () -> DjiAppleSettingsBinding
    private let facts: () -> Facts
    private let setFormat: (VideoFormat) -> Void
    private let enable: () -> Void
    private let timing: DjiAppleTrackingTiming
    private let event: (Event) -> Void
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    public init(
        binding: @escaping () -> DjiAppleSettingsBinding,
        facts: @escaping () -> Facts, setFormat: @escaping (VideoFormat) -> Void,
        enable: @escaping () -> Void, timing: DjiAppleTrackingTiming = .continuous,
        event: @escaping (Event) -> Void = { _ in }
    ) {
        self.binding = binding
        self.facts = facts
        self.setFormat = setFormat
        self.enable = enable
        self.timing = timing
        self.event = event
    }

    /// Local retirement cannot restore a format or enable a replacement endpoint.
    public func reset() {
        generation &+= 1
        let previous = task
        task = nil
        commit(.init())
        previous?.cancel()
    }

    public func start() {
        guard task == nil, !snapshot.running else { return }
        generation &+= 1
        let token = generation
        let source = binding()
        var next = snapshot
        next.running = true
        let publication = commit(next)
        guard current(token, source: source), revision == publication else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(token, source: source)
            guard self.generation == token else { return }
            self.task = nil
            var next = self.snapshot
            next.running = false
            self.commit(next)
        }
    }

    public func waitForPending() async { await task?.value }

    private func commit(_ next: Snapshot) -> UInt64 {
        snapshot = next
        revision &+= 1
        let publication = revision
        event(.changed(next, revision: publication))
        return publication
    }
    private func current(_ token: UInt64, source: DjiAppleSettingsBinding) -> Bool {
        generation == token && binding() == source && !Task.isCancelled
    }
    private func execute(_ token: UInt64, source: DjiAppleSettingsBinding) async {
        guard current(token, source: source) else { return }
        let captured = facts()
        guard !captured.status.isRecording, !captured.browsing else { return }
        let original = VideoFormat.firstPictureOriginal(
            format: captured.status.videoFormat, resolution: captured.status.videoResolution,
            fps: captured.status.fps)
        let kick = VideoFormat.firstPictureEncoderKick(
            from: original, available: captured.status.availableVideoFormats)
        var next = snapshot
        next.poked = true
        let publication = commit(next)
        guard current(token, source: source), revision == publication else { return }
        event(
            .preparing(
                original: original, kick: kick,
                legal: captured.status.availableVideoFormats.isEmpty
                    || captured.status.availableVideoFormats.contains(kick),
                availableCount: captured.status.availableVideoFormats.count))
        guard current(token, source: source), revision == publication else { return }
        setFormat(kick)
        guard await settle(token, source: source) else { return }
        setFormat(original)
        guard await settle(token, source: source), !facts().browsing else { return }
        enable()
    }
    private func settle(_ token: UInt64, source: DjiAppleSettingsBinding) async -> Bool {
        guard current(token, source: source) else { return false }
        let start = timing.now()
        while facts().formatPinned,
            timing.now().timeIntervalSince(start) < CameraSoftAP.firstPictureFormatPokePinWait
        {
            do { try await timing.wait(.milliseconds(50)) } catch { return false }
            guard current(token, source: source) else { return false }
        }
        let elapsed = timing.now().timeIntervalSince(start)
        if elapsed < CameraSoftAP.firstPictureFormatPokeMinSettle {
            do {
                try await timing.wait(
                    .seconds(CameraSoftAP.firstPictureFormatPokeMinSettle - elapsed))
            } catch { return false }
        }
        return current(token, source: source)
    }
}

/// Actual D-Log report admission, pending zoom writes and parked-wide color restoration.
/// Native gesture/HUD/editor pins remain presentation; this owner never calls an old slider workflow.
@MainActor public final class DjiAppleZoomColor {
    public struct Facts {
        public var status: CameraStatus
        public var model: CameraModel?
        public var supportsZoom: Bool
        public var previewing: Bool
        public var locked: Bool
        public init(
            status: CameraStatus, model: CameraModel?, supportsZoom: Bool,
            previewing: Bool, locked: Bool
        ) {
            self.status = status
            self.model = model
            self.supportsZoom = supportsZoom
            self.previewing = previewing
            self.locked = locked
        }
    }
    public struct Snapshot: Equatable, Sendable {
        public var hopPending = false
        public var restoreOnWide = false
        public var pendingFactor: Double?
        public init() {}
    }
    public enum Event {
        case changed(previous: Snapshot, next: Snapshot, revision: UInt64)
        case hopRetry
        case hopPreparing(from: ColorMode?, to: ColorMode)
        case nativeISO(from: ColorMode?, to: ColorMode)
        case hopFailed
        case hopSettled(Bool)
        case confirmed
        case restoredPreparing(from: ColorMode?)
        case restoreFailed
        case restoreSettled(Bool)
        case flushed(Double)
        case slewCleared
        case recordingBlocked
        case locked
        case zoomPreparing
        case zoomSettled(frame: Duml.Frame, name: String, announce: Bool, success: Bool)
    }
    public private(set) var snapshot = Snapshot()
    public private(set) var revision: UInt64 = 0
    public struct Authority {
        fileprivate var generation: UInt64
        fileprivate var binding: DjiAppleSettingsBinding
        fileprivate var revision: UInt64
    }
    public var authority: Authority {
        .init(generation: generation, binding: binding(), revision: revision)
    }
    public func admits(_ authority: Authority) -> Bool {
        current(authority.generation, source: authority.binding) && revision == authority.revision
    }
    private let binding: () -> DjiAppleSettingsBinding
    private let facts: () -> Facts
    private let send:
        (
            DjiAppleControlExchange.SetRequest,
            @escaping @MainActor (DjiAppleControlExchange.SetEvent) -> Void
        ) -> Void
    private let event: (Event) -> Void
    private let admittedNativeISO: ((ColorMode?, ColorMode, DJICommandAdmission) -> Void)?
    private let now: () -> Date
    private var generation: UInt64 = 0
    private var gestureAdmission: (() -> Bool)?
    private var deadline: Date?
    private var hopBinding: DjiAppleSettingsBinding?
    private var pendingBinding: DjiAppleSettingsBinding?
    private var pendingStage: (@MainActor (ControlWireEvent) -> Void)?
    private var pendingAdmission: DJICommandAdmission?

    public init(
        binding: @escaping () -> DjiAppleSettingsBinding, facts: @escaping () -> Facts,
        send:
            @escaping (
                DjiAppleControlExchange.SetRequest,
                @escaping @MainActor (DjiAppleControlExchange.SetEvent) -> Void
            ) -> Void,
        now: @escaping () -> Date = { Date() }, event: @escaping (Event) -> Void = { _ in },
        admittedNativeISO: ((ColorMode?, ColorMode, DJICommandAdmission) -> Void)? = nil
    ) {
        self.binding = binding
        self.facts = facts
        self.send = send
        self.now = now
        self.event = event
        self.admittedNativeISO = admittedNativeISO
    }

    /// Disconnect retirement is local. Its captured pending stage is released exactly once.
    public func reset() {
        generation &+= 1
        deadline = nil
        hopBinding = nil
        pendingBinding = nil
        pendingAdmission = nil
        let previous = pendingStage
        pendingStage = nil
        commit(.init())
        previous?(.notSent)
    }

    @discardableResult public func dropForZoom(_ factor: Double) -> Bool {
        dropForZoom(factor, suppliedAdmission: nil)
    }
    @discardableResult public func dropForZoom(_ factor: Double, admission: DJICommandAdmission)
        -> Bool
    {
        dropForZoom(factor, suppliedAdmission: admission)
    }
    private func dropForZoom(_ factor: Double, suppliedAdmission admission: DJICommandAdmission?)
        -> Bool
    {
        guard admission?.isCurrent ?? true else { return false }
        let token = generation
        let source = binding()
        let publication = commit(snapshot)
        guard current(token, source: source), revision == publication else { return false }
        let captured = facts()
        guard !blockRecording(factor, captured: captured) else { return false }
        guard let next = CamFov.colorMode(forZoom: factor, current: captured.status.colorMode)
        else {
            if !captured.previewing, snapshot.pendingFactor == nil, !snapshot.hopPending {
                return restoreIfNeeded(afterZoom: factor, suppliedAdmission: admission)
            }
            return true
        }
        return sendColorOnce(next, admission: admission)
    }

    public func holding(_ factor: Double) -> Bool {
        CamFov.holdZoomWrite(
            factor: factor, current: facts().status.colorMode, hopPending: snapshot.hopPending)
    }

    public func queue(_ factor: Double, onStage: (@MainActor (ControlWireEvent) -> Void)?) {
        _ = queuePublication(factor, onStage: onStage, admission: nil)
    }
    public func queue(
        _ factor: Double, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        _ = queuePublication(factor, onStage: onStage, admission: admission)
    }

    private func queuePublication(
        _ factor: Double, onStage: (@MainActor (ControlWireEvent) -> Void)?,
        admission: DJICommandAdmission?
    ) -> UInt64? {
        guard admission?.isCurrent ?? true else {
            onStage?(.notSent)
            return nil
        }
        let token = generation
        let source = binding()
        let previous = pendingStage
        pendingStage = onStage
        pendingAdmission = admission
        pendingBinding = source
        var next = snapshot
        next.pendingFactor = factor
        let publication = commit(next)
        // The new request is committed before outgoing accounting can synchronously enqueue a successor.
        previous?(.notSent)
        guard current(token, source: source), revision == publication else { return nil }
        return publication
    }

    @discardableResult public func discardPending() -> Bool {
        let token = generation
        let source = binding()
        let previous = pendingStage
        pendingStage = nil
        pendingBinding = nil
        pendingAdmission = nil
        var next = snapshot
        next.pendingFactor = nil
        let publication = commit(next)
        previous?(.notSent)
        return current(token, source: source) && revision == publication
    }

    @discardableResult public func retireForProgrammedZoom() -> Bool {
        let token = generation
        let source = binding()
        let previous = pendingStage
        pendingStage = nil
        pendingBinding = nil
        pendingAdmission = nil
        var next = snapshot
        next.pendingFactor = nil
        next.restoreOnWide = false
        let publication = commit(next)
        previous?(.notSent)
        return current(token, source: source) && revision == publication
    }

    @discardableResult public func manualColorSelected(_ mode: ColorMode) -> Bool {
        if mode == .dLog2 {
            generation &+= 1
            deadline = nil
        }
        let token = generation
        let source = binding()
        var next = snapshot
        if mode == .dLog2 { next.hopPending = false }
        let publication = commit(next)
        return current(token, source: source) && revision == publication
    }

    /// Call only after the host commits its actual incoming camera status, or an existing manual D-Log check.
    public func confirmIfReady() { _ = confirmReadyPublication() }

    private func confirmReadyPublication() -> UInt64? {
        guard snapshot.hopPending, hopBinding == binding(), facts().status.colorMode == .dLog else {
            return nil
        }
        let token = generation
        let source = binding()
        deadline = nil
        var next = snapshot
        next.hopPending = false
        let publication = commit(next)
        guard current(token, source: source), revision == publication else { return nil }
        event(.confirmed)
        guard current(token, source: source), revision == publication else { return nil }
        return flushPendingPublication()
    }

    public func slider(_ factor: Double, onStage: (@MainActor (ControlWireEvent) -> Void)? = nil) {
        _ = sliderPublication(factor, onStage: onStage, admission: nil)
    }
    public func slider(
        _ factor: Double, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)? = nil
    ) {
        _ = sliderPublication(factor, onStage: onStage, admission: admission)
    }

    private func sliderPublication(
        _ factor: Double, onStage: (@MainActor (ControlWireEvent) -> Void)?,
        admission: DJICommandAdmission?
    ) -> UInt64? {
        guard admission?.isCurrent ?? true else {
            onStage?(.notSent)
            return nil
        }
        let captured = facts()
        guard !captured.locked else {
            event(.locked)
            onStage?(.notSent)
            return nil
        }
        guard !blockRecording(factor, captured: captured) else {
            onStage?(.notSent)
            return nil
        }
        guard dropForZoom(factor, suppliedAdmission: admission) else {
            onStage?(.notSent)
            return nil
        }
        let token = generation
        let source = binding()
        if holding(factor) {
            return queuePublication(factor, onStage: onStage, admission: admission)
        }
        let publication = revision
        event(.slewCleared)
        guard current(token, source: source), revision == publication else {
            onStage?(.notSent)
            return nil
        }
        return firePublication(
            .lens(CamFov.pinchLens(for: factor)), target: CamFov.displayTenths(factor),
            announce: false,
            onStage: onStage, admission: admission)
    }

    public func fire(
        _ write: CamFov.ChipWrite, target: Double?, announce: Bool,
        onStage: (@MainActor (ControlWireEvent) -> Void)? = nil
    ) {
        _ = firePublication(
            write, target: target, announce: announce, onStage: onStage, admission: nil)
    }
    public func fire(
        _ write: CamFov.ChipWrite, target: Double?, announce: Bool,
        admission: DJICommandAdmission, onStage: (@MainActor (ControlWireEvent) -> Void)? = nil
    ) {
        _ = firePublication(
            write, target: target, announce: announce, onStage: onStage, admission: admission)
    }

    private func firePublication(
        _ write: CamFov.ChipWrite, target: Double?, announce: Bool,
        onStage: (@MainActor (ControlWireEvent) -> Void)?, admission: DJICommandAdmission?
    ) -> UInt64? {
        guard admission?.isCurrent ?? true else {
            onStage?(.notSent)
            return nil
        }
        let captured = facts()
        guard captured.supportsZoom else {
            onStage?(.notSent)
            return nil
        }
        let token = generation
        let source = binding()
        let publication = commit(snapshot)
        guard current(token, source: source), revision == publication else {
            onStage?(.notSent)
            return nil
        }
        let frame: Duml.Frame
        let name: String
        switch write {
        case .lens(let position):
            frame = Commands.setZoomLens(position)
            name = target.map { "Zoom \(CamFov.displayLabel(factor: $0))" } ?? "Zoom slider"
        case .slew(let value):
            frame = Commands.setZoomSlew(value)
            name =
                target.map { "Zoom \(CamFov.displayLabel(factor: $0))" }
                ?? (value == CamFov.slewTele
                    ? "Zoom 1×" : value == CamFov.slewWide ? "Zoom 3×" : "Zoom slew")
        }
        event(.zoomPreparing)
        guard current(token, source: source), revision == publication else {
            onStage?(.notSent)
            return nil
        }
        send(
            .init(
                frame, name: name, expectation: announce ? target.map { .zoom($0) } : nil,
                retransmits: announce, coalesce: !announce, admission: admission)
        ) { [weak self] callback in
            guard let self, self.current(token, source: source) else { return }
            switch callback {
            case .stage(let value): onStage?(value)
            case .failed: break
            case .settled(let success):
                self.event(
                    .zoomSettled(frame: frame, name: name, announce: announce, success: success))
            }
        }
        guard current(token, source: source), revision == publication else { return nil }
        return publication
    }

    @discardableResult public func restoreIfNeeded(afterZoom factor: Double) -> Bool {
        restoreIfNeeded(afterZoom: factor, suppliedAdmission: nil)
    }
    @discardableResult public func restoreIfNeeded(
        afterZoom factor: Double,
        admission: DJICommandAdmission
    ) -> Bool {
        restoreIfNeeded(afterZoom: factor, suppliedAdmission: admission)
    }
    private func restoreIfNeeded(
        afterZoom factor: Double,
        suppliedAdmission admission: DJICommandAdmission?
    ) -> Bool {
        guard admission?.isCurrent ?? true else { return false }
        guard snapshot.restoreOnWide, CamFov.shouldRestoreDLog2(factor: factor) else { return true }
        let captured = facts()
        guard !captured.status.isRecording else { return true }
        let token = generation
        let source = binding()
        var next = snapshot
        next.restoreOnWide = false
        let publication = commit(next)
        guard current(token, source: source), revision == publication else { return false }
        event(.restoredPreparing(from: captured.status.colorMode))
        guard current(token, source: source), revision == publication else { return false }
        send(
            .init(
                Commands.setColorMode(.dLog2, model: captured.model), name: "D-Log2",
                expectation: .color(.dLog2), admission: admission)
        ) {
            [weak self] callback in
            guard let self, self.current(token, source: source) else { return }
            switch callback {
            case .stage: break
            case .failed: self.event(.restoreFailed)
            case .settled(let success): self.event(.restoreSettled(success))
            }
        }
        guard current(token, source: source) else { return false }
        publishNativeISO(from: captured.status.colorMode, to: .dLog2, admission: admission)
        return current(token, source: source) && revision == publication
    }

    private func commit(_ next: Snapshot) -> UInt64 {
        let previous = snapshot
        snapshot = next
        revision &+= 1
        let publication = revision
        event(.changed(previous: previous, next: next, revision: publication))
        return publication
    }
    /// Integration-internal synchronous admission. Nested operator actions replace the
    /// predicate while they run; restoring it lets the outgoing action reject itself.
    /// No predicate is retained by wire callbacks or changes the existing default API.
    func withGestureAdmission<T>(_ admission: @escaping () -> Bool, _ operation: () -> T) -> T {
        let previous = gestureAdmission
        gestureAdmission = admission
        defer { gestureAdmission = previous }
        return operation()
    }

    private func current(_ token: UInt64, source: DjiAppleSettingsBinding) -> Bool {
        generation == token && binding() == source && !Task.isCancelled
            && (gestureAdmission?() ?? true)
    }
    private func blockRecording(_ factor: Double, captured: Facts) -> Bool {
        guard
            CamFov.zoomNeedsColorHopWhileRecording(
                factor: factor, current: captured.status.colorMode,
                isRecording: captured.status.isRecording
            )
        else { return false }
        event(.recordingBlocked)
        return true
    }
    private func sendColorOnce(_ mode: ColorMode, admission: DJICommandAdmission?) -> Bool {
        guard admission?.isCurrent ?? true else { return false }
        let captured = facts()
        guard !captured.status.isRecording else {
            event(.recordingBlocked)
            return false
        }
        if snapshot.hopPending {
            guard let deadline, now() >= deadline else { return true }
            let token = generation
            let source = binding()
            let publication = revision
            event(.hopRetry)
            guard current(token, source: source), revision == publication else { return false }
        }
        generation &+= 1
        let token = generation
        let source = binding()
        deadline = now().addingTimeInterval(2)
        hopBinding = source
        var next = snapshot
        next.hopPending = true
        next.restoreOnWide = true
        let publication = commit(next)
        guard current(token, source: source), revision == publication else { return false }
        event(.hopPreparing(from: captured.status.colorMode, to: mode))
        guard current(token, source: source), revision == publication else { return false }
        var admittedPublication = publication
        send(
            .init(
                Commands.setColorMode(mode, model: captured.model), name: "D-Log (zoom)",
                expectation: .color(mode), admission: admission)
        ) {
            [weak self] callback in
            guard let self, self.current(token, source: source) else { return }
            switch callback {
            case .stage: break
            case .failed:
                self.deadline = nil
                var next = self.snapshot
                next.restoreOnWide = false
                next.hopPending = false
                let publication = self.commit(next)
                guard self.current(token, source: source), self.revision == publication else {
                    return
                }
                self.event(.hopFailed)
                guard self.current(token, source: source), self.revision == publication else {
                    return
                }
                admittedPublication = publication
            case .settled(let success):
                let publication = self.revision
                self.event(.hopSettled(success))
                guard self.current(token, source: source), self.revision == publication else {
                    return
                }
                if success {
                    if let ownedPublication = self.confirmReadyPublication() {
                        admittedPublication = ownedPublication
                    }
                } else {
                    self.deadline = nil
                    var next = self.snapshot
                    next.hopPending = false
                    let publication = self.commit(next)
                    guard self.current(token, source: source), self.revision == publication else {
                        return
                    }
                    admittedPublication = publication
                }
            }
        }
        guard current(token, source: source), revision == admittedPublication else { return false }
        publishNativeISO(from: captured.status.colorMode, to: mode, admission: admission)
        return current(token, source: source) && revision == admittedPublication
    }
    private func publishNativeISO(from: ColorMode?, to: ColorMode, admission: DJICommandAdmission?)
    {
        if let admission {
            guard admission.isCurrent else { return }
            admittedNativeISO?(from, to, admission)
        } else {
            event(.nativeISO(from: from, to: to))
        }
    }

    private func flushPendingPublication() -> UInt64? {
        guard let factor = snapshot.pendingFactor, !holding(factor) else { return revision }
        guard pendingBinding == binding() else {
            return discardPending() ? revision : nil
        }
        let token = generation
        let source = binding()
        let onStage = pendingStage
        let admission = pendingAdmission
        pendingStage = nil
        pendingBinding = nil
        pendingAdmission = nil
        var next = snapshot
        next.pendingFactor = nil
        let publication = commit(next)
        guard current(token, source: source), revision == publication else {
            onStage?(.notSent)
            return nil
        }
        guard admission?.isCurrent ?? true else {
            onStage?(.notSent)
            return publication
        }
        event(.flushed(factor))
        guard current(token, source: source), revision == publication else {
            onStage?(.notSent)
            return nil
        }
        // Use the same slider recipe directly, never an app-owned whole workflow callback.
        return sliderPublication(factor, onStage: onStage, admission: admission)
    }
}
