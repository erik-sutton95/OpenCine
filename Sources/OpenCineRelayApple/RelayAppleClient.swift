#if canImport(Network)
    import Foundation
    import Network
    import OpenCineRelay

    public enum RelayAppleClientState: Equatable, Sendable {
        case idle, connecting
        case waiting(String)
        case connected(hostName: String, cameraName: String?)
        case failed(String)
    }

    /// Exact deployed watcher facts. The projections read wire values and never drive a camera.
    public struct RelayAppleWatcherConfiguration<Metadata: Sendable, Control: Sendable, Denied: Sendable>: Sendable {
        public let deviceName: String
        public let passcode: String?
        public let timing: RelayWatcherTimingPolicy
        public let encodedAt: @Sendable (Metadata) -> TimeInterval?
        public let holderIsRecipient: @Sendable (Control) -> Bool?
        public let refusal: @Sendable (Denied) -> RelayWatcherRefusal
        public init(deviceName: String, passcode: String?,
            timing: RelayWatcherTimingPolicy = .init(),
            encodedAt: @escaping @Sendable (Metadata) -> TimeInterval?,
            holderIsRecipient: @escaping @Sendable (Control) -> Bool?,
            refusal: @escaping @Sendable (Denied) -> RelayWatcherRefusal) {
            self.deviceName = deviceName; self.passcode = passcode
            self.timing = timing; self.encodedAt = encodedAt
            self.holderIsRecipient = holderIsRecipient; self.refusal = refusal
        }
    }

    /// The real connection race, introduction queue and typed receive owner. Saved install
    /// identity/passcode storage arrives as explicit values; no bundle/default lookup lives here.
    @MainActor public final class RelayAppleClient<Codec: RelayWireCodec> {
        public typealias State = RelayAppleClientState
        public private(set) var state: State = .idle
        public private(set) var actionRevision: UInt64 = 0
        public var onStateChanged: (@MainActor (State) -> Void)?
        public var onRelayState: (@MainActor (Codec.State) -> Void)?
        public var onFrame: (@MainActor (Codec.FrameMetadata, Data) -> Void)?
        public var onControlToken: (@MainActor (Codec.ControlToken) -> Void)?
        public var onJoinDenied: (@MainActor (Codec.JoinDenied) -> Void)?
        public var onWatcherChanged: (@MainActor (RelayWatcherStatus) -> Void)?
        public var onSourceBegan: (@MainActor (UUID, Bool) -> Void)?
        public var onReconnect: (@MainActor () -> Void)?
        public var resolveWatcherEndpoint: (@MainActor (NWEndpoint) -> NWEndpoint?)?
        public var sourceToken: UUID { lifetime.token }
        public var watcherStatus: RelayWatcherStatus? { watcherSession?.status }
        public var watcherCanControl: Bool { watcherSession?.status.phase == .live && watcherHoldsControl == true }
        private let codec: Codec
        private let network: RelayNetworkPolicy
        private let racePeerToPeer: Bool
        private let watcherID: String?
        private let versionMismatchReason: String
        private let unreachableSuffix: String
        private let journal: @Sendable (String) -> Void
        private let sleep: @MainActor (TimeInterval) async -> Void
        private let now: @Sendable () -> TimeInterval
        private let watcher: RelayAppleWatcherConfiguration<Codec.FrameMetadata, Codec.ControlToken, Codec.JoinDenied>?
        private var watcherSession: RelayWatcherSession?
        private var watcherEpisode: UUID?
        private var watcherEndpoint: NWEndpoint?
        private var watcherTask: Task<Void, Never>?
        private var lastWatcherStatus: RelayWatcherStatus?
        private var watcherHoldsControl: Bool?
        private var lifetime = RelayConnectionLifetime()
        private var connection: NWConnection?
        private var reader: RelayAppleReader<Codec>?
        private var racing: [NWConnection] = []
        private var pendingHello: [Data] = []
        private var connectTimeout: Task<Void, Never>?
        private var lastWaitingReason: String?
        private var lastControl: Codec.ControlToken?
        private let queue = DispatchQueue(label: "opc.relay.client", qos: .userInitiated)
        public init(
            codec: Codec, network: RelayNetworkPolicy = .init(), racePeerToPeer: Bool = false,
            watcherID: String?, versionMismatchReason: String, unreachableSuffix: String = "",
            journal: @escaping @Sendable (String) -> Void = { _ in },
            sleep: (@MainActor (TimeInterval) async -> Void)? = nil, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            watcher: RelayAppleWatcherConfiguration<Codec.FrameMetadata, Codec.ControlToken, Codec.JoinDenied>? = nil
        ) {
            self.codec = codec
            self.network = network
            self.racePeerToPeer = racePeerToPeer
            self.watcherID = watcherID
            self.versionMismatchReason = versionMismatchReason
            self.unreachableSuffix = unreachableSuffix
            self.journal = journal
            // Resolved here, not as a closure-literal default (swiftlang/swift#92017).
            self.sleep = sleep ?? { seconds in try? await Task.sleep(for: .seconds(seconds)) }
            self.now = now; self.watcher = watcher
            self.watcherSession = watcher.map { RelayWatcherSession(policy: $0.timing) }
        }
        public func connect(to endpoint: NWEndpoint) {
            var startedEpisode: UUID?
            if watcher != nil {
                watcherTask?.cancel(); watcherTask = nil
                watcherEpisode = UUID(); watcherEndpoint = endpoint
                watcherSession?.begin(now: now())
                let episode = watcherEpisode
                startedEpisode = episode
                publishWatcher()
                guard watcherEpisode == episode else { return }
            }
            connectTransport(to: endpoint, recovering: false)
            if let startedEpisode, watcherEpisode == startedEpisode { driveWatcher(startedEpisode) }
        }
        private func connectTransport(to endpoint: NWEndpoint, recovering: Bool) {
            let retired = retireConnection(publishIdle: watcher == nil)
            guard lifetime.token == retired, !lifetime.active else { return }
            let token = lifetime.begin()
            actionRevision &+= 1
            watcherHoldsControl = nil
            watcherSession?.beginConnection()
            update(.connecting)
            guard lifetime.admits(token) else { return }
            onSourceBegan?(token, recovering)
            guard lifetime.admits(token) else { return }
            let endpoint = RelayAppleNetwork.rediscoveryEndpoint(endpoint)
            let modes = racePeerToPeer ? [false, true] : [network.includePeerToPeer]
            racing = modes.map { includes in
                NWConnection(
                    to: endpoint,
                    using: RelayAppleNetwork.parameters(
                        .init(
                            includePeerToPeer: includes,
                            prohibitsCellular: network.prohibitsCellular,
                            keepaliveIdle: network.keepaliveIdle,
                            keepaliveInterval: network.keepaliveInterval,
                            keepaliveCount: network.keepaliveCount)))
            }
            for candidate in racing {
                candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                    Task { @MainActor in
                        guard let self, let candidate, self.lifetime.admits(token),
                            self.racing.contains(where: { $0 === candidate })
                        else { return }
                        switch state {
                        case .ready: self.adopt(candidate, token: token)
                        case .waiting(let error):
                            guard self.connection == nil else { return }
                            self.lastWaitingReason = error.localizedDescription
                            self.journal("relay client: waiting; \(error.localizedDescription)")
                            self.update(.waiting(error.localizedDescription))
                        case .failed(let error):
                            self.candidateFailed(candidate, error: error, token: token)
                        default: break
                        }
                    }
                }
                candidate.start(queue: queue)
            }
            if let watcher {
                introduce(deviceName: watcher.deviceName, passcode: watcher.passcode)
                return
            }
            connectTimeout = Task { [weak self] in
                guard let self else { return }
                await sleep(15)
                guard !Task.isCancelled, lifetime.admits(token), connection == nil else { return }
                let reason = lastWaitingReason.map { " (\($0))" } ?? ""
                update(
                    .failed("Couldn't reach the broadcasting device\(reason)." + unreachableSuffix))
                if lifetime.admits(token) { stop() }
            }
        }
        private func adopt(_ winner: NWConnection, token: UUID) {
            guard lifetime.admits(token), connection == nil,
                racing.contains(where: { $0 === winner })
            else {
                if winner !== connection { winner.cancel() }
                return
            }
            journal("relay client: transport ready, adopted")
            guard lifetime.admits(token), connection == nil, racing.contains(where: { $0 === winner }) else {
                if winner !== connection { winner.cancel() }
                return
            }
            connection = winner
            for candidate in racing where candidate !== winner { candidate.cancel() }
            racing = []
            connectTimeout?.cancel()
            connectTimeout = nil
            winner.stateUpdateHandler = { [weak self, weak winner] state in
                Task { @MainActor in
                    guard let self, let winner, self.lifetime.admits(token),
                        self.connection === winner
                    else { return }
                    switch state {
                    case .waiting(let error): self.update(.waiting(error.localizedDescription))
                    case .failed(let error):
                        if self.watcher != nil { self.watcherConnectionLost(error.localizedDescription, token: token) }
                        else { self.update(.failed(error.localizedDescription)) }
                    case .cancelled: self.update(.idle)
                    default: break
                    }
                }
            }
            for wire in pendingHello {
                winner.send(content: wire, completion: .contentProcessed { _ in })
            }
            pendingHello = []
            let reader = RelayAppleReader(codec: codec, maximumReceiveBytes: 1024 * 1024)
            self.reader = reader
            receive(on: winner, reader: reader, token: token)
        }
        private func candidateFailed(_ candidate: NWConnection, error: NWError, token: UUID) {
            guard lifetime.admits(token), connection == nil,
                racing.contains(where: { $0 === candidate })
            else { return }
            racing.removeAll { $0 === candidate }
            if racing.isEmpty {
                if watcher != nil { watcherConnectionLost(error.localizedDescription, token: token); return }
                update(.failed(error.localizedDescription))
                if lifetime.admits(token) { stop() }
            }
        }
        public func stop() {
            watcherTask?.cancel(); watcherTask = nil; watcherEpisode = nil
            watcherSession?.leave()
            _ = retireConnection()
            publishWatcher()
        }
        private func retireConnection(publishIdle: Bool = true) -> UUID {
            lifetime.retire()
            actionRevision &+= 1
            reader = nil
            lastControl = nil
            let retired = lifetime.token
            connectTimeout?.cancel()
            connectTimeout = nil
            for candidate in racing { candidate.cancel() }
            racing = []
            pendingHello = []
            lastWaitingReason = nil
            let previous = connection
            connection = nil
            previous?.cancel()
            if publishIdle, state != .idle { update(.idle) }
            return retired
        }
        public func introduce(deviceName: String, passcode: String? = nil, codecs: [String]? = nil)
        {
            guard lifetime.active,
                let payload = try? codec.encodeHello(
                    .init(
                        version: codec.profile.version,
                        hostName: deviceName, passcode: passcode, codecs: codecs,
                        watcherID: watcherID))
            else { return }
            send(kind: 1, payload: payload, queueIntroduction: true)
        }
        public func requestControl() {
            if watcher != nil {
                let source = lifetime.token
                guard lifetime.admits(source), watcherSession?.requestControl(now: now()) == true else { return }
                publishWatcher()
                guard lifetime.admits(source) else { return }
            }
            send(kind: 0x10, payload: Data())
        }
        public func releaseControl() {
            guard watcher == nil || watcherCanControl else { return }
            send(kind: 0x11, payload: Data())
        }
        public func send(command: Codec.Command) {
            guard watcher == nil || watcherCanControl else { return }
            guard let payload = try? codec.encodeCommand(command) else { return }
            send(kind: 0x12, payload: payload)
        }
        private func send(kind: UInt8, payload: Data, queueIntroduction: Bool = false) {
            guard lifetime.active else { return }
            let wire = RelayStreamFraming.encode(kind: kind, payload: payload)
            guard let connection else {
                if queueIntroduction { pendingHello = [wire] }
                return
            }
            connection.send(content: wire, completion: .contentProcessed { _ in })
        }
        private func receive(
            on connection: NWConnection, reader: RelayAppleReader<Codec>, token: UUID
        ) {
            reader.receive(on: connection) { [weak self, weak reader] messages, complete, error in
                Task { @MainActor in
                    guard let self, let reader, self.lifetime.admits(token),
                        self.connection === connection,
                        self.reader === reader
                    else { return }
                    for message in messages {
                        guard self.lifetime.admits(token), self.connection === connection else {
                            return
                        }
                        switch message {
                        case .frame(let metadata, let bytes):
                            if let watcher = self.watcher {
                                guard self.watcherSession?.status.phase == .live else { continue }
                                if self.watcherSession?.admitsFrame(encodedAt: watcher.encodedAt(metadata), receivedAt: self.now()) != true {
                                    self.watcherConnectionLost("The shared feed fell behind live delivery.", token: token)
                                    return
                                }
                            }
                            self.onFrame?(metadata, bytes)
                        case .control(let control): self.handle(control)
                        }
                    }
                    guard self.lifetime.admits(token), self.connection === connection else {
                        return
                    }
                    if complete || error != nil {
                        if self.watcher != nil {
                            self.watcherConnectionLost(error?.localizedDescription ?? "The connection closed.", token: token)
                            return
                        }
                        self.update(
                            .failed(
                                error == nil
                                    ? "The broadcasting device disconnected."
                                    : "The relay stream desynchronised."))
                        if self.lifetime.admits(token) { self.stop() }
                    } else {
                        self.receive(on: connection, reader: reader, token: token)
                    }
                }
            }
        }
        private func handle(_ message: RelayStreamFraming.Decoded) {
            switch message.kind {
            case 1:
                guard let hello = try? codec.decodeHello(message.payload) else {
                    if watcher != nil { failWatcher("The feed ended.") }
                    return
                }
                guard hello.version == codec.profile.version else {
                    if watcher != nil { failWatcher(versionMismatchReason); return }
                    let token = lifetime.token
                    update(.failed(versionMismatchReason))
                    if lifetime.admits(token) { stop() }
                    return
                }
                let token = lifetime.token
                watcherSession?.connected(now: now())
                update(.connected(hostName: hello.hostName, cameraName: hello.cameraName))
                if lifetime.admits(token) { publishWatcher() }
            case 2:
                if let state = try? codec.decodeState(message.payload) {
                    let token = lifetime.token
                    watcherSession?.receivedState(now: now())
                    onRelayState?(state)
                    if lifetime.admits(token) { publishWatcher() }
                } else if watcher != nil { failWatcher("The feed ended.") }
            case 4:
                guard
                    let value = try? JSONDecoder().decode(
                        Codec.ControlToken.self, from: message.payload)
                else { if watcher != nil { failWatcher("The feed ended.") }; return }
                if lastControl != value {
                    actionRevision &+= 1
                    lastControl = value
                }
                let token = lifetime.token
                watcherHoldsControl = watcher?.holderIsRecipient(value)
                watcherSession?.receivedControl(now: now())
                onControlToken?(value)
                if lifetime.admits(token) { publishWatcher() }
            case 5:
                let decoded = try? JSONDecoder().decode(Codec.JoinDenied.self, from: message.payload)
                if watcher != nil, decoded == nil { failWatcher("The feed ended."); return }
                let denial = decoded ?? codec.joinDenied(
                        reason: "The broadcasting device refused this join.",
                        passcodeRequired: false)
                let token = lifetime.token
                if let watcher {
                    let refusal = watcher.refusal(denial)
                    watcherTask?.cancel(); watcherTask = nil; watcherEpisode = nil
                    watcherSession?.denied(passcodeRequired: refusal.passcodeRequired, reason: refusal.reason)
                    _ = retireConnection(publishIdle: false)
                    onJoinDenied?(denial)
                    publishWatcher()
                    return
                }
                onJoinDenied?(denial)
                if lifetime.admits(token) { stop() }
            default: break
            }
        }
        /// Called by the existing native decoder after presentation, under its captured source.
        public func notePresentedPicture(source: UUID, presentation: TimeInterval) {
            guard lifetime.admits(source) else { return }
            watcherSession?.presentedPicture(presentation: presentation, now: now())
        }
        private func publishWatcher() {
            guard let status = watcherSession?.status, status != lastWatcherStatus else { return }
            lastWatcherStatus = status
            onWatcherChanged?(status)
        }
        private func watcherConnectionLost(_ reason: String, token: UUID) {
            guard lifetime.admits(token), let episode = watcherEpisode else { return }
            journal("relay watcher: connection interrupted; \(reason)")
            guard lifetime.admits(token), watcherEpisode == episode else { return }
            let previous = watcherSession?.status.phase
            let action: WatcherRelayRecovery.Action = watcherSession?.disconnected(now: now()) ?? .none
            if action == .exhausted {
                failWatcher("Could not reconnect. Check camera Wi-Fi and sharing, then choose the feed again.")
                return
            }
            _ = retireConnection(publishIdle: false)
            publishWatcher()
            guard watcherEpisode == episode else { return }
            if previous != watcherSession?.status.phase { onReconnect?() }
        }
        private func driveWatcher(_ episode: UUID) {
            guard watcherEpisode == episode, let watcher else { return }
            watcherTask?.cancel()
            let wait = sleep, interval = watcher.timing.pollInterval
            watcherTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await wait(interval)
                    guard !Task.isCancelled, let self, self.watcherEpisode == episode else { return }
                    self.tickWatcher(episode)
                }
            }
        }
        private func tickWatcher(_ episode: UUID) {
            guard watcherEpisode == episode else { return }
            let previous = watcherSession?.status.phase
            let action: WatcherRelayRecovery.Action = watcherSession?.tick(now: now()) ?? .none
            if previous != watcherSession?.status.phase, let phase = watcherSession?.status.phase,
                case .reconnecting = phase {
                _ = retireConnection(publishIdle: false)
                publishWatcher()
                guard watcherEpisode == episode else { return }
                onReconnect?()
            }
            guard watcherEpisode == episode else { return }
            publishWatcher()
            guard watcherEpisode == episode else { return }
            switch action {
            case .reconnect:
                guard let endpoint = watcherEndpoint else { failWatcher("Choose a shared feed to reconnect."); return }
                let fresh = resolveWatcherEndpoint?(endpoint) ?? RelayAppleNetwork.rediscoveryEndpoint(endpoint)
                guard watcherEpisode == episode else { return }
                connectTransport(to: fresh, recovering: true)
            case .exhausted:
                failWatcher("Could not reconnect. Check that both devices are on the same camera Wi-Fi and sharing is on, then choose the feed again.")
            default: break
            }
        }
        private func failWatcher(_ reason: String) {
            watcherTask?.cancel(); watcherTask = nil; watcherEpisode = nil
            watcherSession?.fail(reason)
            _ = retireConnection(publishIdle: false)
            publishWatcher()
        }
        private func update(_ next: State) {
            guard state != next else { return }
            switch next {
            case .waiting, .failed, .idle: actionRevision &+= 1
            default: break
            }
            state = next
            onStateChanged?(next)
        }
    }
#endif
