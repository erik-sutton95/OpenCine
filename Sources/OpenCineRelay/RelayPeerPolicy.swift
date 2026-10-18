import Foundation

/// Captured source admission from its actual native owner, not a guessed observation. Native
/// producers vary here; relay scheduling consumes this one predicate around every suspension.
@MainActor public final class RelayFrameAdmission {
    public let isCurrent: @MainActor @Sendable () -> Bool
    public init(isCurrent: @escaping @MainActor @Sendable () -> Bool) { self.isCurrent = isCurrent }
}

/// Same-meaning join policy for typed deployed codecs. Version and passcode refusal happen
/// before a recognized install can reclaim control or receive protected state/picture bytes.
public enum RelayJoinPolicy {
    public struct Refusal: Equatable, Sendable {
        public let reason: String
        public let passcodeRequired: Bool
        public init(reason: String, passcodeRequired: Bool) {
            self.reason = reason
            self.passcodeRequired = passcodeRequired
        }
    }
    public static func refusal(
        hello: RelayPeerHello, profile: RelayWireProfile,
        requiredPasscode: String, versionMismatchReason: String,
        passcodeReason: String = "This broadcast asks for a passcode.",
        requiresVersionMatch: Bool = true
    ) -> Refusal? {
        if requiresVersionMatch && hello.version != profile.version {
            return Refusal(reason: versionMismatchReason, passcodeRequired: false)
        }
        let required = normalizedPasscode(requiredPasscode)
        if !required.isEmpty && hello.passcode.map(normalizedPasscode) != required {
            return Refusal(reason: passcodeReason, passcodeRequired: true)
        }
        return nil
    }

    /// Both sides of a join compare passcodes without surrounding whitespace: the same trim as the
    /// watcher passcode rule (MonitorPresentation `MonitorWatcherPasscodeRule.normalized`).
    public static func normalizedPasscode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One peer's delivered reference chain and bounded socket writes. Control traffic has its
/// own lane and cannot borrow or consume video capacity. The SDK adapter confines this value.
public struct RelayPeerDelivery: Equatable, Sendable {
    public enum FrameDecision: Equatable, Sendable {
        case send, unavailable, wrongCodec, saturated, needsKeyframe
    }
    public var authorized: Bool
    public var closing = false
    public var acceptsHEVC = true
    public var needsKeyframe = true
    public var inFlightFrames = 0
    public private(set) var inFlightStates = 0
    public init(authorized: Bool = false) { self.authorized = authorized }

    public mutating func admitFrame(
        isHEVC: Bool, isKeyframe: Bool, depth: Int,
        jpegOnly: Bool = false
    ) -> FrameDecision {
        guard authorized && !closing else { return .unavailable }
        guard !(isHEVC && !acceptsHEVC), !(jpegOnly && acceptsHEVC) else { return .wrongCodec }
        guard inFlightFrames < depth else {
            needsKeyframe = true
            return .saturated
        }
        guard !needsKeyframe || isKeyframe else { return .needsKeyframe }
        needsKeyframe = false
        inFlightFrames += 1
        return .send
    }
    public mutating func completeFrame() { inFlightFrames = max(0, inFlightFrames - 1) }
    public func readyForFrame(depth: Int) -> Bool {
        authorized && !closing && inFlightFrames < depth
    }
    public mutating func admitState(maximumInFlight: Int = 1) -> Bool {
        guard authorized && !closing && inFlightStates < maximumInFlight else { return false }
        inFlightStates += 1
        return true
    }
    public mutating func completeState() { inFlightStates = max(0, inFlightStates - 1) }
}

/// A real start/stop or producer replacement changes the token, including ABA reentry. Tokens
/// are never synthesized from a camera name, address or a frame's metadata.
public struct RelayConnectionLifetime: Sendable {
    public private(set) var token = UUID()
    public private(set) var active = false
    public init() {}
    @discardableResult public mutating func begin() -> UUID {
        token = UUID()
        active = true
        return token
    }
    public mutating func retire() {
        token = UUID()
        active = false
    }
    public func admits(_ token: UUID) -> Bool { active && self.token == token }
}

/// Host control and its reconnect window. Source/peer/lease identity is captured before a
/// callback leaves the owner and rechecked at dispatch, so late work cannot command a successor.
public struct RelayHostControl: Sendable {
    public struct Admission: Hashable, Sendable {
        public let source: UUID
        public let peer: UUID
        public let revision: UInt64
    }
    /// A displayed request identifies this exact occurrence, including a repeat from one peer.
    public struct PendingRequest: Hashable, Sendable {
        public let source: UUID
        public let peer: UUID
        public let requestRevision: UInt64
    }
    private struct Peer: Sendable {
        var name: String
        var watcherID: String?
        var authorized: Bool
    }
    public private(set) var source = UUID()
    public private(set) var revision: UInt64 = 0
    public private(set) var requestRevision: UInt64 = 0
    public private(set) var holder: UUID?
    public private(set) var holderName: String?
    public private(set) var pending: UUID?
    public var pendingName: String? { pending.flatMap { peers[$0]?.name } }
    public var pendingRequestRevision: UInt64? { pending == nil ? nil : requestRevision }
    public var pendingRequest: PendingRequest? {
        pending.map { PendingRequest(source: source, peer: $0, requestRevision: requestRevision) }
    }
    public func admits(_ request: PendingRequest) -> Bool {
        pendingRequest == request && peers[request.peer]?.authorized == true
    }
    public var holderWatcherID: String? { holder.flatMap { peers[$0]?.watcherID } }
    public var pendingWatcherID: String? { pending.flatMap { peers[$0]?.watcherID } }
    private var peers: [UUID: Peer] = [:]
    private var lease: RelayParkedControlLease
    public init(windowSeconds: TimeInterval = RelayParkedControlLease.defaultWindowSeconds) {
        lease = RelayParkedControlLease(windowSeconds: windowSeconds)
    }
    public mutating func resetSource() {
        source = UUID()
        revision &+= 1
        peers.removeAll()
        holder = nil
        holderName = nil
        pending = nil
        lease.clear()
    }
    public mutating func register(_ id: UUID, name: String, authorized: Bool) {
        peers[id] = Peer(name: name, watcherID: nil, authorized: authorized)
    }
    @discardableResult public mutating func introduce(
        _ id: UUID, hello: RelayPeerHello,
        authorized: Bool, now: Date
    ) -> Bool {
        guard peers[id] != nil else { return false }
        peers[id] = Peer(name: hello.hostName, watcherID: hello.watcherID, authorized: authorized)
        guard authorized else {
            if pending == id { pending = nil }
            if holder == id { reclaim() }
            return false
        }
        if holder == id { holderName = hello.hostName }
        if holder == nil && lease.claim(watcherID: hello.watcherID, now: now) {
            holder = id
            holderName = hello.hostName
            revision &+= 1
            return true
        }
        return false
    }
    @discardableResult public mutating func request(_ id: UUID, allowsControl: Bool) -> Bool {
        guard allowsControl, peers[id]?.authorized == true else { return false }
        requestRevision &+= 1
        pending = id
        return true
    }
    @discardableResult public mutating func grantPending() -> Bool {
        guard let pending, let peer = peers[pending], peer.authorized else { return false }
        holder = pending
        holderName = peer.name
        self.pending = nil
        lease.clear()
        revision &+= 1
        return true
    }
    @discardableResult public mutating func grantPending(_ request: PendingRequest) -> Bool {
        guard admits(request) else { return false }
        return grantPending()
    }
    public mutating func declinePending() { pending = nil }
    @discardableResult public mutating func declinePending(_ request: PendingRequest) -> Bool {
        guard admits(request) else { return false }
        declinePending()
        return true
    }
    public mutating func reclaim() {
        holder = nil
        holderName = nil
        pending = nil
        lease.clear()
        revision &+= 1
    }
    /// Returns a revision for the scheduled expiry, or nil when there is no parked claim.
    public mutating func drop(_ id: UUID, now: Date) -> UInt64? {
        guard let departing = peers.removeValue(forKey: id) else { return nil }
        if pending == id { pending = nil }
        guard holder == id else { return nil }
        holder = nil
        revision &+= 1
        if departing.authorized && lease.park(watcherID: departing.watcherID, now: now) {
            return revision
        }
        holderName = nil
        return nil
    }
    @discardableResult public mutating func expire(expected: UInt64, now: Date) -> Bool {
        guard expected == revision, holder == nil, holderName != nil, !lease.isParked(at: now)
        else { return false }
        reclaim()
        return true
    }
    public func admission(for id: UUID) -> Admission? {
        guard peers[id]?.authorized == true, holder == id else { return nil }
        return Admission(source: source, peer: id, revision: revision)
    }
    public func admits(_ value: Admission) -> Bool {
        source == value.source && revision == value.revision && admission(for: value.peer) == value
    }
}
