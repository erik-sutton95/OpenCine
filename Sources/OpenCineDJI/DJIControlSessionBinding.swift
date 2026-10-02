import Foundation
import OpenCineCore

/// One native connection's common-control lifetime. Operator reconnects replace it; datalink
/// recovery keeps it. The native owner supplies teardown, which can run only for its current
/// binding. The binding itself sends no camera commands.
@MainActor
public final class DJIControlSessionBinding {
    private unowned let port: any DJIControlPort
    private let now: @Sendable () -> MonotonicInstant
    private let onClose: @MainActor (SessionCloseReason) -> Void
    private var owner: UUID?

    /// The current adapter, if somebody requested it. Notifications must not create a session.
    public private(set) var cached: DJICameraSessionAdapter?

    public init(
        port: any DJIControlPort,
        onClose: @escaping @MainActor (SessionCloseReason) -> Void,
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now
    ) {
        self.port = port
        self.onClose = onClose
        self.now = now
    }

    /// The connection's one adapter. A retired connection's adapter is never reused.
    public var session: DJICameraSessionAdapter {
        if let cached { return cached }
        let owner = UUID()
        self.owner = owner
        let session = DJICameraSessionAdapter(
            session: port, now: now,
            onClose: { [weak self] reason in
                self?.close(owner: owner, reason: reason)
            })
        cached = session
        return session
    }

    /// Before a new operator connection changes the native target. Link recovery does not call
    /// this: its adapter stays bound and advances its existing control epoch instead.
    public func beginConnection() {
        retire(.replaced)
    }

    /// Native teardown or borrowed return already owns cleanup. Retire the common seam without
    /// invoking native cleanup again. Clear its owner before closing, including reentrant calls.
    public func retire(_ reason: SessionCloseReason) {
        let previous = cached
        owner = nil
        cached = nil
        previous?.close(reason)
    }

    private func close(owner: UUID, reason: SessionCloseReason) {
        guard self.owner == owner else { return }
        self.owner = nil
        cached = nil
        onClose(reason)
    }
}
