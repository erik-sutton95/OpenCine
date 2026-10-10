import Foundation
import Insta360Protocol

/// One Luna connection's Deep Track and tap focus. The camera reports Deep Track on every video
/// frame (media 0x85) and its end on notification 8315; requests go out through the session.
/// Control admission, notes and the face box stay with the app.
@MainActor public final class LunaSubjectTracking {
    /// Top-left box in preview fractions, the Luna wire's own frame.
    public struct Box: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// The green box shown when the camera locks a search box: 45% of each side, at least
        /// 0.05, centred in the search box.
        public func subject() -> Box {
            let w = min(max(width * 0.45, 0.05), width)
            let h = min(max(height * 0.45, 0.05), height)
            return Box(x: x + (width - w) / 2, y: y + (height - h) / 2, width: w, height: h)
        }
    }

    public struct Snapshot: Equatable, Sendable {
        /// The operator's request, or the last box while the camera has lost the subject.
        public var searchBox: Box?
        /// The camera's locked subject.
        public var subjectBox: Box?
        public var tracking: Bool
        public var active: Bool { tracking || searchBox != nil || subjectBox != nil }

        public init(searchBox: Box? = nil, subjectBox: Box? = nil, tracking: Bool = false) {
            self.searchBox = searchBox
            self.subjectBox = subjectBox
            self.tracking = tracking
        }
    }

    public private(set) var snapshot = Snapshot()
    private var sawLock = false
    private let session: @MainActor () -> LunaCameraSession?
    private let changed: @MainActor (Snapshot) -> Void

    /// `session` is the connection's current session; `changed` hears every published snapshot.
    public init(
        session: @escaping @MainActor () -> LunaCameraSession?,
        changed: @escaping @MainActor (Snapshot) -> Void = { _ in }
    ) {
        self.session = session
        self.changed = changed
    }

    /// Whether the session would send a request now.
    public var admitsControl: Bool { session()?.admitsControl == true }

    /// cmd 237 with the operator's rectangle, kept inside the frame. A request that cannot be
    /// built throws; a request the camera does not apply clears the search before `finished`.
    public func start(_ box: Box, finished: @escaping @MainActor (Error?) -> Void = { _ in }) throws
    {
        sawLock = false
        publish(Snapshot(searchBox: box))
        let left = min(max(box.x, 0), 1)
        let top = min(max(box.y, 0), 1)
        let request: LunaRequest
        do {
            request = try LunaProtocol.openTracking(
                x: left, y: top, width: min(box.width, 1 - left), height: min(box.height, 1 - top))
        } catch {
            clear()
            throw error
        }
        send(request) { [weak self] error in
            if error != nil { self?.clear() }
            finished(error)
        }
    }

    /// Clears locally first; the camera's cancel goes out only when tracking was active and the
    /// session admits control.
    public func cancel(finished: @escaping @MainActor (Error?) -> Void = { _ in }) {
        cancel(suppliedAdmission: nil, finished: finished)
    }

    public func cancel(
        admission: LunaCommandAdmission, finished: @escaping @MainActor (Error?) -> Void = { _ in }
    ) {
        cancel(suppliedAdmission: admission, finished: finished)
    }

    private func cancel(
        suppliedAdmission admission: LunaCommandAdmission?,
        finished: @escaping @MainActor (Error?) -> Void
    ) {
        if let admission {
            guard let target = session(), admission.admits(target.commandOwner) else { return }
            let epoch = target.current.epoch
            let had = snapshot.active
            clear()
            // Publishing the local clear can synchronously replace the producer. Never send
            // that operation on the replacement or clear its newly published tracking again.
            guard had, session() === target, target.current.epoch == epoch,
                admission.admits(target.commandOwner), target.admitsControl
            else { return }
            send(
                LunaProtocol.cancelTrackingRequest, through: target, admission: admission,
                finished: finished)
        } else {
            let had = snapshot.active
            clear()
            guard had, admitsControl else { return }
            send(LunaProtocol.cancelTrackingRequest, finished: finished)
        }
    }

    /// Tap focus at a preview point with the fw 1.1.15 official ROI for an upright camera:
    /// 0.1545 × 0.2727 of the 16:9 preview (square on the sensor), centred on the tap and kept
    /// inside the frame.
    public func focus(
        x: Double, y: Double, finished: @escaping @MainActor (Error?) -> Void = { _ in }
    )
        throws
    {
        try focus(x: x, y: y, suppliedAdmission: nil, finished: finished)
    }

    public func focus(
        x: Double, y: Double, admission: LunaCommandAdmission,
        finished: @escaping @MainActor (Error?) -> Void = { _ in }
    ) throws {
        try focus(x: x, y: y, suppliedAdmission: admission, finished: finished)
    }

    private func focus(
        x: Double, y: Double, suppliedAdmission admission: LunaCommandAdmission?,
        finished: @escaping @MainActor (Error?) -> Void
    ) throws {
        let w = 0.1545
        let h = 0.2727
        let left = min(max(x - w / 2, 0), 1 - w)
        let top = min(max(y - h / 2, 0), 1 - h)
        guard let session = session() else { return finished(CancellationError()) }
        if let admission { try admission.require(owner: session.commandOwner) }
        let request = try LunaProtocol.setTapFocus(
            x: left, y: top, width: w, height: h, functionMode: session.requestFunctionMode)
        if let admission {
            send(request, through: session, admission: admission, finished: finished)
        } else {
            send(request, finished: finished)
        }
    }

    /// Media 0x85: tracking moves the subject box with the camera's box; lost shows the last box
    /// as a search box until the camera reacquires or the operator cancels; idle after a lock
    /// means the camera ended tracking. Idle frames also arrive before the first lock.
    public func ingest(_ frame: LunaTrackFrame) {
        let box = Box(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        switch frame.state {
        case .tracking:
            sawLock = true
            publish(Snapshot(subjectBox: box, tracking: true))
        case .lost:
            guard sawLock else { return }
            publish(Snapshot(searchBox: box))
        case .idle:
            if sawLock { clear() }
        case nil:
            break
        }
    }

    /// Notification 8315: states 1 and 2 are a lock (a search box becomes the subject); any other
    /// state ends tracking once a lock was seen or a search is pending.
    public func ingest(trackingState state: UInt64) {
        switch state {
        case 1, 2:
            sawLock = true
            publish(
                Snapshot(
                    subjectBox: snapshot.searchBox?.subject() ?? snapshot.subjectBox, tracking: true
                ))
        default:
            if sawLock || snapshot.searchBox != nil { clear() }
        }
    }

    public func clear() {
        sawLock = false
        publish(Snapshot())
    }

    /// Hides the boxes but keeps whether the camera has locked, so its next report draws them
    /// again ("Frame Too Small" leaves the camera's own tracking alone).
    public func clearBoxes() { publish(Snapshot()) }

    private func publish(_ next: Snapshot) {
        snapshot = next
        changed(next)
    }

    private func send(
        _ request: LunaRequest, through target: LunaCameraSession? = nil,
        admission: LunaCommandAdmission? = nil, finished: @escaping @MainActor (Error?) -> Void
    ) {
        let session = target ?? session()
        Task { @MainActor in
            do {
                guard let session else { throw CancellationError() }
                if let admission {
                    _ = try await session.control(request, admission: admission)
                } else {
                    _ = try await session.control(request)
                }
                finished(nil)
            } catch {
                finished(error)
            }
        }
    }
}
