#if canImport(Network)
    import Foundation
    import Network
    import OpenCineRelay

    /// MainActor SDK handles over the same Foundation peer/authority owner as the queue facade.
    @MainActor public final class RelayAppleHost<Codec: RelayWireCodec> {
        public typealias SendWire =
            @MainActor (Data, NWConnection, @escaping @Sendable () -> Void) -> Void
        public private(set) var peerCount = 0
        public private(set) var isBroadcasting = false
        public private(set) var boundPort: UInt16?
        public var onPeerCountChanged: (@MainActor (Int) -> Void)?
        public var onFailure: (@MainActor (String) -> Void)?
        public var onListening: (@MainActor (UInt16?) -> Void)?
        public var onControlChanged: (@MainActor () -> Void)?
        public var onCommand: (@MainActor (Codec.Command) -> Void)?
        public var onAdmittedCommand:
            (@MainActor (Codec.Command, RelayHostControl.Admission) -> Void)?
        public var onKeyframeNeeded: (@MainActor () -> Void)?
        public var watcherPasscode = "" { didSet { configureAdmission() } }
        public var allowsControlRequests = true { didSet { configureAdmission() } }
        public var controlHolder: UUID? { binding?.owner.controlHolder }
        public var controlHolderName: String? { binding?.owner.controlHolderName }
        public var pendingRequestName: String? { binding?.owner.pendingName }
        public var pendingRequestID: UUID? { binding?.owner.pendingPeerID }
        public var pendingRequestRevision: UInt64? { binding?.owner.pendingRequestRevision }
        public var pendingRequest: RelayHostControl.PendingRequest? { binding?.owner.pendingRequest }
        public var sourceToken: UUID { binding?.owner.source ?? retiredSource }
        public var controlRevision: UInt64 { binding?.owner.controlRevision ?? 0 }
        private let codec: Codec
        private let network: RelayNetworkPolicy
        private let versionMismatchReason: String
        private let requiresVersionMatch: Bool
        private let journal: @Sendable (String) -> Void
        private let now: @MainActor () -> Date
        private let sleep: @MainActor (TimeInterval) async -> Void
        private let sendWire: SendWire
        private var depth: Int
        private var binding: Binding?
        private var retiring: [UUID: Binding] = [:]
        private var retiredSource = UUID()
        private var hostName = ""
        private var cameraName: String?
        private var servedCameraHost: String?
        private let queue = DispatchQueue(label: "opc.relay.host", qos: .userInitiated)

        @MainActor private final class Binding {
            let id = UUID()
            let owner: RelayHostSession<Codec>
            var listener: NWListener?
            var peers: [UUID: Peer] = [:]
            init(owner: RelayHostSession<Codec>) { self.owner = owner }
        }
        @MainActor private final class Peer {
            let connection: NWConnection
            let common = RelayHostSessionPeer()
            init(connection: NWConnection, authorized: Bool) {
                self.connection = connection
                common.name = "A device"
                common.delivery.authorized = authorized
            }
        }
        public init(
            codec: Codec, profile: RelayEncoderProfile = .lowLatency,
            network: RelayNetworkPolicy = .init(), versionMismatchReason: String,
            requiresVersionMatch: Bool = true,
            journal: @escaping @Sendable (String) -> Void = { _ in },
            now: @escaping @MainActor () -> Date = { Date() },
            sleep: (@MainActor (TimeInterval) async -> Void)? = nil,
            sendWire: @escaping SendWire = { data, connection, completion in
                connection.send(content: data, completion: .contentProcessed { _ in completion() })
            }
        ) {
            self.codec = codec
            depth = profile.maxInFlightFramesPerPeer
            self.network = network
            self.versionMismatchReason = versionMismatchReason
            self.requiresVersionMatch = requiresVersionMatch
            self.journal = journal
            self.now = now
            // Resolved here, not as a closure-literal default (swiftlang/swift#92017).
            self.sleep = sleep ?? { seconds in try? await Task.sleep(for: .seconds(seconds)) }
            self.sendWire = sendWire
        }
        public func start(
            hostName: String, cameraName: String?, servedCameraHost: String? = nil,
            includePeerToPeer: Bool, preferredPort: UInt16? = nil
        ) {
            let retired = stopOwner(notifyingViewers: nil)
            guard binding == nil, retiredSource == retired else { return }
            self.hostName = hostName
            self.cameraName = cameraName
            self.servedCameraHost = servedCameraHost
            let binding = makeBinding()
            self.binding = binding
            binding.owner.begin(
                hostName: hostName, cameraName: cameraName, passcode: watcherPasscode,
                allowsControl: allowsControlRequests)
            guard self.binding === binding else { return }
            let source = binding.owner.connectionSource
            do {
                let parameters = RelayAppleNetwork.parameters(
                    RelayNetworkPolicy(
                        includePeerToPeer: includePeerToPeer,
                        prohibitsCellular: network.prohibitsCellular,
                        keepaliveIdle: network.keepaliveIdle,
                        keepaliveInterval: network.keepaliveInterval,
                        keepaliveCount: network.keepaliveCount))
                let listener: NWListener
                if let preferredPort, let port = NWEndpoint.Port(rawValue: preferredPort),
                    let reused = try? NWListener(using: parameters, on: port)
                {
                    listener = reused
                } else {
                    listener = try NWListener(using: parameters)
                }
                listener.service = advertisedService()
                listener.newConnectionHandler = {
                    [weak self, weak binding, weak listener] connection in
                    Task { @MainActor in
                        guard let self, let binding, let listener,
                            self.binding === binding, binding.listener === listener,
                            binding.owner.admitsConnectionSource(source)
                        else {
                            connection.cancel()
                            return
                        }
                        self.accept(connection, binding: binding, source: source)
                    }
                }
                listener.stateUpdateHandler = { [weak self, weak binding, weak listener] state in
                    Task { @MainActor in
                        guard let self, let binding, let listener,
                            self.binding === binding, binding.listener === listener,
                            binding.owner.admitsConnectionSource(source)
                        else { return }
                        switch state {
                        case .ready:
                            self.boundPort = listener.port?.rawValue
                            self.onListening?(self.boundPort)
                        case .failed(let error):
                            self.onFailure?("Sharing stopped: \(error.localizedDescription)")
                            if self.binding === binding { self.stop() }
                        default: break
                        }
                    }
                }
                binding.listener = listener
                isBroadcasting = true
                listener.start(queue: queue)
            } catch {
                if self.binding === binding { _ = stopOwner(notifyingViewers: nil) }
                onFailure?("Couldn't start sharing: \(error.localizedDescription)")
            }
        }
        private func makeBinding() -> Binding {
            let now = now
            let sleep = sleep
            let owner = RelayHostSession(
                codec: codec,
                policy: .init(
                    introduction: .onAccept, frameDepth: depth,
                    requiresVersionMatch: requiresVersionMatch,
                    sendsTokenOnHello: false, verifiesAuthorizedHelloPasscode: false,
                    ignoresMalformedPayloads: true, boundsIntroductionStateWrites: false,
                    versionMismatchReason: versionMismatchReason),
                now: { MainActor.assumeIsolated { now() } },
                execute: { action in Task { @MainActor in action() } },
                schedule: { seconds, action in
                    Task { @MainActor in
                        await sleep(seconds)
                        if !Task.isCancelled { action() }
                    }
                })
            let binding = Binding(owner: owner)
            owner.onSend = { [weak self, weak binding] bytes, id, completion in
                MainActor.assumeIsolated {
                    guard let self, let connection = binding?.peers[id]?.connection else {
                        completion()
                        return
                    }
                    self.sendWire(bytes, connection, completion)
                }
            }
            owner.onClose = { [weak self, weak binding] id in
                MainActor.assumeIsolated {
                    guard let self, let binding else { return }
                    binding.peers.removeValue(forKey: id)?.connection.cancel()
                    if binding.peers.isEmpty, self.binding !== binding {
                        self.retiring.removeValue(forKey: binding.id)
                    }
                }
            }
            owner.onChange = { [weak self, weak binding] in
                MainActor.assumeIsolated {
                    if let binding { self?.refresh(binding) }
                }
            }
            owner.onCommand = { [weak self, weak binding] command, admission in
                MainActor.assumeIsolated {
                    guard let self, let binding, self.binding === binding,
                        binding.owner.commandGate.admits(admission)
                    else { return }
                    if let onAdmittedCommand = self.onAdmittedCommand {
                        onAdmittedCommand(command, admission)
                    } else {
                        self.onCommand?(command)
                    }
                }
            }
            owner.onKeyframeNeeded = { [weak self, weak binding] in
                MainActor.assumeIsolated {
                    guard let self, let binding, self.binding === binding else { return }
                    self.onKeyframeNeeded?()
                }
            }
            owner.onEvent = { [weak self, weak binding] event in
                MainActor.assumeIsolated {
                    guard let self, let binding, self.binding === binding else { return }
                    switch event {
                    case .connected(let count):
                        self.journal("relay host: viewer connected (\(count) total)")
                    case .left(let count): self.journal("relay host: viewer left (\(count) remain)")
                    case .refused: self.journal("relay host: viewer refused (passcode)")
                    case .holderParked: self.journal("relay host: holder dropped; control parked")
                    case .holderRestored: self.journal("relay host: dropped holder resumed control")
                    case .parkedExpired:
                        self.journal("relay host: parked claim expired; control returned")
                    case .closing: break
                    }
                }
            }
            return binding
        }
        private func configureAdmission() {
            binding?.owner.configure(
                passcode: watcherPasscode, allowsControl: allowsControlRequests)
        }
        private func advertisedService() -> NWListener.Service {
            var txt = NWTXTRecord()
            if let servedCameraHost, !servedCameraHost.isEmpty {
                txt[codec.profile.servedCameraTXTKey] = servedCameraHost
            }
            return NWListener.Service(
                name: hostName, type: codec.profile.serviceType, txtRecord: txt)
        }
        public func updateServedCamera(cameraName: String?, servedCameraHost: String?) {
            guard self.cameraName != cameraName || self.servedCameraHost != servedCameraHost else {
                return
            }
            self.cameraName = cameraName
            self.servedCameraHost = servedCameraHost
            binding?.owner.updateCameraName(cameraName)
            binding?.listener?.service = advertisedService()
        }
        public func retireSource() { binding?.owner.retireSource() }
        public func stop() { stop(notifyingViewers: nil) }
        public func stop(notifyingViewers reason: String?) {
            _ = stopOwner(notifyingViewers: reason)
        }
        private func stopOwner(notifyingViewers reason: String?) -> UUID {
            retiredSource = UUID()
            let retired = retiredSource
            let previous = binding
            binding = nil
            previous?.listener?.cancel()
            previous?.listener = nil
            boundPort = nil
            isBroadcasting = false
            let oldCount = peerCount
            peerCount = 0
            if let previous {
                retiring[previous.id] = previous
                previous.owner.stop(reason: reason)
                if previous.peers.isEmpty { retiring.removeValue(forKey: previous.id) }
            }
            if oldCount != 0 { onPeerCountChanged?(0) }
            if binding == nil, retiredSource == retired { onControlChanged?() }
            return retired
        }
        private func accept(_ connection: NWConnection, binding: Binding, source: UUID) {
            guard self.binding === binding, binding.owner.admitsConnectionSource(source) else {
                connection.cancel()
                return
            }
            let peer = Peer(connection: connection, authorized: watcherPasscode.isEmpty)
            binding.peers[peer.common.id] = peer
            binding.owner.install(peer.common)
            guard current(peer, binding: binding, source: source) else { return }
            connection.stateUpdateHandler = { [weak self, weak binding, weak peer] state in
                Task { @MainActor in
                    guard let self, let binding, let peer,
                        self.current(peer, binding: binding, source: source)
                    else { return }
                    switch state {
                    case .failed, .cancelled: binding.owner.drop(peer.common)
                    default: break
                    }
                }
            }
            connection.start(queue: queue)
            receive(peer, binding: binding, source: source)
        }
        private func current(_ peer: Peer, binding: Binding, source: UUID) -> Bool {
            self.binding === binding && binding.owner.admitsConnectionSource(source)
                && binding.peers[peer.common.id] === peer
        }
        private func receive(_ peer: Peer, binding: Binding, source: UUID) {
            peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self, weak binding, weak peer] bytes, _, complete, error in
                Task { @MainActor in
                    guard let self, let binding, let peer,
                        self.current(peer, binding: binding, source: source)
                    else { return }
                    do { try binding.owner.receive(bytes ?? Data(), from: peer.common) } catch {
                        binding.owner.drop(peer.common)
                        return
                    }
                    guard self.current(peer, binding: binding, source: source),
                        !peer.common.delivery.closing
                    else { return }
                    if complete || error != nil {
                        binding.owner.drop(peer.common)
                    } else {
                        self.receive(peer, binding: binding, source: source)
                    }
                }
            }
        }
        private func refresh(_ binding: Binding) {
            guard self.binding === binding else { return }
            let count = binding.owner.peerCount
            if peerCount != count {
                peerCount = count
                onPeerCountChanged?(count)
            }
            guard self.binding === binding else { return }
            onControlChanged?()
        }
        public func admits(_ admission: RelayHostControl.Admission) -> Bool {
            binding?.owner.commandGate.admits(admission) == true
        }
        /// Captures the actual thread-safe owner gate for an integration's native executor.
        public func capturedCommandAdmission(
            for admission: RelayHostControl.Admission
        ) -> @Sendable () -> Bool {
            guard let gate = binding?.owner.commandGate else { return { false } }
            return { gate.admits(admission) }
        }
        public func grantPendingControl() { binding?.owner.grantControl() }
        public func declinePendingControl() { binding?.owner.denyControl() }
        public func reclaimControl() { binding?.owner.reclaimControl() }
        public func broadcast(state: Codec.State) { binding?.owner.broadcast(state: state) }
        public func adoptProfile(_ profile: RelayEncoderProfile) {
            depth = profile.maxInFlightFramesPerPeer
            binding?.owner.adoptFrameDepth(depth)
        }
        public var hasPeerReadyForFrame: Bool { binding?.owner.hasPeerReadyForFrame == true }
        public var hasJPEGOnlyPeers: Bool { binding?.owner.hasJPEGOnlyPeers == true }
        public func broadcast(
            frameMetadata: Codec.FrameMetadata, image: Data, admittedSource: UUID? = nil
        ) {
            binding?.owner.broadcast(
                metadata: frameMetadata, image: image, admittedSource: admittedSource)
        }
        public func broadcastJPEGFallback(
            frameMetadata: Codec.FrameMetadata, image: Data, admittedSource: UUID? = nil
        ) {
            binding?.owner.broadcast(
                metadata: frameMetadata, image: image, admittedSource: admittedSource,
                jpegOnly: true)
        }
    }
#endif
