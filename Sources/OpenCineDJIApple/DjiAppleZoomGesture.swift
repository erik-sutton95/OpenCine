import Foundation
import OpenCineDJI

/// DJI zoom interaction owns its gesture, requested chip and telemetry projection.
/// The real color owner continues to admit and send protocol work.
@MainActor
public final class DjiAppleZoomGesture {
    public struct Facts {
        public var status: CameraStatus
        public var stops: [Double]
        public var supportsZoom: Bool
        public var locked: Bool
        public init(status: CameraStatus, stops: [Double], supportsZoom: Bool, locked: Bool) {
            self.status = status
            self.stops = stops
            self.supportsZoom = supportsZoom
            self.locked = locked
        }
    }
    public struct Snapshot: Equatable, Sendable {
        public var stop: Double = 1
        public var preview: Double?
        public var optimistic: Double?
        fileprivate var pinDeadline: TimeInterval?
        fileprivate var touched = false
        fileprivate var anchor: Double = 1
        fileprivate var lastLens: UInt16?
        fileprivate var lastLogTenths: Double?
        public init() {}
    }
    public enum Event {
        case changed(previous: Snapshot, next: Snapshot, revision: UInt64)
        case cancelProgrammedMove
        case chipRequested(from: String, to: String)
        case unavailableChip(String)
        case chipPreparing(String)
        case sliderRequested(factor: Double, lens: UInt16)
        case slewRequested(UInt16)
        case stopRequested
        case stopPreparing
        case stopSettled(frame: Duml.Frame, success: Bool)
        case locked
        case recordingBlocked
    }
    public struct Authority {
        fileprivate var generation: UInt64
        fileprivate var source: DjiAppleSettingsBinding
        fileprivate var revision: UInt64
    }
    public private(set) var snapshot = Snapshot()
    public private(set) var revision: UInt64 = 0
    private var generation: UInt64 = 0
    private var invocation: UInt64 = 0
    private let binding: () -> DjiAppleSettingsBinding
    private let facts: () -> Facts
    private let color: DjiAppleZoomColor
    private let now: () -> TimeInterval
    private let event: (Event) -> Void
    private let sendStop: (Duml.Frame, @escaping @MainActor (Bool) -> Void) -> Void

    public init(
        binding: @escaping () -> DjiAppleSettingsBinding, facts: @escaping () -> Facts,
        color: DjiAppleZoomColor,
        now: @escaping () -> TimeInterval = { Date.timeIntervalSinceReferenceDate },
        sendStop: @escaping (Duml.Frame, @escaping @MainActor (Bool) -> Void) -> Void,
        event: @escaping (Event) -> Void = { _ in }
    ) {
        self.binding = binding
        self.facts = facts
        self.color = color
        self.now = now
        self.sendStop = sendStop
        self.event = event
    }
    public var authority: Authority {
        .init(generation: generation, source: binding(), revision: revision)
    }
    public func admits(_ token: Authority) -> Bool {
        token.generation == generation && token.source == binding() && token.revision == revision
    }
    public var fallback: Double { CamFov.stopWithinCycle(snapshot.stop, stops: facts().stops) }
    public var readout: Double {
        CamFov.readout(
            live: facts().status.zoomFactor,
            preview: color.snapshot.hopPending ? nil : snapshot.preview, fallback: fallback,
            optimistic: color.snapshot.hopPending ? nil : snapshot.optimistic)
    }
    public var dialReadout: Double {
        CamFov.continuousReadout(
            live: facts().status.zoomFactor, preview: snapshot.preview,
            fallback: fallback, optimistic: snapshot.optimistic)
    }
    public func reset() {
        generation &+= 1
        invocation &+= 1
        let admitted = commit(.init())
        guard admits(admitted) else { return }
        color.reset()
    }
    public func observe(_ status: CameraStatus) {
        var next = snapshot
        if let expected = next.optimistic {
            if now() >= (next.pinDeadline ?? now())
                || status.zoomFactor.map({ CamFov.matches($0, expected) }) == true
            {
                next.optimistic = nil
                next.pinDeadline = nil
            }
        }
        if !next.touched, let factor = status.zoomFactor {
            if abs(factor - CamFov.maxFactor) < 0.15 {
                next.stop = 12
            } else if abs(factor - 6) < 0.2 {
                next.stop = 6
            } else if abs(factor - 3) < 0.2 {
                next.stop = 3
            } else if factor < 2.5 {
                next.stop = 1
            }
        }
        if next != snapshot { _ = commit(next) }
    }
    public func updatePinch(magnification: Double) {
        guard facts().supportsZoom else { return }
        var admitted = begin()
        event(.cancelProgrammedMove)
        guard admits(admitted) else { return }
        if snapshot.preview == nil {
            var next = snapshot
            next.anchor = facts().status.zoomFactor ?? next.optimistic ?? next.stop
            next.optimistic = nil
            next.pinDeadline = nil
            next.lastLens = nil
            next.lastLogTenths = nil
            admitted = commit(next)
            guard admits(admitted) else { return }
        }
        let factor = CamFov.pinchFactor(
            anchor: snapshot.anchor, magnification: magnification,
            max: facts().stops.last ?? 1)
        guard !blocksRecording(factor), admits(admitted) else { return }
        guard inColor { color.dropForZoom(factor) }, admits(admitted) else { return }
        if color.holding(factor) {
            inColor { color.queue(factor, onStage: nil) }
            guard admits(admitted) else { return }
            var next = snapshot
            next.preview = factor
            _ = commit(next)
            return
        }
        guard inColor { color.discardPending() }, admits(admitted) else { return }
        let source = color.authority
        let first = snapshot.preview == nil
        var next = snapshot
        next.preview = factor
        admitted = commit(next)
        guard admits(admitted), color.admits(source) else { return }
        let lens = CamFov.pinchLens(for: factor)
        if first && abs(factor - snapshot.anchor) < 0.01 { return }
        if snapshot.lastLens == lens { return }
        next = snapshot
        next.lastLens = lens
        admitted = commit(next)
        guard admits(admitted), color.admits(source) else { return }
        slider(factor)
    }
    public func endPinch() {
        var admitted = begin()
        guard inColor { color.discardPending() }, admits(admitted) else { return }
        let source = color.authority
        if let preview = snapshot.preview {
            admitted = markStop(preview)
            guard admits(admitted), color.admits(source) else { return }
            guard inColor { color.restoreIfNeeded(afterZoom: preview) }, admits(admitted) else {
                return
            }
        }
        var next = snapshot
        next.preview = nil
        _ = commit(next)
    }
    public func chip(_ factor: Double, onStage: (@MainActor (ControlWireEvent) -> Void)? = nil) {
        chip(factor, suppliedAdmission: nil, onStage: onStage)
    }
    public func chip(
        _ factor: Double, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)? = nil
    ) {
        chip(factor, suppliedAdmission: admission, onStage: onStage)
    }
    private func chip(
        _ factor: Double, suppliedAdmission admission: DJICommandAdmission?,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        guard admission?.isCurrent ?? true else {
            onStage?(.notSent)
            return
        }
        guard facts().supportsZoom else {
            onStage?(.notSent)
            return
        }
        var admitted = begin()
        event(.cancelProgrammedMove)
        guard admits(admitted) else {
            onStage?(.notSent)
            return
        }
        let from = CamFov.displayLabel(factor: readout)
        let to = CamFov.displayLabel(factor: factor)
        event(.chipRequested(from: from, to: to))
        guard admits(admitted) else {
            onStage?(.notSent)
            return
        }
        guard !facts().locked else {
            event(.locked)
            onStage?(.notSent)
            return
        }
        guard let write = CamFov.chipWrite(forJump: factor) else {
            event(.unavailableChip(to))
            onStage?(.notSent)
            return
        }
        guard !blocksRecording(factor), admits(admitted) else {
            onStage?(.notSent)
            return
        }
        var next = snapshot
        next.preview = nil
        admitted = commit(next)
        guard admits(admitted),
            inColor({
                if let admission { return color.dropForZoom(factor, admission: admission) }
                return color.dropForZoom(factor)
            }), admits(admitted)
        else {
            onStage?(.notSent)
            return
        }
        if color.holding(factor) {
            inColor {
                if let admission {
                    color.queue(factor, admission: admission, onStage: onStage)
                } else {
                    color.queue(factor, onStage: onStage)
                }
            }
            return
        }
        let source = color.authority
        next = snapshot
        next.optimistic = factor
        next.pinDeadline = now() + 2
        admitted = commit(next)
        guard admits(admitted), color.admits(source) else {
            onStage?(.notSent)
            return
        }
        admitted = markStop(factor)
        guard admits(admitted), color.admits(source) else {
            onStage?(.notSent)
            return
        }
        event(.chipPreparing(to))
        guard admits(admitted), color.admits(source) else {
            onStage?(.notSent)
            return
        }
        inColor {
            if let admission {
                color.fire(
                    write, target: factor, announce: true, admission: admission, onStage: onStage)
            } else {
                color.fire(write, target: factor, announce: true, onStage: onStage)
            }
        }
    }
    public func slider(_ factor: Double, onStage: (@MainActor (ControlWireEvent) -> Void)? = nil) {
        slider(factor, suppliedAdmission: nil, onStage: onStage)
    }
    public func slider(
        _ factor: Double, admission: DJICommandAdmission,
        onStage: (@MainActor (ControlWireEvent) -> Void)? = nil
    ) {
        slider(factor, suppliedAdmission: admission, onStage: onStage)
    }
    private func slider(
        _ factor: Double, suppliedAdmission admission: DJICommandAdmission?,
        onStage: (@MainActor (ControlWireEvent) -> Void)?
    ) {
        guard admission?.isCurrent ?? true else {
            onStage?(.notSent)
            return
        }
        let admitted = begin()
        event(.cancelProgrammedMove)
        guard admits(admitted) else {
            onStage?(.notSent)
            return
        }
        guard noteSlider(factor), admitsCurrentSource(admitted) else {
            onStage?(.notSent)
            return
        }
        inColor {
            if let admission {
                color.slider(factor, admission: admission, onStage: onStage)
            } else {
                color.slider(factor, onStage: onStage)
            }
        }
    }
    public func slew(_ value: UInt16) {
        let admitted = begin()
        event(.cancelProgrammedMove)
        guard admits(admitted) else { return }
        event(.slewRequested(value))
        guard admits(admitted) else { return }
        guard !facts().locked else {
            event(.locked)
            return
        }
        let target =
            value == CamFov.slewTele ? 12.0 : value == CamFov.slewWide ? CamFov.slewDetent : 0
        inColor { color.fire(.slew(value), target: target > 0 ? target : nil, announce: false) }
    }
    public func stop() {
        let admitted = begin()
        event(.cancelProgrammedMove)
        guard admits(admitted) else { return }
        event(.stopRequested)
        guard admits(admitted), !facts().locked, facts().supportsZoom else { return }
        event(.stopPreparing)
        guard admits(admitted) else { return }
        let frame = Commands.setZoomStop()
        sendStop(frame) { [weak self] ok in
            guard let self, self.admitsCurrentSource(admitted) else { return }
            self.event(.stopSettled(frame: frame, success: ok))
        }
    }
    @discardableResult public func retireForProgrammedZoom() -> Bool {
        var next = snapshot
        next.preview = nil
        let admitted = commit(next)
        guard admits(admitted), inColor { color.retireForProgrammedZoom() }, admits(admitted) else {
            return false
        }
        next = snapshot
        next.optimistic = nil
        next.pinDeadline = nil
        return admits(commit(next))
    }
    /// Color confirmation has already admitted the original pending factor.
    @discardableResult public func flushed(_ factor: Double) -> Bool {
        let source = color.authority
        var next = snapshot
        next.preview = factor
        var admitted = commit(next)
        guard admits(admitted), color.admits(source) else { return false }
        admitted = markStop(factor)
        guard admits(admitted), color.admits(source) else { return false }
        event(.cancelProgrammedMove)
        guard admits(admitted), color.admits(source) else { return false }
        return noteSlider(factor) && color.admits(source)
    }
    /// Incoming status is already committed by the native host. The gesture invocation
    /// remains captured while its own flush publishes a newer presentation revision.
    public func confirmIfReady() { inColor { color.confirmIfReady() } }

    private func begin() -> Authority {
        invocation &+= 1
        return commit(snapshot)
    }

    private func inColor<T>(_ operation: () -> T) -> T {
        let generation = generation
        let source = binding()
        let invocation = invocation
        return color.withGestureAdmission(
            { [weak self] in
                guard let self else { return false }
                return self.generation == generation && self.binding() == source
                    && self.invocation == invocation
            }, operation)
    }

    private func admitsCurrentSource(_ token: Authority) -> Bool {
        token.generation == generation && token.source == binding()
    }
    private func blocksRecording(_ factor: Double) -> Bool {
        let captured = facts().status
        guard
            CamFov.zoomNeedsColorHopWhileRecording(
                factor: factor, current: captured.colorMode,
                isRecording: captured.isRecording)
        else { return false }
        event(.recordingBlocked)
        return true
    }
    private func markStop(_ factor: Double) -> Authority {
        var next = snapshot
        next.stop = factor
        next.touched = true
        return commit(next)
    }
    private func noteSlider(_ factor: Double) -> Bool {
        let tenths = CamFov.displayTenths(factor)
        guard snapshot.lastLogTenths != tenths else { return true }
        var next = snapshot
        next.lastLogTenths = tenths
        let admitted = commit(next)
        guard admits(admitted) else { return false }
        event(.sliderRequested(factor: factor, lens: CamFov.pinchLens(for: factor)))
        return admits(admitted)
    }
    private func commit(_ next: Snapshot) -> Authority {
        let previous = snapshot
        snapshot = next
        revision &+= 1
        let admitted = authority
        event(.changed(previous: previous, next: next, revision: revision))
        return admitted
    }
}
