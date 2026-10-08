import Foundation

/// Exercised wire/lifetime differences supplied to the common queue owner.
public struct RelayHostSessionPolicy: Sendable {
    public enum Introduction: Sendable { case onAccept, afterAuthorization }
    public let introduction: Introduction
    public let ignoresRepeatedAuthorizedHello: Bool
    public let requiresIdentityForControl: Bool
    public let presentsParkedHolder: Bool
    public let frameDepth: Int
    public let stateDepth: Int
    public let closeDeadlineSeconds: TimeInterval
    public let requiresVersionMatch: Bool
    public let sendsTokenOnHello: Bool
    public let verifiesAuthorizedHelloPasscode: Bool
    public let ignoresMalformedPayloads: Bool
    public let boundsIntroductionStateWrites: Bool
    public let versionMismatchReason: String
    public let passcodeReason: String
    public init(
        introduction: Introduction = .onAccept,
        ignoresRepeatedAuthorizedHello: Bool = false,
        requiresIdentityForControl: Bool = false, presentsParkedHolder: Bool = true,
        frameDepth: Int = 2, stateDepth: Int = 1, closeDeadlineSeconds: TimeInterval = 3,
        requiresVersionMatch: Bool = true,
        sendsTokenOnHello: Bool = true, verifiesAuthorizedHelloPasscode: Bool = true,
        ignoresMalformedPayloads: Bool = false, boundsIntroductionStateWrites: Bool = true,
        versionMismatchReason: String,
        passcodeReason: String = "This feed requires a passcode."
    ) {
        precondition(frameDepth > 0 && stateDepth > 0 && closeDeadlineSeconds >= 0)
        self.introduction = introduction
        self.ignoresRepeatedAuthorizedHello = ignoresRepeatedAuthorizedHello
        self.requiresIdentityForControl = requiresIdentityForControl
        self.presentsParkedHolder = presentsParkedHolder
        self.frameDepth = frameDepth
        self.stateDepth = stateDepth
        self.closeDeadlineSeconds = closeDeadlineSeconds
        self.requiresVersionMatch = requiresVersionMatch
        self.sendsTokenOnHello = sendsTokenOnHello
        self.verifiesAuthorizedHelloPasscode = verifiesAuthorizedHelloPasscode
        self.ignoresMalformedPayloads = ignoresMalformedPayloads
        self.boundsIntroductionStateWrites = boundsIntroductionStateWrites
        self.versionMismatchReason = versionMismatchReason
        self.passcodeReason = passcodeReason
    }
}

public enum RelayHostSessionEvent: Sendable {
    case connected(Int)
    case left(Int)
    case refused, holderParked, holderRestored, parkedExpired
    case closing(String)
}

/// Read-only admission crosses executors only through this owner's published generation.
public final class RelayHostCommandGate: @unchecked Sendable {
    public struct Publication: Hashable, Sendable {
        fileprivate let owner: UUID
        fileprivate let generation: UInt64
    }
    private let lock = NSLock()
    private let owner = UUID()
    private var generation: UInt64 = 0
    private var current: RelayHostControl.Admission?
    private var source: UUID?
    private var revision: UInt64?
    private var watcherID: String?
    public init() {}
    public var publication: Publication {
        lock.lock()
        defer { lock.unlock() }
        return .init(owner: owner, generation: generation)
    }
    public func isCurrent(_ publication: Publication) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return publication.owner == owner && publication.generation == generation
    }
    /// Retire immediately before handing the existing owner its queued stop/reclaim/source work.
    /// Old queued publications cannot reactivate the captured admission.
    @discardableResult public func retire() -> Publication {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        current = nil
        source = nil
        revision = nil
        watcherID = nil
        return .init(owner: owner, generation: generation)
    }
    @discardableResult public func publish(
        _ publication: Publication, source: UUID, revision: UInt64,
        admission: RelayHostControl.Admission?, watcherID: String?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard publication.owner == owner, publication.generation == generation else { return false }
        self.source = source
        self.revision = revision
        current = admission
        self.watcherID = watcherID
        return true
    }
    public func admits(source: UUID, revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.source == source && self.revision == revision
    }
    public func admits(_ admission: RelayHostControl.Admission) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current == admission
    }
    public func admits(watcherID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !watcherID.isEmpty && current != nil && self.watcherID == watcherID
    }
}

/// Actual peer facts. Native connection handles stay in the SDK adapter keyed by this identity.
public final class RelayHostSessionPeer: @unchecked Sendable {
    public let id = UUID()
    public var name = "Watcher"
    public var hello: RelayPeerHello?
    public var delivery = RelayPeerDelivery()
    fileprivate var reader: RelayStreamBuffer?
    fileprivate var frameWrites: Set<UUID> = []
    fileprivate var stateWrites: Set<UUID> = []
    public init() {}
}

/// A serial-executor host owns authorization, stream state, per-peer pressure, reconnect leases,
/// refusal/close deadlines and command admission. Socket and encoder SDKs are bounded ports.
/// Every public mutation is confined to the supplied executor; only commandGate is thread-safe.
public final class RelayHostSession<Codec: RelayWireCodec>: @unchecked Sendable {
    public typealias Completion = @Sendable () -> Void
    public var onSend: ((Data, UUID, @escaping Completion) -> Void)?
    public var onClose: ((UUID) -> Void)?
    public var onChange: (() -> Void)?
    public var onCommand: ((Codec.Command, RelayHostControl.Admission) -> Void)?
    public var onEvent: ((RelayHostSessionEvent) -> Void)?
    public var onKeyframeNeeded: (() -> Void)?
    public let commandGate = RelayHostCommandGate()
    private var commandPublication: RelayHostCommandGate.Publication?
    public private(set) var peers: [UUID: RelayHostSessionPeer] = [:]
    public private(set) var sentFrames = 0
    public private(set) var skippedFrames = 0
    public private(set) var keyframes = 0
    public var watcherCount: Int {
        lifetime.active ? peers.values.filter { $0.delivery.authorized }.count : 0
    }
    public var pendingName: String? { control.pendingName }
    public var pendingPeerID: UUID? { control.pending }
    public var pendingRequestRevision: UInt64? { control.pendingRequestRevision }
    public var pendingRequest: RelayHostControl.PendingRequest? { control.pendingRequest }
    public var peerCount: Int { lifetime.active ? peers.count : 0 }
    public var controlHolder: UUID? { control.holder }
    public var controlHolderName: String? { control.holderName }
    public var pendingWatcherID: String? { control.pendingWatcherID }
    public var holderWatcherID: String? { control.holderWatcherID }
    public var holderName: String {
        if !policy.presentsParkedHolder, control.holder == nil { return hostName }
        return control.holderName ?? hostName
    }
    public var source: UUID { control.source }
    public var controlRevision: UInt64 { control.revision }
    public var connectionSource: UUID { lifetime.token }
    public func admitsConnectionSource(_ source: UUID) -> Bool { lifetime.admits(source) }
    public func admission(watcherID: String?) -> RelayHostControl.Admission? {
        guard let watcherID, !watcherID.isEmpty else { return nil }
        return peers.values.first { $0.hello?.watcherID == watcherID }.flatMap {
            control.admission(for: $0.id)
        }
    }
    public var hasPeerReadyForFrame: Bool {
        peers.values.contains { $0.delivery.readyForFrame(depth: frameDepth) }
    }
    public var allAuthorizedPeersFull: Bool {
        let authorized = peers.values.filter { $0.delivery.authorized && !$0.delivery.closing }
        return !authorized.isEmpty
            && authorized.allSatisfy { !$0.delivery.readyForFrame(depth: frameDepth) }
    }
    public var needsKeyframe: Bool {
        peers.values.contains {
            $0.delivery.needsKeyframe && $0.delivery.readyForFrame(depth: frameDepth)
        }
    }
    public var hasJPEGOnlyPeers: Bool {
        peers.values.contains {
            $0.delivery.authorized && !$0.delivery.closing && !$0.delivery.acceptsHEVC
        }
    }
    private let codec: Codec
    private let policy: RelayHostSessionPolicy
    private let execute: (@escaping Completion) -> Void
    private let schedule: (TimeInterval, @escaping Completion) -> Void
    private let now: () -> Date
    private var control = RelayHostControl()
    private var lifetime = RelayConnectionLifetime()
    private var hostName = "Host"
    private var cameraName: String?
    private var passcode = ""
    private var allowsControl = true
    private var latestState: Codec.State?
    private var frameDepth: Int
    public init(
        codec: Codec, policy: RelayHostSessionPolicy,
        startsActive: Bool = false,
        now: @escaping () -> Date = { Date() },
        execute: @escaping (@escaping Completion) -> Void,
        schedule: @escaping (TimeInterval, @escaping Completion) -> Void
    ) {
        self.codec = codec
        self.policy = policy
        self.now = now
        self.execute = execute
        self.schedule = schedule
        frameDepth = policy.frameDepth
        commandPublication = commandGate.publication
        if startsActive { lifetime.begin() }
    }
    public func begin(hostName: String, cameraName: String?, passcode: String, allowsControl: Bool)
    {
        let retired = stopOwner(reason: nil)
        guard lifetime.token == retired, !lifetime.active else { return }
        self.hostName = hostName
        self.cameraName = cameraName
        self.passcode = passcode
        self.allowsControl = allowsControl
        lifetime.begin()
        commandPublication = commandGate.publication
    }
    public func configure(passcode: String, allowsControl: Bool) {
        self.passcode = passcode
        self.allowsControl = allowsControl
    }
    public func updateCameraName(_ name: String?) { cameraName = name }
    public func adoptFrameDepth(_ depth: Int) {
        precondition(depth > 0)
        frameDepth = depth
    }
    public func install(_ peer: RelayHostSessionPeer) {
        guard lifetime.active else {
            onClose?(peer.id)
            return
        }
        peers[peer.id] = peer
        peer.reader = RelayStreamBuffer(profile: codec.profile)
        control.register(peer.id, name: peer.name, authorized: peer.delivery.authorized)
        if policy.introduction == .onAccept {
            sendHello(to: peer)
            if peer.delivery.authorized, let latestState {
                sendIntroductionState(latestState, to: peer)
            }
        }
        onEvent?(.connected(peers.count))
        onChange?()
    }
    public func receive(_ bytes: Data, from peer: RelayHostSessionPeer) throws {
        guard current(peer), !peer.delivery.closing else { return }
        for message in try peer.reader?.append(bytes) ?? [] {
            guard current(peer), !peer.delivery.closing else { return }
            do { try handle(message, from: peer) } catch {
                if !policy.ignoresMalformedPayloads { throw error }
            }
        }
    }
    public func handle(_ message: RelayStreamFraming.Decoded, from peer: RelayHostSessionPeer)
        throws
    {
        guard current(peer), !peer.delivery.closing else { return }
        switch message.kind {
        case 1:
            guard !policy.ignoresRepeatedAuthorizedHello || !peer.delivery.authorized else {
                return
            }
            let hello = try codec.decodeHello(message.payload)
            if let refusal = RelayJoinPolicy.refusal(
                hello: hello, profile: codec.profile,
                requiredPasscode: !policy.verifiesAuthorizedHelloPasscode
                    && peer.delivery.authorized ? "" : passcode,
                versionMismatchReason: policy.versionMismatchReason,
                passcodeReason: policy.passcodeReason,
                requiresVersionMatch: policy.requiresVersionMatch)
            {
                peer.delivery.authorized = false
                _ = control.introduce(peer.id, hello: hello, authorized: false, now: now())
                publishAuthority()
                close(peer, reason: refusal.reason, passcodeRequired: refusal.passcodeRequired)
                onEvent?(.refused)
                return
            }
            let newlyAuthorized = !peer.delivery.authorized
            peer.name = hello.hostName
            peer.hello = hello
            peer.delivery.authorized = true
            peer.delivery.acceptsHEVC = hello.acceptsHEVC
            let restored = control.introduce(peer.id, hello: hello, authorized: true, now: now())
            if policy.introduction == .afterAuthorization { sendHello(to: peer) }
            if let latestState, policy.introduction == .afterAuthorization || newlyAuthorized {
                sendIntroductionState(latestState, to: peer)
            }
            if policy.sendsTokenOnHello { sendToken(to: peer) }
            peer.delivery.needsKeyframe = true
            publishAuthority()
            if restored {
                onEvent?(.holderRestored)
                if !policy.sendsTokenOnHello { broadcastTokens() }
            }
            onChange?()
        case 0x10:
            if control.request(peer.id, allowsControl: allowsControl) { onChange?() }
        case 0x11:
            if control.admission(for: peer.id) != nil { reclaimControl() }
        case 0x12:
            guard let admission = control.admission(for: peer.id) else { return }
            let command = try codec.decodeCommand(message.payload)
            guard commandGate.admits(admission) else { return }
            onCommand?(command, admission)
        default: break
        }
    }
    public func grantControl() {
        guard control.pending != nil else { return }
        if policy.requiresIdentityForControl,
            control.pendingWatcherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ?? true
        {
            control.reclaim()
        } else {
            _ = control.grantPending()
        }
        publishAuthority()
        broadcastTokens()
        onChange?()
    }
    public func denyControl() {
        control.declinePending()
        onChange?()
    }
    public func reclaimControl(publication: RelayHostCommandGate.Publication) {
        guard commandGate.isCurrent(publication) else { return }
        commandPublication = publication
        reclaimControl()
    }
    public func reclaimControl() {
        control.reclaim()
        publishAuthority()
        broadcastTokens()
        onChange?()
    }
    public func retireSource(publication: RelayHostCommandGate.Publication) {
        guard commandGate.isCurrent(publication) else { return }
        commandPublication = publication
        retireSource()
    }
    public func retireSource() {
        control.resetSource()
        latestState = nil
        for peer in peers.values {
            peer.delivery.needsKeyframe = true
            control.register(peer.id, name: peer.name, authorized: peer.delivery.authorized)
            if let hello = peer.hello {
                _ = control.introduce(
                    peer.id, hello: hello, authorized: peer.delivery.authorized, now: now())
            }
        }
        publishAuthority()
        broadcastTokens()
        onChange?()
    }
    public func broadcast(state: Codec.State) {
        latestState = state
        for peer in peers.values where current(peer) { sendState(state, to: peer) }
    }
    public func acceptLatest(state: Codec.State) { latestState = state }
    public func broadcast(
        metadata: Codec.FrameMetadata, image: Data, admittedSource: UUID? = nil,
        jpegOnly: Bool = false
    ) {
        guard lifetime.active, admittedSource == nil || admittedSource == source,
            let payload = try? codec.encodeFrame(metadata: metadata, image: image)
        else { return }
        let video = codec.videoDescription(of: metadata)
        let wire = RelayStreamFraming.encode(kind: 3, payload: payload)
        if video.isKeyframe { keyframes += 1 }
        let window = lifetime.token
        var keyframeWanted = false
        for peer in peers.values where current(peer) {
            switch peer.delivery.admitFrame(
                isHEVC: video.codec == codec.profile.hevcCodec,
                isKeyframe: video.isKeyframe, depth: frameDepth, jpegOnly: jpegOnly)
            {
            case .send:
                sentFrames += 1
                let write = UUID()
                peer.frameWrites.insert(write)
                onSend?(wire, peer.id) { [weak self, weak peer] in
                    self?.execute { [weak self, weak peer] in
                        guard let self, let peer, self.lifetime.admits(window), self.current(peer),
                            peer.frameWrites.remove(write) != nil
                        else { return }
                        peer.delivery.completeFrame()
                    }
                }
            case .saturated:
                skippedFrames += 1
                if video.codec == codec.profile.hevcCodec { keyframeWanted = true }
            case .needsKeyframe:
                if video.codec == codec.profile.hevcCodec { keyframeWanted = true }
            default: break
            }
        }
        if keyframeWanted { onKeyframeNeeded?() }
    }
    public func clearMetrics() {
        sentFrames = 0
        skippedFrames = 0
        keyframes = 0
    }
    public func drop(_ peer: RelayHostSessionPeer) {
        guard peers.removeValue(forKey: peer.id) === peer else { return }
        if let expected = control.drop(peer.id, now: now()) {
            onEvent?(.holderParked)
            let source = control.source
            schedule(RelayParkedControlLease.defaultWindowSeconds) { [weak self] in
                guard let self, self.control.source == source,
                    self.control.expire(expected: expected, now: self.now())
                else { return }
                self.publishAuthority()
                self.onEvent?(.parkedExpired)
                self.broadcastTokens()
                self.onChange?()
            }
        }
        publishAuthority()
        onClose?(peer.id)
        onEvent?(.left(peers.count))
        broadcastTokens()
        onChange?()
    }
    public func stop(reason: String? = nil) {
        _ = stopOwner(reason: reason)
    }
    private func stopOwner(reason: String?) -> UUID {
        lifetime.retire()
        let retired = lifetime.token
        control.resetSource()
        latestState = nil
        publishAuthority()
        for peer in Array(peers.values) {
            if let reason {
                close(peer, reason: reason, passcodeRequired: false)
            } else {
                peers.removeValue(forKey: peer.id)
                onClose?(peer.id)
            }
        }
        onChange?()
        return retired
    }
    private func publishAuthority() {
        guard let commandPublication else { return }
        commandGate.publish(
            commandPublication, source: control.source, revision: control.revision,
            admission: lifetime.active
                ? control.holder.flatMap { control.admission(for: $0) } : nil,
            watcherID: lifetime.active ? control.holderWatcherID : nil
        )
    }
    private func current(_ peer: RelayHostSessionPeer) -> Bool {
        lifetime.active && peers[peer.id] === peer
    }
    private func sendHello(to peer: RelayHostSessionPeer) {
        if let payload = try? codec.encodeHello(
            .init(version: codec.profile.version, hostName: hostName, cameraName: cameraName))
        {
            onSend?(RelayStreamFraming.encode(kind: 1, payload: payload), peer.id, {})
        }
    }
    private func sendToken(to peer: RelayHostSessionPeer) {
        guard peer.delivery.authorized, !peer.delivery.closing else { return }
        let token = codec.controlToken(
            holderName: holderName, holderIsRecipient: control.holder == peer.id)
        if let payload = try? JSONEncoder().encode(token) {
            onSend?(RelayStreamFraming.encode(kind: 4, payload: payload), peer.id, {})
        }
    }
    private func broadcastTokens() { for peer in peers.values { sendToken(to: peer) } }
    private func sendState(_ state: Codec.State, to peer: RelayHostSessionPeer) {
        guard peer.delivery.admitState(maximumInFlight: policy.stateDepth) else { return }
        guard let payload = try? codec.encodeState(state) else {
            peer.delivery.completeState()
            return
        }
        let window = lifetime.token
        let write = UUID()
        peer.stateWrites.insert(write)
        onSend?(RelayStreamFraming.encode(kind: 2, payload: payload), peer.id) {
            [weak self, weak peer] in
            self?.execute { [weak self, weak peer] in
                guard let self, let peer, self.lifetime.admits(window), self.current(peer),
                    peer.stateWrites.remove(write) != nil
                else { return }
                peer.delivery.completeState()
            }
        }
    }
    private func sendIntroductionState(_ state: Codec.State, to peer: RelayHostSessionPeer) {
        if policy.boundsIntroductionStateWrites {
            sendState(state, to: peer)
        } else if peer.delivery.authorized, !peer.delivery.closing,
            let payload = try? codec.encodeState(state)
        {
            onSend?(RelayStreamFraming.encode(kind: 2, payload: payload), peer.id, {})
        }
    }
    private func close(_ peer: RelayHostSessionPeer, reason: String, passcodeRequired: Bool) {
        guard !peer.delivery.closing else { return }
        peer.delivery.closing = true
        onEvent?(.closing(reason))
        let finish: Completion = { [weak self, weak peer] in
            self?.execute { [weak self, weak peer] in
                guard let self, let peer, self.peers[peer.id] === peer else { return }
                self.drop(peer)
            }
        }
        if let payload = try? JSONEncoder().encode(
            codec.joinDenied(reason: reason, passcodeRequired: passcodeRequired))
        {
            onSend?(RelayStreamFraming.encode(kind: 5, payload: payload), peer.id, finish)
            schedule(policy.closeDeadlineSeconds, finish)
        } else {
            drop(peer)
        }
    }
}
