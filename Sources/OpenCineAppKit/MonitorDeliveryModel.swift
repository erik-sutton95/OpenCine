import Foundation
import Observation
import OpenCineCore

private final class MonitorDeliveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var retired = false
    func cancel() {
        lock.lock()
        retired = true
        lock.unlock()
    }
    var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !retired
    }
}

/// A captured handle to the existing delivery task. Retirement never borrows a successor run.
public struct MonitorDeliveryRunHandle: Sendable {
    private let work: Task<Void, Never>
    private let cancelCaptured: @MainActor @Sendable () -> Void
    fileprivate init(
        work: Task<Void, Never>, cancelCaptured: @escaping @MainActor @Sendable () -> Void
    ) {
        self.work = work
        self.cancelCaptured = cancelCaptured
    }
    public func awaitEnteredCleanup() async { await work.value }
    @MainActor public func cancel() {
        cancelCaptured()
        work.cancel()
    }
    @MainActor public func cancelAndJoin() async {
        cancel()
        await work.value
    }
}

/// App-owned completion facts. The shell chooses no destination, file or storage namespace.
public struct MonitorDeliveryCompletion<Outcome: Sendable, Share: Sendable>: Sendable {
    public let outcome: Outcome
    public let share: Share?
    public let toast: String?
    public init(_ outcome: Outcome, share: Share? = nil, toast: String? = nil) {
        self.outcome = outcome
        self.share = share
        self.toast = toast
    }
}

public struct MonitorDeliveryShare<Payload: Sendable>: Identifiable, Sendable {
    public let id: UUID
    public let payload: Payload
}

public struct MonitorDeliveryState<Progress: Sendable, Share: Sendable>: Sendable {
    public fileprivate(set) var running = false
    public fileprivate(set) var progress: Progress?
    public fileprivate(set) var share: MonitorDeliveryShare<Share>?
    public fileprivate(set) var toast: String?
    public fileprivate(set) var expanded = false
    public fileprivate(set) var localOverlayDepth = 0
    public var showsLocalOverlay: Bool { localOverlayDepth > 0 }
    public var showsGlobalChrome: Bool { progress != nil && !showsLocalOverlay }
    /// The root chrome yields while any media surface is mounted; a surface always shows its run.
    public func progress(in scope: MonitorDeliveryChromeScope) -> Progress? {
        scope == .root && showsLocalOverlay ? nil : progress
    }
    public func toast(in scope: MonitorDeliveryChromeScope) -> String? {
        scope == .root && showsLocalOverlay ? nil : toast
    }
}

/// Where a delivery chrome is mounted: once at the app root, or on a media surface.
public enum MonitorDeliveryChromeScope: Sendable { case root, surface }

/// One app-scoped delivery lifetime, including cancellation and presentation resource leases.
/// Export, transfer, network admission and OS presentation stay in the supplied operation.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorDeliveryModel<Progress: Sendable, Outcome: Sendable, Share: Sendable> {
    public var state: MonitorDeliveryState<Progress, Share> {
        _ = publication
        return committed
    }
    @ObservationIgnored private var committed = MonitorDeliveryState<Progress, Share>()
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var notifying = false
    private var publication: UInt64 = 0
    @ObservationIgnored private var shareRun: UUID?
    @ObservationIgnored private var pendingShareAcknowledgement: (id: UUID, run: UUID)?
    @ObservationIgnored private var run = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cancelHandler: (() -> Void)?
    @ObservationIgnored private var toastID = UUID()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private let releaseShare: @MainActor (Share) -> Void

    public init(
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:),
        releaseShare: @escaping @MainActor (Share) -> Void = { _ in }
    ) {
        self.sleep = sleep
        self.releaseShare = releaseShare
    }

    public func begin(
        onCancel: (() -> Void)? = nil,
        onComplete: ((Outcome) -> String?)? = nil,
        operation:
            @escaping @MainActor (@escaping @MainActor (Progress) -> Void) async
            -> MonitorDeliveryCompletion<Outcome, Share>
    ) {
        beginAdmitted(onCancel: onCancel, onComplete: onComplete) { progress, _ in
            await operation(progress)
        }
    }

    public func beginAdmitted(
        onCancel: (() -> Void)? = nil,
        onComplete: ((Outcome) -> String?)? = nil,
        operation:
            @escaping @MainActor (@escaping @MainActor (Progress) -> Void, MonitorDeliveryAdmission)
            async
            -> MonitorDeliveryCompletion<Outcome, Share>
    ) {
        _ = beginCaptured(onCancel: onCancel, onComplete: onComplete, operation: operation)
    }

    /// Starts through the same task owner and returns only that task's cancellation/join handle.
    @discardableResult public func beginCaptured(
        onCancel: (() -> Void)? = nil,
        onComplete: ((Outcome) -> String?)? = nil,
        operation:
            @escaping @MainActor (@escaping @MainActor (Progress) -> Void, MonitorDeliveryAdmission)
            async
            -> MonitorDeliveryCompletion<Outcome, Share>
    ) -> MonitorDeliveryRunHandle? {
        beginCaptured(onCancel: onCancel, onComplete: onComplete,
            cleanupWhenRetired: false, operation: operation)
    }

    /// A resource-owning operation must reach cleanup even if it retires before task entry.
    /// It receives stale admission and must check it before entering source or native work.
    @discardableResult public func beginCaptured(
        onCancel: (() -> Void)? = nil,
        onComplete: ((Outcome) -> String?)? = nil,
        cleanupWhenRetired: Bool,
        operation:
            @escaping @MainActor (@escaping @MainActor (Progress) -> Void, MonitorDeliveryAdmission)
            async
            -> MonitorDeliveryCompletion<Outcome, Share>
    ) -> MonitorDeliveryRunHandle? {
        guard !closed else { return nil }
        let previous = work
        let token = UUID()
        run = token
        pendingShareAcknowledgement = nil
        cancelHandler = onCancel
        previous?.cancel()
        guard cleanupWhenRetired || current(token) else { return nil }
        let releaseCapturedShare = releaseShare
        let next = Task { [weak self] in
            guard cleanupWhenRetired || self?.current(token) == true else { return }
            let cancellation = MonitorDeliveryCancellation()
            let completion = await withTaskCancellationHandler {
                await operation(
                    { [weak self] progress in
                        guard let self, self.current(token), self.state.running else { return }
                        self.publish(token) { $0.progress = progress }
                    },
                    .init { [weak self] in
                        cancellation.active && self?.current(token) == true
                            && self?.state.running == true
                            && cancellation.active && self?.current(token) == true
                    })
            } onCancel: {
                cancellation.cancel()
            }
            if Task.isCancelled, self?.current(token) == true { self?.cancel() }
            guard let self, self.current(token), self.state.running else {
                if let share = completion.share { releaseCapturedShare(share) }
                return
            }
            self.finish(completion, token: token, onComplete: onComplete)
        }
        if current(token) {
            work = next
            publish(token) {
                $0.running = true
                $0.progress = nil
                $0.expanded = false
            }
        } else {
            next.cancel()
        }
        return MonitorDeliveryRunHandle(work: next) { [weak self] in
            guard let self, self.current(token), self.state.running else { return }
            self.cancel()
        }
    }

    /// Retires first: a reentrant cancellation callback may safely begin another run.
    public func cancel() {
        let previous = work
        let callback = cancelHandler
        let token = UUID()
        run = token
        pendingShareAcknowledgement = nil
        work = nil
        cancelHandler = nil
        previous?.cancel()
        callback?()
        publish(token) {
            $0.running = false
            $0.progress = nil
            $0.expanded = false
        }
    }

    public func setExpanded(_ expanded: Bool) { commit { $0.expanded = expanded } }
    public func enterLocalOverlayContext() { commit { $0.localOverlayDepth += 1 } }
    public func exitLocalOverlayContext() {
        commit { $0.localOverlayDepth = max(0, $0.localOverlayDepth - 1) }
    }

    /// A delayed dismissal belonging to an older sheet cannot erase its replacement.
    public func clearSharePresentation(id: UUID? = nil) {
        guard let previous = state.share, id == nil || id == previous.id else { return }
        pendingShareAcknowledgement =
            !closed
            ? shareRun.map { (id: previous.id, run: $0) } : nil
        shareRun = nil
        commit { $0.share = nil }
        releaseShare(previous.payload)
    }

    /// Accepts a matching presentation completion once, independent of dismissal ordering.
    /// A newer run retires acknowledgements, including shares retained from an older run.
    @discardableResult public func completeSharePresentation(id: UUID) -> Bool {
        clearSharePresentation(id: id)
        guard let acknowledgement = pendingShareAcknowledgement,
            acknowledgement.id == id, current(acknowledgement.run)
        else { return false }
        pendingShareAcknowledgement = nil
        return true
    }

    public func dismissToast() {
        toastID = UUID()
        let identity = toastID
        let previous = toastTask
        toastTask = nil
        previous?.cancel()
        guard toastID == identity else { return }
        commit { $0.toast = nil }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        cancel()
        dismissToast()
        clearSharePresentation()
    }

    private func current(_ token: UUID) -> Bool { !closed && run == token }

    private func commit(_ change: (inout MonitorDeliveryState<Progress, Share>) -> Void) {
        var next = committed
        change(&next)
        committed = next
        revision &+= 1
        // A synchronous observer can commit a successor before this setter returns. Defer its
        // notification until the outgoing one-shot tracking callback has finished unregistering.
        guard !notifying else { return }
        notifying = true
        defer { notifying = false }
        var delivered: UInt64
        repeat {
            delivered = revision
            publication = delivered
        } while delivered != revision
    }

    @discardableResult private func publish(
        _ token: UUID, _ change: (inout MonitorDeliveryState<Progress, Share>) -> Void
    ) -> Bool {
        guard run == token else { return false }
        commit(change)
        return current(token)
    }

    private func finish(
        _ completion: MonitorDeliveryCompletion<Outcome, Share>, token: UUID,
        onComplete: ((Outcome) -> String?)?
    ) {
        work = nil
        cancelHandler = nil
        pendingShareAcknowledgement = nil
        guard
            publish(
                token,
                {
                    $0.running = false
                    $0.progress = nil
                    $0.expanded = false
                })
        else {
            if let share = completion.share { releaseShare(share) }
            return
        }
        let overrideToast = onComplete?(completion.outcome)
        guard current(token) else {
            if let share = completion.share { releaseShare(share) }
            return
        }
        if let share = completion.share {
            let previous = state.share
            shareRun = token
            let admitted = publish(token) { $0.share = .init(id: UUID(), payload: share) }
            if let previous { releaseShare(previous.payload) }
            guard admitted, current(token) else { return }
        }
        if let message = overrideToast ?? completion.toast { showToast(message, token: token) }
    }

    private func showToast(_ message: String, token: UUID) {
        toastID = UUID()
        let identity = toastID
        let previous = toastTask
        toastTask = nil
        previous?.cancel()
        guard current(token), toastID == identity else { return }
        toastTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(.milliseconds(2500)) } catch { return }
            guard !Task.isCancelled, self.toastID == identity, !self.closed else { return }
            self.toastTask = nil
            self.commit { $0.toast = nil }
        }
        publish(token) { $0.toast = message }
    }
}
