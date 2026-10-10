#if canImport(Network) && canImport(VideoToolbox)
    import CoreVideo
    import Foundation
    import Network
    import Observation
    import OpenCineRelay
    import os

    private struct WatcherNativeSource: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
    }

    /// Native socket/VideoToolbox ports over Foundation-only host and source owners.
    public final class WatcherRelayTransport: @unchecked Sendable {
        public let queue: DispatchQueue
        let producer = UUID()
        var controlRevision: UInt64 = 0
        private let orientationLock = NSLock()
        private var orientation = false
        var onChange: (() -> Void)?
        var onCommand: ((WatcherRelayCommand, String?) -> Void)?
        var onAdmittedCommand: ((WatcherRelayCommand, RelayHostControl.Admission) -> Void)?
        var watcherCount = 0
        var encoderFailed = false
        var pendingControlRequest: (name: String, watcherID: String)?
        var holderName = "Host"
        var lease = WatcherRelayControlLease()
        public typealias SendWire = (Data, NWConnection, @escaping @Sendable () -> Void) -> Void
        public typealias EncodeFrame = (
            CVPixelBuffer, Bool, @escaping (WatcherRelayEncoder.Annex?, Bool) -> Void
        ) -> Void
        private let session: RelayHostSession<SharedMonitorRelayCodec>
        private let pipeline:
            RelayHostSourcePipeline<
                SharedMonitorRelayCodec, WatcherNativeSource, WatcherRelayEncoder.Annex, Bool
            >
        private let encoder: WatcherRelayEncoder
        private var listener: NWListener?
        private var socketPeers: [ObjectIdentifier: Peer] = [:]
        private var connections: [UUID: Peer] = [:]
        private var allowsControl = true
        private let log: Logger
        private let journal: @Sendable (String) -> Void
        private let now: () -> TimeInterval

        public init(
            versionMismatchReason: String,
            logSubsystem: String = "com.opencapture.opencine",
            journal: @escaping @Sendable (String) -> Void = { _ in },
            stateInterval: TimeInterval = 0.2,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            encodeFrame: EncodeFrame? = nil,
            sendWire: @escaping SendWire = { data, connection, completion in
                connection.send(content: data, completion: .contentProcessed { _ in completion() })
            }
        ) {
            let workQueue = DispatchQueue(label: "opc.watcher-relay.transport", qos: .userInitiated)
            queue = workQueue
            log = Logger(subsystem: logSubsystem, category: "relay")
            self.journal = journal
            self.now = now
            let session = RelayHostSession(
                codec: SharedMonitorRelayCodec(),
                policy: .init(
                    introduction: .afterAuthorization, ignoresRepeatedAuthorizedHello: true,
                    requiresIdentityForControl: true, presentsParkedHolder: false,
                    boundsIntroductionStateWrites: false,
                    versionMismatchReason: versionMismatchReason, passcodeReason: "Wrong passcode."),
                startsActive: true,
                execute: { action in workQueue.async(execute: action) },
                schedule: { seconds, action in
                    workQueue.asyncAfter(deadline: .now() + seconds, execute: action)
                })
            self.session = session
            let encoder = WatcherRelayEncoder()
            self.encoder = encoder
            pipeline = RelayHostSourcePipeline(
                session: session,
                policy: .init(
                    stateInterval: stateInterval,
                    starvation: .init(absoluteFloorFPS: 0, baselineFraction: 0.8),
                    encoderFailureReason:
                        "The host could not encode the shared picture. Restart sharing on the host."
                ),
                now: now, execute: { action in workQueue.async(execute: action) },
                encode: { source, key, completion in
                    if let encodeFrame {
                        encodeFrame(source.pixelBuffer, key, completion)
                    } else {
                        encoder.encode(source.pixelBuffer, forceKey: key, completion: completion)
                    }
                },
                metadata: { frame, mirrored, recording, encodedAt in
                    WatcherRelayFrameMetadata(
                        isKeyframe: frame.isKey, parameterSets: frame.sets,
                        isRecording: recording, extraMirrored: mirrored, encodedAt: encodedAt)
                }, image: { $0.data }, isRecording: { $0.isRecording })
            session.onSend = { [weak self] wire, id, completion in
                guard let peer = self?.connections[id] else {
                    completion()
                    return
                }
                sendWire(wire, peer.conn, completion)
            }
            session.onClose = { [weak self] id in
                guard let self, let peer = self.connections.removeValue(forKey: id) else { return }
                self.socketPeers.removeValue(forKey: ObjectIdentifier(peer))
                peer.conn.cancel()
            }
            session.onChange = { [weak self] in self?.refreshProjection() }
            session.onCommand = { [weak self] command, admission in
                self?.onAdmittedCommand?(command, admission)
                if self?.onAdmittedCommand == nil {
                    self?.onCommand?(command, self?.session.holderWatcherID)
                }
            }
            session.onEvent = { event in
                if case .closing(let reason) = event {
                    journal("relay host: closing peer (\(reason))")
                }
            }
            pipeline.onBitrate = { encoder.bitsPerSecond = $0 }
            pipeline.onFailure = { [weak self] reason in
                self?.encoderFailed = true
                self?.stop(reason: reason)
            }
            pipeline.onMetrics = { [weak self] count, bps, sent, skipped, keys, fps in
                self?.log.info(
                    "relay: peers=\(count) bps=\(bps) sent=\(sent) skipped=\(skipped) keys=\(keys) cameraFPS=\(fps ?? 0)"
                )
            }
        }
        var commandGate: RelayHostCommandGate { session.commandGate }
        var source: UUID { session.source }
        var authorityRevision: UInt64 { session.controlRevision }
        var bitsPerSecond: Int { pipeline.bitsPerSecond }
        public var listeningPort: NWEndpoint.Port? {
            guard let listener, case .ready = listener.state, let port = listener.port,
                port.rawValue != 0
            else { return nil }
            return port
        }
        /// Original synthetic peer seam exercises exactly the same portable peer owner as sockets.
        var peers: [ObjectIdentifier: Peer] {
            get { socketPeers }
            set {
                let old = socketPeers
                socketPeers = newValue
                for (key, peer) in old where newValue[key] == nil { session.drop(peer.common) }
                for (key, peer) in newValue where old[key] !== peer {
                    connections[peer.common.id] = peer
                    session.install(peer.common)
                }
            }
        }
        public func start(
            hostName: String, cameraName: String, passcode: String, ceilingIndex: Int,
            allowsControl: Bool
        ) {
            listener?.cancel()
            listener = nil
            session.begin(
                hostName: hostName, cameraName: cameraName,
                passcode: passcode.trimmingCharacters(in: .whitespacesAndNewlines),
                allowsControl: allowsControl)
            self.allowsControl = allowsControl
            pipeline.begin(ceilingIndex: ceilingIndex)
            encoderFailed = false
            let source = session.connectionSource
            do {
                let listener = try NWListener(using: WatcherRelayNetwork.parameters())
                var txt = NWTXTRecord()
                txt[WatcherRelayProtocol.txtCamera] = cameraName
                txt[WatcherRelayProtocol.txtWatchable] = "1"
                listener.service = NWListener.Service(
                    name: hostName, type: WatcherRelayProtocol.serviceType, txtRecord: txt)
                listener.newConnectionHandler = { [weak self, weak listener] connection in
                    guard let self, let listener, self.listener === listener,
                        self.session.admitsConnectionSource(source)
                    else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener,
                        self.session.admitsConnectionSource(source)
                    else { return }
                    if case .failed = state {
                        self.encoderFailed = true
                        self.stop()
                        self.onChange?()
                    }
                }
                self.listener = listener
                listener.start(queue: queue)
                log.info("relay: listening \(WatcherRelayProtocol.serviceType, privacy: .public)")
            } catch {
                encoderFailed = true
                onChange?()
                log.error("relay: listen failed \(error.localizedDescription, privacy: .public)")
            }
        }
        public func stop(reason: String? = nil) {
            listener?.cancel()
            listener = nil
            pipeline.stop()
            encoder.invalidate()
            session.stop(reason: reason)
            watcherCount = 0
            pendingControlRequest = nil
            onChange?()
        }
        func retireSource(publication: RelayHostCommandGate.Publication? = nil) {
            if let publication {
                session.retireSource(publication: publication)
            } else {
                session.retireSource()
            }
            pipeline.retireSource()
            encoder.invalidate()
        }
        func setCeiling(_ index: Int) { pipeline.setCeiling(index) }
        func updateOrientation(_ mirrored: Bool) {
            orientationLock.lock()
            orientation = mirrored
            orientationLock.unlock()
        }
        func submit(_ identity: CVPixelBuffer) {
            orientationLock.lock()
            let mirrored = orientation
            orientationLock.unlock()
            pipeline.submit(WatcherNativeSource(pixelBuffer: identity), context: mirrored)
        }
        func update(state: WatcherRelayState) {
            var state = state
            state.allowsControlRequests = allowsControl
            pipeline.update(state: state, measuredCameraFPS: Double(state.liveFPS))
        }
        func grantControl() { session.grantControl() }
        func denyControl() { session.denyControl() }
        func reclaimControl(publication: RelayHostCommandGate.Publication? = nil) {
            if let publication {
                session.reclaimControl(publication: publication)
            } else {
                session.reclaimControl()
            }
        }
        func applyCommand(_ command: WatcherRelayCommand, from watcherID: String?)
            -> WatcherRelayCommand?
        {
            guard let admission = session.admission(watcherID: watcherID),
                session.commandGate.admits(admission)
            else { return nil }
            return command
        }
        func onMessage(peer: Peer, msg: WatcherRelayFraming.Decoded) throws {
            try session.handle(
                .init(
                    kind: msg.kind.rawValue, payload: msg.payload, consumedBytes: msg.consumedBytes),
                from: peer.common)
        }
        public func broadcast(
            hevc: Data, isKey: Bool, sets: [Data]?, mirrored: Bool = false, recording: Bool = false
        ) {
            session.broadcast(
                metadata: .init(
                    isKeyframe: isKey, parameterSets: sets,
                    isRecording: recording, extraMirrored: mirrored, encodedAt: now()), image: hevc)
        }
        func drop(_ peer: Peer) { session.drop(peer.common) }
        private func refreshProjection() {
            watcherCount = session.watcherCount
            pendingControlRequest = session.pendingName.map { ($0, session.pendingWatcherID ?? "") }
            holderName = session.holderName
            lease.holderName = holderName
            lease.holderWatcherID = session.holderWatcherID
            onChange?()
        }
        private func accept(_ connection: NWConnection) {
            let peer = Peer(conn: connection)
            peers[ObjectIdentifier(peer)] = peer
            let source = session.connectionSource
            connection.stateUpdateHandler = { [weak self, weak peer] state in
                guard let self, let peer, self.session.admitsConnectionSource(source),
                    self.connections[peer.common.id] === peer
                else { return }
                if case .failed = state { self.drop(peer) }
            }
            receive(peer, source: source)
            connection.start(queue: queue)
        }
        private func receive(_ peer: Peer, source: UUID) {
            peer.conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self, weak peer] data, _, complete, error in
                guard let self, let peer, self.session.admitsConnectionSource(source),
                    self.connections[peer.common.id] === peer
                else { return }
                do { try self.session.receive(data ?? Data(), from: peer.common) } catch {
                    self.drop(peer)
                    return
                }
                guard self.connections[peer.common.id] === peer, !peer.closing else { return }
                if complete || error != nil {
                    self.drop(peer)
                } else {
                    self.receive(peer, source: source)
                }
            }
        }
        final class Peer: @unchecked Sendable {
            let conn: NWConnection
            let common = RelayHostSessionPeer()
            var authorized: Bool {
                get { common.delivery.authorized }
                set { common.delivery.authorized = newValue }
            }
            var closing: Bool {
                get { common.delivery.closing }
                set { common.delivery.closing = newValue }
            }
            var needsKeyframe: Bool {
                get { common.delivery.needsKeyframe }
                set { common.delivery.needsKeyframe = newValue }
            }
            var inFlight: Int {
                get { common.delivery.inFlightFrames }
                set { common.delivery.inFlightFrames = newValue }
            }
            var stateInFlight: Bool { common.delivery.inFlightStates > 0 }
            var watcherID: String? {
                get { common.hello?.watcherID }
                set {
                    common.hello = .init(
                        version: WatcherRelayProtocol.version, hostName: common.name,
                        watcherID: newValue)
                }
            }
            var name: String {
                get { common.name }
                set { common.name = newValue }
            }
            init(conn: NWConnection) { self.conn = conn }
        }
    }

    public struct WatcherRelayCommandDelivery: Sendable {
        public let command: WatcherRelayCommand
        public let admission: RelayHostControl.Admission
        fileprivate let producer: UUID
        fileprivate let modelRevision: UInt64
    }

    /// Only operator state crosses MainActor. Frame bytes, VT settings, and sockets do not.
    @available(macOS 14, *)
    @MainActor
    @Observable
    public final class WatcherRelayHost {
        public internal(set) var watcherCount = 0
        public internal(set) var encoderFailed = false
        public internal(set) var pendingControlRequest: (name: String, watcherID: String)?
        public internal(set) var holderName = "Host"
        @ObservationIgnored private var holderWatcherID: String?
        @ObservationIgnored private var controlRevision: UInt64 = 0
        @ObservationIgnored private(set) var transport: WatcherRelayTransport?
        public var onCommand: (@MainActor (WatcherRelayCommandDelivery) -> Void)?
        @ObservationIgnored private let statePoller: RelayStatePoller<WatcherRelayState>
        @ObservationIgnored private let versionMismatchReason: String
        @ObservationIgnored private let logSubsystem: String
        @ObservationIgnored private let journal: @Sendable (String) -> Void
        @ObservationIgnored private let stateInterval: TimeInterval

        /// The app's version-mismatch copy, log subsystem and journal; state broadcasts at most
        /// every `stateInterval`.
        public init(
            versionMismatchReason: String, logSubsystem: String,
            journal: @escaping @Sendable (String) -> Void, stateInterval: TimeInterval = 0.2
        ) {
            self.versionMismatchReason = versionMismatchReason
            self.logSubsystem = logSubsystem
            self.journal = journal
            self.stateInterval = stateInterval
            statePoller = RelayStatePoller(interval: max(stateInterval, 0.001))
        }

        public func start(
            hostName: String, cameraName: String, passcode: String, ceilingIndex: Int,
            allowsControl: Bool
        ) {
            stop()
            encoderFailed = false
            let transport = WatcherRelayTransport(
                versionMismatchReason: versionMismatchReason, logSubsystem: logSubsystem,
                journal: journal, stateInterval: stateInterval)
            self.transport = transport
            transport.controlRevision = controlRevision
            transport.onChange = { [weak self, weak transport] in
                guard let transport else { return }
                let revision = transport.controlRevision
                let count = transport.watcherCount
                let failed = transport.encoderFailed
                let pending = transport.pendingControlRequest
                let holder = transport.holderName
                let holderID = transport.lease.holderWatcherID
                let source = transport.source
                let authorityRevision = transport.authorityRevision
                Task { @MainActor [weak self, weak transport] in
                    guard let self, let transport, self.transport === transport,
                        self.controlRevision == revision,
                        transport.commandGate.admits(source: source, revision: authorityRevision)
                    else { return }
                    self.watcherCount = count
                    self.encoderFailed = failed
                    self.pendingControlRequest = pending
                    self.holderName = holder
                    self.holderWatcherID = holderID
                }
            }
            transport.onAdmittedCommand = { [weak self, weak transport] command, admission in
                guard let transport else { return }
                let revision = transport.controlRevision
                let delivery = WatcherRelayCommandDelivery(
                    command: command, admission: admission,
                    producer: transport.producer, modelRevision: revision)
                Task { @MainActor in
                    guard let self, self.admits(delivery) else { return }
                    self.onCommand?(delivery)
                }
            }
            // Retained original test-facing callback cannot manufacture actual peer admission.
            transport.onCommand = { _, _ in }
            transport.queue.async {
                transport.start(
                    hostName: hostName, cameraName: cameraName, passcode: passcode,
                    ceilingIndex: ceilingIndex, allowsControl: allowsControl)
            }
        }

        /// Capture once when wiring the decoder; no per-frame actor hop or retained host model.
        public func frameSink() -> (CVPixelBuffer) -> Void {
            { [weak transport] buffer in transport?.submit(buffer) }
        }

        public func orientationSink() -> (Bool) -> Void {
            { [weak transport] mirrored in transport?.updateOrientation(mirrored) }
        }

        public func update(state: WatcherRelayState) {
            guard let transport else { return }
            transport.queue.async { transport.update(state: state) }
        }

        /// Apps project typed readings; common cadence and stop/reentry belong to this owner.
        public func pollState(
            _ read: @escaping @MainActor @Sendable () -> WatcherRelayState?,
            onFailure: @escaping @MainActor @Sendable () -> Void
        ) {
            guard let transport else { return }
            statePoller.begin(
                source: transport.producer, read: read,
                receive: { [weak self] in self?.update(state: $0) },
                hasFailed: { [weak self] in self?.encoderFailed == true }, onFailure: onFailure)
        }

        public func admits(_ delivery: WatcherRelayCommandDelivery) -> Bool {
            guard let transport, transport.producer == delivery.producer,
                controlRevision == delivery.modelRevision
            else { return false }
            return transport.commandGate.admits(delivery.admission)
        }

        /// Capture the existing locked gate, never actor-confined app/session predicates.
        public func capturedCommandAdmission(for delivery: WatcherRelayCommandDelivery)
            -> @Sendable () -> Bool
        {
            guard admits(delivery), let gate = transport?.commandGate else { return { false } }
            return { gate.admits(delivery.admission) }
        }

        public func retireSource() {
            controlRevision &+= 1
            holderWatcherID = nil
            guard let transport else { return }
            let revision = controlRevision
            let publication = transport.commandGate.retire()
            transport.queue.async {
                transport.controlRevision = revision
                transport.retireSource(publication: publication)
            }
        }

        public func stop() {
            statePoller.stop()
            controlRevision &+= 1
            if let transport {
                transport.commandGate.retire()
                transport.queue.async { transport.stop(reason: "The host ended this shared feed.") }
            }
            transport = nil
            holderWatcherID = nil
            watcherCount = 0
            pendingControlRequest = nil
        }

        public func setCeiling(_ index: Int) {
            guard let transport else { return }
            transport.queue.async { transport.setCeiling(index) }
        }

        public func grantControl() {
            guard let transport else { return }
            transport.queue.async { transport.grantControl() }
        }

        public func denyControl() {
            guard let transport else { return }
            transport.queue.async { transport.denyControl() }
        }

        public func reclaimControl() {
            holderWatcherID = nil
            controlRevision &+= 1
            let revision = controlRevision
            guard let transport else { return }
            let publication = transport.commandGate.retire()
            transport.queue.async {
                transport.controlRevision = revision
                transport.reclaimControl(publication: publication)
            }
        }

        public func applyCommand(_ command: WatcherRelayCommand, from watcherID: String?)
            -> WatcherRelayCommand?
        {
            guard let watcherID, watcherID == holderWatcherID,
                transport?.commandGate.admits(watcherID: watcherID) == true
            else { return nil }
            return command
        }
    }

    extension Notification.Name {
        public static let opcWatcherRelayCommand = Notification.Name("opc.watcherRelay.command")
    }

#endif
