import Foundation
import OpenCineDJI

/// Captured actual control ownership; nil retains local facts without inventing readiness.
public struct DjiAppleTrackingBinding: Equatable, Sendable {
    public var endpoint: ObjectIdentifier?
    public var controlGeneration: Int

    public init(endpoint: ObjectIdentifier? = nil, controlGeneration: Int = 0) {
        self.endpoint = endpoint
        self.controlGeneration = controlGeneration
    }
}

@MainActor public struct DjiAppleTrackingTiming {
    public var now: () -> Date
    public var wait: @MainActor (Duration) async throws -> Void

    public init(
        now: @escaping () -> Date,
        wait: @escaping @MainActor (Duration) async throws -> Void
    ) {
        self.now = now
        self.wait = wait
    }

    public static var continuous: Self {
        .init(now: { Date() }, wait: { try await Task.sleep(for: $0) })
    }
}

/// One session's actual ActiveTrack request, camera reports and polling lifetime.
/// Face detection, focus presentation and control admission stay with the native host.
@MainActor public final class DjiAppleSubjectTracking {
    public struct Snapshot: Equatable, Sendable {
        public var searchBox: TrackingBox?
        public var subjectBox: TrackingBox?
        public var tracking: Bool
        public var active: Bool { tracking || searchBox != nil || subjectBox != nil }

        public init(
            searchBox: TrackingBox? = nil, subjectBox: TrackingBox? = nil,
            tracking: Bool = false
        ) {
            self.searchBox = searchBox
            self.subjectBox = subjectBox
            self.tracking = tracking
        }
    }

    public struct Authority {
        fileprivate var generation: UInt64
        fileprivate var binding: DjiAppleTrackingBinding
        fileprivate var revision: UInt64
    }

    public enum Event {
        case changed(previous: Snapshot, next: Snapshot, revision: UInt64)
        case preparing(Authority)
        case tooSmall(Authority)
        case focus(x: Double, y: Double)
    }

    public private(set) var snapshot = Snapshot()
    public private(set) var revision: UInt64 = 0
    public var polling: Bool { pollTask != nil && pollingBinding == binding() }
    private let binding: () -> DjiAppleTrackingBinding
    private let send: (Duml.Frame, String, Bool, @escaping @MainActor (Bool) -> Void) -> Void
    private let sendAdmitted:
        (
            (Duml.Frame, String, Bool, DJICommandAdmission, @escaping @MainActor (Bool) -> Void) ->
                Void
        )?
    private let event: (Event) -> Void
    private let timing: DjiAppleTrackingTiming
    private var nextID: UInt16 = 1
    private var pollTask: Task<Void, Never>?
    private var pollingBinding: DjiAppleTrackingBinding?
    private var generation: UInt64 = 0
    private var sawLock = false
    private var operatorClearedAt: Date?
    private var lastPushAt: Date?
    private var lastLiveAt: Date?
    private var request: (box: TrackingBox, at: Date)?

    public init(
        binding: @escaping () -> DjiAppleTrackingBinding,
        send: @escaping (Duml.Frame, String, Bool, @escaping @MainActor (Bool) -> Void) -> Void,
        timing: DjiAppleTrackingTiming = .continuous,
        event: @escaping (Event) -> Void = { _ in },
        sendAdmitted:
            (
                (Duml.Frame, String, Bool, DJICommandAdmission, @escaping @MainActor (Bool) -> Void)
                    -> Void
            )? = nil
    ) {
        self.binding = binding
        self.send = send
        self.timing = timing
        self.event = event
        self.sendAdmitted = sendAdmitted
    }

    public func start(_ box: TrackingBox) {
        guard !box.isTooSmall else {
            let token = generation
            let source = binding()
            let publication = commit(.init())
            let authority = Authority(
                generation: token, binding: source, revision: publication)
            guard admits(authority) else { return }
            event(.tooSmall(authority))
            return
        }
        stopPolling()
        let token = generation
        let source = binding()
        operatorClearedAt = nil
        lastLiveAt = nil
        lastPushAt = nil
        request = (box, timing.now())
        sawLock = false
        let publication = commit(.init(searchBox: box))
        let authority = Authority(generation: token, binding: source, revision: publication)
        guard admits(authority) else { return }
        event(.preparing(authority))
        guard admits(authority) else { return }
        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        guard source.endpoint != nil else { return }
        send(
            Commands.setTrackingBox(
                id: id, x: Float(box.centerX), y: Float(box.centerY),
                width: Float(box.width), height: Float(box.height)), "Track", true
        ) { [weak self] ok in
            guard let self, ok, self.current(token, source: source) else { return }
            self.beginPolling()
        }
    }

    /// Preserve the donor's local-first overlay clear and short leftover-push hold.
    public func cancel(sendClear: Bool) {
        cancel(sendClear: sendClear, suppliedAdmission: nil)
    }

    public func cancel(sendClear: Bool, admission: DJICommandAdmission) {
        guard admission.isCurrent else { return }
        cancel(sendClear: sendClear, suppliedAdmission: admission)
    }

    private func cancel(sendClear: Bool, suppliedAdmission admission: DJICommandAdmission?) {
        stopPolling()
        let token = generation
        let source = binding()
        let had = snapshot.active
        sawLock = false
        if sendClear { operatorClearedAt = timing.now() }
        lastLiveAt = nil
        lastPushAt = nil
        request = nil
        let publication = commit(.init())
        let authority = Authority(generation: token, binding: source, revision: publication)
        guard admits(authority), sendClear, had, source.endpoint != nil else { return }
        if let admission {
            guard admission.isCurrent, let sendAdmitted else { return }
            sendAdmitted(Commands.clearTrackingBox(), "Track clear", true, admission) { _ in }
        } else {
            send(Commands.clearTrackingBox(), "Track clear", true) { _ in }
        }
    }

    /// Disconnect resets presentation/history, without resetting the donor request ID.
    public func reset() {
        stopPolling()
        sawLock = false
        operatorClearedAt = nil
        lastLiveAt = nil
        lastPushAt = nil
        commit(.init())
    }

    /// Native recovery/borrow retirement never sends CLEAR or another camera command.
    public func stopPolling() {
        generation &+= 1
        let previous = pollTask
        pollTask = nil
        pollingBinding = nil
        previous?.cancel()
    }

    public func rejectSmallBox() { commit(.init()) }

    public func receiveLivePush(_ payload: [UInt8]) {
        guard
            TrackingClearPolicy.shouldApplyLivePush(
                operatorClearedAt: operatorClearedAt,
                now: timing.now()), let box = TrackingBox.parseLivePush(payload), accepts(box)
        else { return }
        let token = generation
        let source = binding()
        lastPushAt = timing.now()
        let subject = smoothed(toward: box)
        sawLock = true
        let publication = commit(.init(subjectBox: subject, tracking: true))
        let authority = Authority(generation: token, binding: source, revision: publication)
        guard admits(authority) else { return }
        event(.focus(x: box.centerX, y: box.centerY))
        guard admits(authority) else { return }
        if !polling { beginPolling() }
    }

    public func receivePoll(_ payload: [UInt8]) {
        guard
            TrackingClearPolicy.shouldApplyLivePush(
                operatorClearedAt: operatorClearedAt,
                now: timing.now())
        else { return }
        switch TrackingPoll.parse(payload) {
        case .locked(let cameraBox):
            if let cameraBox, !accepts(cameraBox) { return }
            sawLock = true
            let subject: TrackingBox?
            if let cameraBox {
                subject = smoothed(toward: cameraBox)
            } else if snapshot.subjectBox == nil, let search = snapshot.searchBox {
                subject = TrackingBox.subject(from: search)
            } else {
                subject = snapshot.subjectBox
            }
            commit(.init(subjectBox: subject, tracking: true))
        case .idle:
            if sawLock {
                clearLocal()
            } else {
                var next = snapshot
                next.tracking = false
                commit(next)
            }
        case nil: break
        }
    }

    /// Revalidate the captured publication before each synchronous native-host mutation.
    public func admits(_ authority: Authority) -> Bool {
        current(authority.generation, source: authority.binding) && revision == authority.revision
    }

    private func current(_ token: UInt64, source: DjiAppleTrackingBinding) -> Bool {
        generation == token && !Task.isCancelled && binding() == source && generation == token
    }

    @discardableResult
    private func commit(_ next: Snapshot) -> UInt64 {
        guard next != snapshot else { return revision }
        let previous = snapshot
        snapshot = next
        revision &+= 1
        let publication = revision
        event(.changed(previous: previous, next: next, revision: publication))
        return publication
    }

    private func accepts(_ box: TrackingBox) -> Bool {
        guard let request else { return true }
        guard
            TrackingStartPolicy.accepts(
                box, requested: request.box,
                secondsSinceRequest: timing.now().timeIntervalSince(request.at))
        else { return false }
        self.request = nil
        return true
    }

    private func smoothed(toward box: TrackingBox) -> TrackingBox {
        let now = timing.now()
        let dt = lastLiveAt.map { now.timeIntervalSince($0) } ?? .infinity
        lastLiveAt = now
        return TrackingBoxSmoothing.blend(from: snapshot.subjectBox, toward: box, dt: dt)
    }

    private func clearLocal() {
        lastLiveAt = nil
        lastPushAt = nil
        stopPolling()
        commit(.init())
    }

    private func beginPolling() {
        stopPolling()
        let token = generation
        let source = binding()
        pollingBinding = source
        pollTask = Task { @MainActor [weak self] in
            var idleTicks = 0
            while !Task.isCancelled {
                guard self?.beforeWait(token, source: source) == true,
                    let wait = self?.timing.wait
                else { break }
                try? await wait(.milliseconds(500))
                guard let next = self?.afterWait(token, source: source, idleTicks: idleTicks)
                else { break }
                idleTicks = next
            }
            guard let self, self.generation == token else { return }
            self.pollTask = nil
            self.pollingBinding = nil
        }
    }

    private func beforeWait(_ token: UInt64, source: DjiAppleTrackingBinding) -> Bool {
        guard current(token, source: source), snapshot.active else { return false }
        send(Commands.pollTracking(), "Track poll", false) { _ in }
        return current(token, source: source)
    }

    private func afterWait(
        _ token: UInt64, source: DjiAppleTrackingBinding,
        idleTicks: Int
    ) -> Int? {
        guard current(token, source: source) else { return nil }
        if sawLock,
            TrackingClearPolicy.shouldDropForSilence(lastPush: lastPushAt, now: timing.now())
        {
            clearLocal()
            return nil
        }
        if snapshot.tracking { return 0 }
        if sawLock || idleTicks + 1 >= 6 {
            clearLocal()
            return nil
        }
        return idleTicks + 1
    }
}
