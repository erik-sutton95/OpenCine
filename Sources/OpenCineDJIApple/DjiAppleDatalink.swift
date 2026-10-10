#if os(iOS)
    import Foundation
    import Network
    import OpenCineDJI
    import OpenCineMedia
    import OpenCineMotion
    import os

    /// The DUML-over-UDP datalink on iOS: opens the socket to 192.168.2.1, runs the handshake, registers
    /// the app, subscribes to status, and pumps keepalives - using the byte builders from the (tested)
    /// core. This is the stateful half the core deliberately leaves out (session id, the sequence
    /// counters, the peer-cursor echo).
    ///
    /// Video (pktType 0x02) is best-effort UDP. Mimo keeps the camera's send windows open with a
    /// pktType-0x04 ACK ~40 times a second: group 0 = latest video seq, group 1 = the
    /// forward-most reliable command/download cursor, group 2 = telemetry extra. Receive is
    /// re-armed on the UDP queue (never the main actor) so a busy UI cannot stall the socket.
    @MainActor
    public final class DjiAppleDatalink {
        /// Thread-safe admission identity for this exact endpoint and its UDP replacement epochs.
        nonisolated public let commandOwner = DJICommandOwner()
        private let subscriptionKeys: [String]
        private let stationHost: String?
        private let stationHotspot: Bool
        #if DEBUG
            private var usesLoopbackForTesting = false
            /// Runs the real UDP handshake/recovery against a deterministic local peer.
            public static func loopbackForTesting(
                port: UInt16, host: DjiAppleTransportHost = .init()
            ) -> DjiAppleDatalink {
                let driver = DjiAppleDatalink(
                    port: port, tcpPoke: false, pairingToken: "", host: host)
                driver.usesLoopbackForTesting = true
                return driver
            }
        #endif
        private var remoteHost: String {
            #if DEBUG
                if usesLoopbackForTesting { return "127.0.0.1" }
            #endif
            return stationHost ?? CameraSoftAP.host
        }
        private var pathReady: Bool {
            #if DEBUG
                if usesLoopbackForTesting { return true }
            #endif
            return stationHost == nil
                ? DjiAppleWiFiJoiner.isCameraPathReady()
                : DjiAppleSharedWiFiPath.address(hotspot: stationHotspot) != nil
        }
        private let port: UInt16
        private let tcpPoke: Bool
        private let pairingToken: String
        nonisolated private let q = DispatchQueue(label: "opv.datalink.udp")
        /// All UDP TX (ACK, stick, Flip GET, SET) serializes here. MainActor
        /// `conn.send` interleaved with this pump starved window ACK.
        private static let qKey = DispatchSpecificKey<UInt8>()
        private var conn: NWConnection?
        private var pokeConn: NWConnection?  // kept open for the session; Mimo does not RST 7001
        private var ackTimer: DispatchSourceTimer?
        private var pathMonitor: NWPathMonitor?
        private var writeHealthy = true
        private var lastCommandWriteLanded: Bool?
        private var rebuilding = false
        private var lastRebuildAt: Date?
        /// Bumped before the old UDP is canceled so its 89 / write failures
        /// cannot mark the replacement socket dead.
        private var udpGeneration = 0
        /// Readable from the UDP ingest closure without hopping to MainActor.
        nonisolated private let liveGeneration = OSAllocatedUnfairLock(initialState: 0)
        private var cameraInterface: NWInterface?
        private var cameraLocalIPv4: String?

        // Sequencing state (mirrors Osmosis DumlTransport). Touched on `q` after open().
        private var sessionId: UInt16 = 0
        private var baseSeq: UInt16 = 0
        private var udpSeq: UInt16 = 0
        private var dumlSeq: UInt16 = 0xA000
        private var cmdCounter: UInt8 = 0
        private var peerCursor: UInt16 = 0
        /// Collect the ACK and initial command window on the UDP queue. Registration
        /// needs both; the short ACK payload is not a command sequence.
        nonisolated private let handshakeAdmission = OSAllocatedUnfairLock(
            initialState: DatalinkHandshakeAdmission())
        /// Inbound datagrams seen before the ACK. Zero on a miss means the reader
        /// is dead or the camera never heard us.
        nonisolated private let handshakeInbound = OSAllocatedUnfairLock(initialState: 0)
        /// `receiveMessage` has been armed on the current `conn`.
        private var receiveArmed = false
        /// `close()` is terminal. Handshake on this instance after disconnect
        /// inherited a half-dead UDP session.
        private var closed = false
        /// Camera still pushes the last GOP after Disconnect. Do not count or
        /// decode those 0x02 packets until `0x09/0xa8` has gone out.
        nonisolated private let videoGate = OSAllocatedUnfairLock(initialState: VideoGate())

        private struct VideoGate {
            var accepting = false
            var loggedDrop = false
        }

        /// Depacketize + video counters on the UDP queue. Main only hops complete AUs.
        nonisolated private let videoAssembler = SoftAPVideoAssembler()
        nonisolated private let ingressMetrics = OSAllocatedUnfairLock(initialState: FeedIngressMetrics())
        /// Session/socket snapshot for the 40 Hz ACK pump (UDP queue, not MainActor).
        nonisolated private let wire = OSAllocatedUnfairLock(initialState: WireState())
        /// Last pid `0x38` GET write / reply. Keepalive BLE fallback reads these; UDP queue stamps reply.
        public private(set) var lastSelfieFlipSendAt: Date?
        nonisolated private let lastSelfieFlipReply = OSAllocatedUnfairLock(
            initialState: Date?.none)
        public var lastSelfieFlipReplyAt: Date? { lastSelfieFlipReply.withLock { $0 } }
        private var lastStatusDate: Date?
        /// Last tracked SET / GET on the datalink. Any SET can pause HEVC for a
        /// moment; the watchdog holds `FeedWatchdog.cameraSetGrace` after it.
        private var lastCommandSendAt: Date?
        private var receiveErrors = 0
        nonisolated private let host: DjiAppleTransportHost
        nonisolated private let log: Logger
        /// Open-path steps go to the diagnostics journal too (it also writes os_log). A
        /// never-opened datalink used to leave the tester report silent for 50-80 s.
        nonisolated private func journal(_ text: String) { host.journal(text) }

        private struct NativeProgramRun {
            var token: UInt64
            var epoch: UInt64
            var engine: GimbalMoveEngine
            var zoom: GimbalProgramZoom?
            var timer: DispatchSourceTimer
            var lastTickAt: TimeInterval
            var logsAllTargets: Bool
            var finalTarget: GimbalWaypoint?
            var lastProgressAt: TimeInterval = -.infinity
            var pausedAt: TimeInterval?
            var pauseAnchor: GimbalWaypoint?
            var pauseStableSince: TimeInterval?
            var onProgress: @MainActor @Sendable (UInt64, GimbalMoveEngine, GimbalWaypoint) -> Void
        }

        private struct WireState {
            var sessionId: UInt16 = 0
            var baseSeq: UInt16 = 0
            var conn: NWConnection?
            var dumlSeq: UInt16 = 0xA000
            var cmdCounter: UInt8 = 0
            var udpSeq: UInt16 = 0
            var lastFlipGetAt: TimeInterval = 0
            var liveAccepting = false
            var mediaBrowsing = false
            var ackedDataCursor: UInt16 = 0
            var sawAckedData = false
            var extraCursor: UInt16 = 0
            var sawExtra = false
            var lastAckedDataLogAt: TimeInterval = 0
            var gimbalAxis0: UInt16 = GimbalStick.center
            var gimbalAxis1: UInt16 = GimbalStick.center
            var nativeTargetStream = GimbalNativeTargetStream()
            var nativeProgram: NativeProgramRun?
            var nativeProgramEpoch: UInt64 = 0
            var nativeProgramPose: GimbalWaypoint?
            var nativeProgramPoseAt: TimeInterval?
            var nativeZoomFeedback: [String: (frame: Duml.Frame, receivedAt: TimeInterval)] = [:]
            var nativeZoomSentAt: TimeInterval?
            var gimbalStickHeld = false
            var gimbalSendRest = false
            var lastGimbalStickAt: TimeInterval = 0
            var totalACKs = 0
            /// Last UDP write the stack rejected on the current socket. Diagnostic only.
            var lastSendErrorAt: Date?
            var lastSendErrorCode: Int?
            var ackTiming = DeliveryCadence(startedAt: ProcessInfo.processInfo.systemUptime)
            var lastDeliveryLogAt = ProcessInfo.processInfo.systemUptime
            var stickWrites = 0
            var nativeWrites = 0
        }

        /// Called (on the main actor) for every DUML frame the camera pushes.
        /// Status, control ACKs, and media-list chunks (`0x00/0x27`) all arrive here.
        public var onStatusFrame: ((Duml.Frame) -> Void)?
        /// Query authority is captured on the native receive queue, before the Main hop.
        public nonisolated let mediaIngress = DjiAppleMediaIngressSlot()
        public var onMediaFrame: ((Duml.Frame, DjiAppleMediaIngress?) -> Void)?
        /// Called (on the main actor) with each complete HEVC access unit (DJI marker already stripped).
        public var onAccessUnit: (([UInt8]) -> Void)?
        public var onVideoDiscontinuity: (() -> Void)?

        /// Snapshot of video-pipeline counters. Safe to read from the main actor for the HUD.
        public var videoPackets: Int { videoAssembler.snapshot().packets }
        public var incidentACKs: Int { wire.withLock { $0.totalACKs } }
        public var lastSendError: (at: Date, code: Int)? {
            wire.withLock { w in w.lastSendErrorAt.map { ($0, w.lastSendErrorCode ?? 0) } }
        }
        public var incidentQueue: DjiAppleQueueObservation { videoAssembler.incidentQueue }
        /// Before video admission/assembly; no payload or endpoint address is retained.
        public var incidentIngress: FeedIncidentIngress {
            let accepting = videoGate.withLock { $0.accepting }
            return ingressMetrics.withLock {
                $0.snapshot(now: ProcessInfo.processInfo.systemUptime, videoGateOpen: accepting)
            }
        }
        public var droppedIncomplete: Int { videoAssembler.snapshot().dropped }
        public var receiveErrorCount: Int { receiveErrors }
        public var lastVideoPacketAt: Date? { videoAssembler.snapshot().lastPacket }
        public var lastAccessUnitAt: Date? { videoAssembler.snapshot().lastAU }
        public var accessUnits: Int { videoAssembler.snapshot().accessUnits }
        public var lastStatusAt: Date? { lastStatusDate }
        public var isTcpPokeReady: Bool {
            guard let pokeConn else { return false }
            if case .ready = pokeConn.state { return true }
            return false
        }
        /// Last command `send` completion. `nil` until Network.framework reports.
        public var lastWriteLanded: Bool? { lastCommandWriteLanded }
        public var isFlowHealthy: Bool { writeHealthy && isConnectionReady }
        public var isRebuilding: Bool { rebuilding }
        public var isClosed: Bool { closed }
        public func setMediaBrowsing(_ browsing: Bool) {
            wire.withLock { $0.mediaBrowsing = browsing }
        }
        public var secondsSinceLastRebuild: TimeInterval? {
            lastRebuildAt.map { Date().timeIntervalSince($0) }
        }
        public var secondsSinceNativeZoomSet: TimeInterval? {
            wire.withLock { $0.nativeZoomSentAt }.map { ProcessInfo.processInfo.systemUptime - $0 }
        }
        public var secondsSinceLastCommand: TimeInterval? {
            [lastCommandSendAt.map { Date().timeIntervalSince($0) }, secondsSinceNativeZoomSet]
                .compactMap { $0 }.min()
        }
        public var needsRebuild: Bool {
            if rebuilding { return false }
            return CameraSoftAP.shouldRebuildFlow(flowHealth)
        }

        private var isConnectionReady: Bool {
            guard let conn else { return false }
            if case .ready = conn.state { return true }
            return false
        }

        private var flowHealth: CameraSoftAP.DatalinkFlowHealth {
            if !pathReady { return .pathLost }
            guard let conn else { return .notReady }
            switch conn.state {
            case .ready: return writeHealthy ? .ready : .writeRejected
            case .cancelled: return .cancelled
            case .failed, .waiting: return .notReady
            default: return .notReady
            }
        }

        public init(
            port: UInt16, tcpPoke: Bool, pairingToken: String, stationHost: String? = nil,
            stationHotspot: Bool = false, subscriptionKeys: [String] = Commands.subscriptionKeys,
            host: DjiAppleTransportHost = .init()
        ) {
            self.host = host
            self.log = Logger(subsystem: host.logSubsystem, category: "datalink")
            self.subscriptionKeys = subscriptionKeys
            self.stationHost = stationHost
            self.stationHotspot = stationHotspot
            self.port = port
            self.tcpPoke = tcpPoke
            self.pairingToken = pairingToken
            q.setSpecific(key: Self.qKey, value: 1)
        }

        private var handshakeAcked: Bool {
            handshakeAdmission.withLock { $0.initialCommandSequence != nil }
        }

        /// Bring the datalink up: poke, handshake, register, subscribe. Throws if the socket never opens
        /// or the handshake is never answered (which is how "wrong UDP port for this model" surfaces).
        ///
        /// `afterHandshake` runs after register + subscribe - send `0x09/0xa8`
        /// there. Enable before subscribe is ignored on first boot.
        public func open(
            identityOnly: Bool = false, afterHandshake: (@MainActor () async -> Void)? = nil
        )
            async throws
        {
            try throwIfClosed()
            // Sockets created before 192.168.2.x exist bind to the old Wi-Fi, then
            // RST when the camera AP finishes associating (first-connect black feed).
            try await waitForCameraPath()
            try throwIfClosed()
            try await refreshCameraPath()
            try throwIfClosed()
            try await ensurePoke()
            try throwIfClosed()

            let stationDeadline = Date().addingTimeInterval(15)
            var rebinds = 0
            var sendRounds = 0
            var keepBind = false
            while true {
                try throwIfClosed()
                if stationHost != nil && Date() >= stationDeadline {
                    throw DatalinkError.noHandshake
                }
                if !keepBind {
                    Self.prepareHandshakeBind(
                        existingSocket: conn, discard: discardUDP, reset: resetHandshakeSession)
                    try await openUDP()
                    try throwIfClosed()
                    syncWire()
                    startPathWatch()
                }
                keepBind = false

                let sends = CameraSoftAP.handshakeSendsPerBind
                for send in 1...sends {
                    try throwIfClosed()
                    if handshakeAcked { break }
                    if !CameraSoftAP.canSendHandshake(
                        receiveArmed: receiveArmed, connectionReady: isConnectionReady
                    ) {
                        journal(
                            "datalink: handshake UDP not ready reader=\(self.receiveArmed), will rebind"
                        )
                        break
                    }
                    let pkt = DumlTransport.handshakeDatagram(
                        sessionId: sessionId, seq: udpSeq, baseSeq: baseSeq)
                    write(pkt)
                    udpSeq = udpSeq &+ 8
                    if send == 1 {
                        journal("datalink: handshake send 1/\(sends) bind=\(rebinds + 1)")
                    } else {
                        log.info("datalink: handshake send \(send)/\(sends)")
                    }
                    try await waitForHandshakeAck()
                    if handshakeAcked { break }
                }
                if handshakeAcked {
                    journal("datalink: handshake acked session=\(self.sessionId)")
                    host.localNetworkEvidence(.allowed, "datalink handshake")
                    // Protocol: register + subscribe, then 0x09/0xa8. Enable before
                    // subscribe is ignored; first-boot then piled mid-GOP P-frames
                    // and first-picture tore UDP during the IDR gap.
                    guard let initial = handshakeAdmission.withLock({ $0.initialCommandSequence })
                    else {
                        throw DatalinkError.noHandshake
                    }
                    udpSeq = initial
                    primeWireSeqs()
                    sendAck()
                    if !identityOnly { completeRegistration() }
                    startAckPump()
                    // Mimo 20260828: HEVC 17 ms after DHCP, 0xa8 at +3 s. Arm ingest
                    // on handshake ack. Decoder still latches VPS only.
                    armLiveVideo()
                    // Disconnect can land on this await. Publishing LIVE here after
                    // `close()` is why in-app reconnect sat on Waiting for live view
                    // until process death.
                    try throwIfClosed()
                    if let afterHandshake { await afterHandshake() }
                    try throwIfClosed()
                    armLiveVideo()
                    return
                }

                let inbound = handshakeInbound.withLock { $0 }
                let evidence = handshakeAdmission.withLock {
                    ($0.acknowledged, $0.hasInitialWindow)
                }
                journal(
                    "datalink: negotiation miss ack=\(evidence.0) window=\(evidence.1) inbound=\(inbound) path=\(self.pathReady)"
                )
                let pathReady = self.pathReady
                sendRounds += 1
                switch CameraSoftAP.handshakeTimeoutStep(
                    pathReady: pathReady, rebindsUsed: rebinds, inboundDatagrams: inbound,
                    sendRoundsUsed: sendRounds)
                {
                case .keepSocket:
                    journal("datalink: handshake miss inbound=\(inbound), keep UDP, retry sends")
                    keepBind = true
                case .rebindUDP:
                    rebinds += 1
                    journal(
                        "datalink: handshake miss inbound=\(inbound), SoftAP up, rebind UDP (\(rebinds)/\(CameraSoftAP.handshakeRebindLimit))"
                    )
                case .fail:
                    journal(
                        "datalink: handshake never acked inbound=\(inbound) rounds=\(sendRounds)")
                    throw DatalinkError.noHandshake
                }
            }
        }

        /// pktType 0x00 can land in tens of ms; 350 ms is only the cap per send.
        private func waitForHandshakeAck() async throws {
            let poll = CameraSoftAP.handshakePollMilliseconds
            let cap = CameraSoftAP.handshakeSendIntervalMilliseconds
            var waited = 0
            while waited < cap {
                if handshakeAcked { return }
                try Task.checkCancellation()
                let slice = min(poll, cap - waited)
                try await Task.sleep(for: .milliseconds(slice))
                waited += slice
            }
        }

        /// Invalidate and drain the old receiver before clearing handshake evidence.
        /// Otherwise an already armed old callback can acknowledge the new session.
        public static func prepareHandshakeBind(
            existingSocket: NWConnection?, discard: () -> Void, reset: () -> Void
        ) {
            if existingSocket != nil { discard() }
            reset()
        }

        private func resetHandshakeSession() {
            sessionId = UInt16.random(in: 0x1000...0xFFFE)
            baseSeq = UInt16.random(in: 0x1000...0xF000) & 0xFFF8  // 8-aligned; fresh per connect
            udpSeq = 0
            dumlSeq = 0xA000
            cmdCounter = 0
            let handshakeEpoch = udpGeneration
            handshakeAdmission.withLock { $0.reset(epoch: handshakeEpoch) }
            handshakeInbound.withLock { $0 = 0 }
            videoGate.withLock { $0 = VideoGate() }
            videoAssembler.reset()
            lastStatusDate = nil
            receiveErrors = 0
            writeHealthy = true
            lastCommandWriteLanded = nil
            lastSelfieFlipSendAt = nil
            lastSelfieFlipReply.withLock { $0 = nil }
            primeWireSeqs()
        }

        /// Keep an already-ready 7001 poke. A second connect after a miss used to
        /// open another TCP and RST the one the camera still had.
        private func ensurePoke() async throws {
            guard tcpPoke else {
                journal("datalink: TCP 7001 poke skipped (model)")
                return
            }
            if isTcpPokeReady {
                journal("datalink: TCP 7001 poke already ready")
                return
            }
            pokeConn?.cancel()
            pokeConn = nil
            do {
                try await poke7001()
                journal("datalink: TCP 7001 poke ready")
            } catch is CancellationError {
                throw CancellationError()
            } catch DatalinkError.localNetworkDenied {
                throw DatalinkError.localNetworkDenied
            } catch {
                journal(
                    "datalink: TCP 7001 poke failed (\(error.localizedDescription)), trying UDP")
            }
        }

        /// Re-assert app-presence + ack; call ~1 Hz to hold the session (and playback) open.
        public func keepalive() {
            if closed || rebuilding || !handshakeAcked { return }
            sendDuml(Commands.appPresenceFrame(seq: 0))
            sendAck()
        }

        /// The camera stops video ~10 s after the last registration while telemetry
        /// continues, and ignores `0x09/0xa8` until it sees one again. Re-registering
        /// on the same socket restarted video with no new handshake (Pocket 4 Pro,
        /// 2026-09-22); the field repair used to spend a 5-16 s endpoint rebuild.
        public func reRegister() {
            if closed || rebuilding || !handshakeAcked { return }
            sendDuml(Commands.appDeviceInfo(seq: 0))
            sendDuml(Commands.appPresenceFrame(seq: 0))
            sendAck()
        }

        public func enterPlayback() { sendDuml(Commands.enterPlayback(seq: 0)) }
        public func exitPlayback() { sendDuml(Commands.exitPlayback(seq: 0)) }

        /// Send the live-view enable (`0x09/0xa8`) on **UDP 9004** only.
        /// Never writes TCP 7001 - a second enable on a dying UDP flow RST'd the poke.
        public func startLiveView(receiver: UInt8 = Commands.liveViewEnableReceiverPocket) {
            if closed { return }
            let seq = sendDuml(
                Commands.liveViewEnable(seq: 0, receiver: receiver), trackCommand: false)
            log.info(
                "datalink: sent 0x09/0xa8 rcv=0x\(String(receiver, radix: 16), privacy: .public) seq=\(seq, privacy: .public) ready=\(self.isConnectionReady ? 1 : 0) videoPkts=\(self.videoPackets, privacy: .public)"
            )
            // Re-arm on recover enable after rebuildUDP (physical #148).
            armLiveVideo()
        }

        /// Accept pktType 0x02 after UDP handshake. First arm drops leftover GOP
        /// counters. Re-arm after UDP rebuild / enable only raises the gate.
        public func armLiveVideo() {
            if closed { return }
            let first = videoGate.withLock { !$0.accepting }
            if first {
                videoAssembler.resetDepacketizerKeepingCursor()
            }
            videoGate.withLock {
                $0.accepting = true
                $0.loggedDrop = false
            }
            wire.withLock { $0.liveAccepting = true }
        }

        /// App → camera DUML on the live datalink (`0x02/*` record, mode, param SET).
        /// Returns the `dumlSeq` stamped on the wire (the builder's `seq` is a placeholder).
        @discardableResult
        public func send(_ frame: Duml.Frame) -> UInt16 {
            guard !closed, !rebuilding, handshakeAcked else {
                lastCommandWriteLanded = false
                return 0
            }
            lastCommandWriteLanded = nil
            lastCommandSendAt = Date()
            return sendDuml(frame, trackCommand: true)
        }

        /// Supplied work reports actual local dispatch, preserving zero as a valid stamped sequence.
        public func send(_ frame: Duml.Frame, admission: DJICommandAdmission)
            -> DjiAppleCommandWrite
        {
            guard admission.admits(commandOwner), !closed, !rebuilding, handshakeAcked else {
                return .skipped
            }
            var result: DjiAppleCommandWrite = .skipped
            onUDPQueueSync {
                result = self.sendDumlOnQueue(
                    frame, trackCommand: true, suppliedAdmission: admission)
            }
            if case .queued = result {
                lastCommandWriteLanded = nil
                lastCommandSendAt = Date()
            }
            return result
        }

        /// GET polls (Selfie Flip). Must not latch command-write health or SET timeouts.
        @discardableResult
        public func sendUntracked(_ frame: Duml.Frame) -> UInt16 {
            guard !closed, !rebuilding, handshakeAcked else { return 0 }
            return sendDuml(frame, trackCommand: false)
        }

        /// The same untracked path with explicit first-send admission; it never changes SET health.
        public func sendUntracked(_ frame: Duml.Frame, admission: DJICommandAdmission)
            -> DjiAppleCommandWrite
        {
            guard admission.admits(commandOwner), !closed, !rebuilding, handshakeAcked else {
                return .skipped
            }
            var result: DjiAppleCommandWrite = .skipped
            onUDPQueueSync {
                result = self.sendDumlOnQueue(
                    frame, trackCommand: false, suppliedAdmission: admission)
            }
            return result
        }

        /// The take's engine and feedback clock live on the UDP queue, independent of UI work.
        public func startNativeProgram(
            program: GimbalProgram, token: UInt64, zoom: GimbalProgramZoom? = nil,
            onProgress:
                @escaping @MainActor @Sendable (UInt64, GimbalMoveEngine, GimbalWaypoint) -> Void
        ) -> Bool {
            guard !closed else { return false }
            var started = false
            onUDPQueueSync {
                let now = ProcessInfo.processInfo.systemUptime
                var engine = GimbalMoveEngine()
                let initialZoom = zoom
                let prepared = wire.withLock {
                    w -> (pose: GimbalWaypoint?, zoom: GimbalProgramZoom?) in
                    var zoom = initialZoom
                    for sample in w.nativeZoomFeedback.values.sorted(by: {
                        $0.receivedAt < $1.receivedAt
                    }) {
                        zoom?.observe(sample.frame, at: sample.receivedAt)
                    }
                    guard let conn = w.conn, case .ready = conn.state,
                        var pose = w.nativeProgramPose, let receivedAt = w.nativeProgramPoseAt,
                        now >= receivedAt, now - receivedAt <= 0.3, zoom?.failureReason == nil
                    else { return (nil, zoom) }
                    if let factor = zoom?.liveZoom { pose.zoom = factor }
                    w.nativeProgramPose = pose
                    return (pose, zoom)
                }
                let zoom = prepared.zoom
                guard let pose = prepared.pose, engine.start(program: program, live: pose) else {
                    return
                }
                let preparedEngine = engine
                _ = cancelNativeProgramOnQueue()
                let (headWasActive, needsRest) = wire.withLock { w in
                    let active = w.nativeTargetStream.cancel()
                    let rest = w.gimbalStickHeld || w.gimbalSendRest
                    w.gimbalStickHeld = false
                    w.gimbalSendRest = false
                    w.gimbalAxis0 = GimbalStick.center
                    w.gimbalAxis1 = GimbalStick.center
                    return (active, rest)
                }
                if headWasActive { _ = sendNativeProgramFrame(Commands.gimbalTimedStop()) }
                if needsRest {
                    _ = sendNativeProgramFrame(
                        Commands.gimbalStick(axis0: GimbalStick.center, axis1: GimbalStick.center))
                }
                let timer = DispatchSource.makeTimerSource(queue: q)
                let epoch = wire.withLock { w in
                    w.nativeProgramEpoch &+= 1
                    w.nativeProgram = NativeProgramRun(
                        token: token, epoch: w.nativeProgramEpoch, engine: preparedEngine,
                        zoom: zoom,
                        timer: timer, lastTickAt: now,
                        logsAllTargets: GimbalProgramCurve(program: program) == nil,
                        finalTarget: program.c ?? program.b, onProgress: onProgress)
                    return w.nativeProgramEpoch
                }
                timer.setEventHandler { @Sendable [weak self] in
                    self?.tickNativeProgram(epoch: epoch)
                }
                timer.schedule(
                    deadline: .now() + engine.nextWakeInterval, repeating: .never,
                    leeway: .milliseconds(1))
                timer.resume()
                started = true
            }
            return started
        }

        @discardableResult
        public func pauseNativeProgram(token: UInt64) -> Bool {
            guard !closed else { return false }
            var paused = false
            onUDPQueueSync {
                let snapshot = wire.withLock { w -> (NativeProgramRun, GimbalWaypoint)? in
                    guard var run = w.nativeProgram, run.token == token, !run.engine.isPaused,
                        let pose = w.nativeProgramPose, run.engine.pause(live: pose)
                    else { return nil }
                    w.nativeProgramEpoch &+= 1
                    run.epoch = w.nativeProgramEpoch
                    run.pauseAnchor = nil
                    run.pauseStableSince = nil
                    run.pausedAt = ProcessInfo.processInfo.systemUptime
                    w.nativeProgram = run
                    return (run, pose)
                }
                guard let (run, pose) = snapshot else { return }
                run.timer.cancel()
                if run.zoom?.hasSentTarget == true {
                    _ = sendNativeProgramFrame(Commands.setZoomStop())
                }
                guard sendNativeProgramFrame(Commands.gimbalTimedStop()) else {
                    _ = cancelNativeProgramOnQueue(token: token, reportInterruption: true)
                    return
                }
                wire.withLock {
                    let now = ProcessInfo.processInfo.systemUptime
                    $0.nativeProgram?.pausedAt = now
                    $0.nativeProgram?.zoom?.notePause(at: now)
                }
                publishNativeProgram(run, pose: pose)
                paused = true
            }
            return paused
        }

        @discardableResult
        public func resumeNativeProgram(token: UInt64) -> Bool {
            guard !closed else { return false }
            var resumed = false
            onUDPQueueSync {
                let now = ProcessInfo.processInfo.systemUptime
                let snapshot = wire.withLock { w -> (NativeProgramRun, GimbalWaypoint)? in
                    guard var run = w.nativeProgram, run.token == token, run.engine.isPaused,
                        let conn = w.conn, case .ready = conn.state,
                        let pose = w.nativeProgramPose, let receivedAt = w.nativeProgramPoseAt,
                        now >= receivedAt, now - receivedAt <= 0.3,
                        let stableSince = run.pauseStableSince,
                        receivedAt - stableSince >= 0.2 - 1e-9,
                        let anchor = run.pauseAnchor,
                        GimbalMoveEngine.angularDistance(anchor, pose) <= 0.100001,
                        run.zoom?.canResume(at: now) ?? true,
                        run.engine.resume(live: pose)
                    else { return nil }
                    w.nativeProgramEpoch &+= 1
                    run.epoch = w.nativeProgramEpoch
                    run.timer = DispatchSource.makeTimerSource(queue: q)
                    run.lastTickAt = now - 0.000001
                    run.zoom?.resetDispatch()
                    run.lastProgressAt = -.infinity
                    run.pausedAt = nil
                    run.pauseAnchor = nil
                    run.pauseStableSince = nil
                    w.nativeProgram = run
                    return (run, pose)
                }
                guard let (run, _) = snapshot else { return }
                let epoch = run.epoch
                run.timer.setEventHandler { @Sendable [weak self] in
                    self?.tickNativeProgram(epoch: epoch)
                }
                // Balance the new source before the immediate tick either rearms or cancels it.
                run.timer.resume()
                tickNativeProgram(epoch: epoch)
                resumed = true
            }
            return resumed
        }

        @discardableResult
        public func cancelNativeProgram(token: UInt64) -> Bool {
            var canceled = false
            onUDPQueueSync { canceled = cancelNativeProgramOnQueue(token: token) }
            return canceled
        }

        /// Runs on q: invalidate queued timer handlers before placing STOP on the wire.
        @discardableResult
        nonisolated private func cancelNativeProgramOnQueue(
            token: UInt64? = nil, reportInterruption: Bool = false, reason: String? = nil
        ) -> Bool {
            let removed = wire.withLock { w -> (NativeProgramRun, GimbalWaypoint?)? in
                guard var run = w.nativeProgram, token == nil || run.token == token else {
                    return nil
                }
                w.nativeProgramEpoch &+= 1
                run.epoch = w.nativeProgramEpoch
                w.nativeProgram = nil
                return (run, w.nativeProgramPose)
            }
            guard let removed else { return false }
            var run = removed.0
            let pose = removed.1
            run.timer.cancel()
            if let reason, let pose {
                _ = run.engine.interrupt(live: pose, reason: reason)
            } else if reportInterruption, let pose {
                _ = run.engine.tick(dt: .infinity, live: pose)
            }
            run.engine.cancel()
            if run.zoom?.hasSentTarget == true {
                _ = sendNativeProgramFrame(Commands.setZoomStop())
            }
            _ = sendNativeProgramFrame(Commands.gimbalTimedStop())
            if let pose { publishNativeProgram(run, pose: pose) }
            return true
        }

        nonisolated private func tickNativeProgram(epoch: UInt64) {
            let now = ProcessInfo.processInfo.systemUptime
            let step = wire.withLock {
                w -> (NativeProgramRun, GimbalWaypoint, GimbalMoveEngine.Output, Bool, Duml.Frame?)?
                in
                guard w.nativeProgramEpoch == epoch, var run = w.nativeProgram,
                    !run.engine.isPaused, let pose = w.nativeProgramPose
                else { return nil }
                let ready: Bool
                if let conn = w.conn, case .ready = conn.state {
                    ready = true
                } else {
                    ready = false
                }
                let dt = ready ? now - run.lastTickAt : .infinity
                run.lastTickAt = now
                let age = w.nativeProgramPoseAt.map { now - $0 } ?? .infinity
                if dt > 0.12 || age > 0.3 {
                    host.journal(
                        "gimbal-native: interrupted dt=\(dt) feedbackAge=\(age) ready=\(ready)")
                }
                var output: GimbalMoveEngine.Output
                if let reason = run.zoom?.nativeFailure(at: now) {
                    output = run.engine.interrupt(live: pose, reason: reason)
                } else if let step = run.engine.tick(dt: dt, live: pose, telemetryAge: age) {
                    output = step
                } else {
                    return nil
                }
                if run.zoom?.usesHighRateTargets == true, let demand = run.engine.nativeZoomDemand,
                    let reason = run.zoom?.nativeFailure(for: demand, at: now)
                {
                    output = run.engine.interrupt(live: pose, reason: reason)
                }
                var zoomFrame: Duml.Frame?
                if run.zoom?.usesHighRateTargets == true, let demand = run.engine.nativeZoomDemand {
                    let tracking: Bool
                    if case .track = demand.command { tracking = true } else { tracking = false }
                    if !tracking || run.zoom?.canSampleNativeTarget(at: now) == true {
                        _ = run.engine.consumeNativeZoomDemand()
                        zoomFrame = run.zoom?.nativeCommand(for: demand, at: now)?.frame
                    }
                } else if run.zoom?.canSample(at: now) == true,
                    let target = run.engine.consumeProgrammedZoomTarget(),
                    let lens = run.zoom?.lensTarget(for: target, at: now)
                {
                    zoomFrame = Commands.setZoomLens(lens)
                }
                let publish = output.finished || now - run.lastProgressAt >= 0.2
                if publish { run.lastProgressAt = now }
                w.nativeProgram = run
                return (run, pose, output, publish, zoomFrame)
            }
            guard let step else { return }
            var run = step.0
            let (pose, output, publish) = (step.1, step.2, step.3)
            if let target = output.target {
                guard GimbalMoveEngine.canSendNativeTarget(from: pose, to: target),
                    let frame = Commands.gimbalTimedTarget(
                        waypoint: target, duration: output.duration),
                    sendNativeProgramFrame(
                        frame,
                        logTarget: run.logsAllTargets || target == run.finalTarget ? target : nil,
                        duration: output.duration)
                else {
                    _ = cancelNativeProgramOnQueue(token: run.token, reportInterruption: true)
                    return
                }
            }
            if let zoomFrame = step.4, !sendNativeProgramFrame(zoomFrame) {
                _ = cancelNativeProgramOnQueue(token: run.token, reportInterruption: true)
                return
            }
            if output.finished {
                run.epoch = wire.withLock { w in
                    w.nativeProgramEpoch &+= 1
                    w.nativeProgram = nil
                    return w.nativeProgramEpoch
                }
                run.timer.cancel()
                if run.zoom?.hasSentTarget == true {
                    _ = sendNativeProgramFrame(Commands.setZoomStop())
                }
                if output.stop { _ = sendNativeProgramFrame(Commands.gimbalTimedStop()) }
            } else {
                let interval = min(
                    run.engine.nextWakeInterval,
                    run.zoom?.nextWakeInterval(at: now) ?? .infinity)
                let remaining =
                    run.lastTickAt + interval - ProcessInfo.processInfo.systemUptime
                run.timer.schedule(
                    deadline: .now() + max(0.000_001, remaining), repeating: .never,
                    leeway: .milliseconds(1))
            }
            if publish { publishNativeProgram(run, pose: pose) }
        }

        nonisolated private func publishNativeProgram(_ run: NativeProgramRun, pose: GimbalWaypoint)
        {
            let engine = run.engine
            let token = run.token
            let callback = run.onProgress
            let epoch = run.epoch
            Task { @MainActor [weak self] in
                guard self?.wire.withLock({ $0.nativeProgramEpoch == epoch }) == true else {
                    return
                }
                callback(token, engine, pose)
            }
        }

        /// q-only direct native write: no actor hop and no mailbox latency at a deadline.
        nonisolated private func sendNativeProgramFrame(
            _ frame: Duml.Frame, logTarget: GimbalWaypoint? = nil, duration: TimeInterval = 0
        ) -> Bool {
            let packet = wire.withLock { w -> (NWConnection, [UInt8], UInt16)? in
                guard let conn = w.conn, case .ready = conn.state else { return nil }
                var frame = frame
                frame.seq = w.dumlSeq
                w.dumlSeq &+= 1
                w.cmdCounter &+= 1
                let routing = DumlTransport.routingHeader(seq: w.udpSeq, cmdCounter: w.cmdCounter)
                let duml = Duml.encode(frame)
                let bytes =
                    DumlTransport.transportHeader(
                        pktType: 0x05,
                        payloadLen: routing.count + duml.count, sessionId: w.sessionId,
                        seq: w.udpSeq)
                    + routing + duml
                w.udpSeq &+= 8
                return (conn, bytes, frame.seq)
            }
            guard let (conn, bytes, seq) = packet, case .ready = conn.state else { return false }
            conn.send(content: Data(bytes), completion: .idempotent)
            if frame.cmdSet == 0x02, frame.cmdId == 0xB8 {
                wire.withLock { $0.nativeZoomSentAt = ProcessInfo.processInfo.systemUptime }
            }
            if let target = logTarget {
                let now = ProcessInfo.processInfo.systemUptime
                host.journal(
                    "gimbal-native: seq=\(seq) target=\(target.yawDeg),\(target.pitchDeg) nativePitch=\(target.nativePitchDeg ?? 0) duration=\(duration) monotonic=\(now)"
                )
            }
            return true
        }

        nonisolated private func noteNativeProgramPose(_ frames: [Duml.Frame]) {
            for frame in frames {
                let zoomKey = GimbalProgramZoom.feedbackKey(frame)
                let receivedAt = ProcessInfo.processInfo.systemUptime
                let zoomFailure = wire.withLock { w -> String? in
                    if let zoomKey {
                        w.nativeZoomFeedback[zoomKey] = (frame, receivedAt)
                        w.nativeProgram?.zoom?.observe(frame, at: receivedAt)
                    }
                    if let zoom = w.nativeProgram?.zoom?.liveZoom {
                        w.nativeProgramPose?.zoom = zoom
                    }
                    return w.nativeProgram?.zoom?.failureReason
                }
                if let zoomFailure { _ = cancelNativeProgramOnQueue(reason: zoomFailure) }
                guard frame.cmdSet == 0x04, frame.cmdId == 0x05,
                    GimbalStick.isAttitude(frame.payload)
                else { continue }
                guard
                    let reportedPose = GimbalWaypoint.from(
                        yawTenth: GimbalStick.yawTenthDeg(frame.payload),
                        pitchTenth: GimbalStick.pitchTenthDeg(frame.payload), zoom: 1,
                        nativePitchTenth: GimbalStick.nativePitchTenthDeg(frame.payload))
                else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                wire.withLock { w in
                    var pose = reportedPose
                    if let zoom = w.nativeProgram?.zoom?.liveZoom { pose.zoom = zoom }
                    if var run = w.nativeProgram, run.engine.isPaused,
                        let pausedAt = run.pausedAt, now > pausedAt
                    {
                        if let anchor = run.pauseAnchor, let previousAt = w.nativeProgramPoseAt,
                            now - previousAt <= 0.3,
                            GimbalMoveEngine.angularDistance(anchor, pose) <= 0.100001
                        {
                            // Keep the anchor fixed: accumulated drift must reset the settling window.
                        } else {
                            run.pauseAnchor = pose
                            run.pauseStableSince = now
                        }
                        w.nativeProgram = run
                    }
                    w.nativeProgramPose = pose
                    w.nativeProgramPoseAt = now
                }
            }
        }

        public func beginNativeTargets(token: UInt64) {
            onUDPQueueSync {
                _ = cancelNativeProgramOnQueue()
                wire.withLock { $0.nativeTargetStream.begin(token: token) }
            }
        }

        public func noteNativeTarget(_ frame: Duml.Frame, token: UInt64) -> Bool {
            guard !closed else { return false }
            return wire.withLock {
                $0.nativeTargetStream.submit(
                    frame, token: token, now: ProcessInfo.processInfo.systemUptime)
            }
        }

        /// Clear pending targets and finish the stop on the same queue before a
        /// manual/program command can take ownership. Stale owners do nothing.
        public func endNativeTargets(token: UInt64) {
            onUDPQueueSync {
                let stopped = wire.withLock { $0.nativeTargetStream.cancel(token: token) }
                if stopped, case .ready = conn?.state {
                    _ = sendDumlOnQueue(Commands.gimbalTimedStop(), trackCommand: false)
                }
            }
        }

        /// Latest `0x04/0x01` axes. The ACK pump emits them on the UDP queue.
        public func noteGimbalStick(axis0: UInt16, axis1: UInt16) {
            if closed { return }
            if axis0 == GimbalStick.center, axis1 == GimbalStick.center {
                restGimbalStick()
                return
            }
            onUDPQueueSync { _ = cancelNativeProgramOnQueue() }
            wire.withLock {
                $0.gimbalAxis0 = axis0
                $0.gimbalAxis1 = axis1
                $0.gimbalStickHeld = true
                $0.gimbalSendRest = false
            }
        }

        /// One center packet, then silence. Same UDP queue as ACK.
        public func restGimbalStick() {
            wire.withLock {
                $0.gimbalAxis0 = GimbalStick.center
                $0.gimbalAxis1 = GimbalStick.center
                $0.gimbalStickHeld = false
                $0.gimbalSendRest = true
            }
        }

        public func close() {
            commandOwner.retire()
            onVideoDiscontinuity = nil
            closed = true
            onAccessUnit = nil
            onStatusFrame = nil
            onMediaFrame = nil
            if let ticket = mediaIngress.capture() { mediaIngress.retire(ticket) }
            ackTimer?.cancel()
            ackTimer = nil
            wire.withLock {
                $0.gimbalStickHeld = false
                $0.gimbalSendRest = false
            }
            pathMonitor?.cancel()
            pathMonitor = nil
            // Bump `udpGeneration` so in-flight receive/write completions cannot
            // still ingest leftover GOP or mark the next session's socket dead.
            discardUDP()
            pokeConn?.cancel()
            pokeConn = nil
            videoAssembler.reset()
            videoGate.withLock { $0 = VideoGate() }
            writeHealthy = false
            syncWire()
        }

        private func throwIfClosed() throws {
            if closed || Task.isCancelled { throw CancellationError() }
        }

        /// A replacement ephemeral endpoint must negotiate a new camera session.
        /// Keeping only session/seq left the camera sending to the retired port.
        /// Reuse the normal handshake/register/subscribe chain and a ready TCP poke;
        /// the caller owns exactly one live enable after this succeeds.
        public func rebuildUDP(reason: String) async throws {
            if closed || rebuilding { return }
            rebuilding = true
            lastRebuildAt = Date()
            defer { rebuilding = false }
            host.journal("datalink: renegotiating UDP endpoint (\(reason))")
            // Do not send old-session ACKs while open resets its handshake state.
            ackTimer?.cancel()
            ackTimer = nil
            discardUDP()
            do {
                try await open()
                try throwIfClosed()
            } catch {
                ackTimer?.cancel()
                ackTimer = nil
                discardUDP()
                throw error
            }
            host.journal("datalink: UDP endpoint negotiated (\(reason))")
        }

        /// Drop the live UDP socket only. TCP 7001 stays up for the session.
        private func discardUDP() {
            commandOwner.replaceSource()
            udpGeneration += 1
            let handshakeEpoch = udpGeneration
            ingressMetrics.withLock { $0.reset(generation: handshakeEpoch) }
            handshakeAdmission.withLock { $0.reset(epoch: handshakeEpoch) }
            let generation = udpGeneration
            liveGeneration.withLock { $0 = generation }
            onUDPQueueSync {
                _ = cancelNativeProgramOnQueue(reportInterruption: true)
                wire.withLock {
                    $0.nativeProgramPose = nil
                    $0.nativeProgramPoseAt = nil
                    $0.nativeZoomFeedback = [:]
                }
            }
            receiveArmed = false
            let old = conn
            conn = nil
            wire.withLock {
                $0.conn = nil
                $0.nativeTargetStream.cancel()
            }
            old?.stateUpdateHandler = nil
            old?.cancel()
        }

        // ---- registration ----------------------------------------------------------------------------

        /// Called only after station discovery verifies the selected BLE camera identity.
        public func completeRegistration() {
            guard !closed else { return }
            register()
            subscribe()
        }

        private func register() {
            sendDuml(Commands.appDeviceInfo(seq: 0))
            sendAck()
            sendDuml(Commands.appPresenceFrame(seq: 0))
            sendAck()
            sendDuml(Commands.gimbalInit(seq: 0))
            sendAck()
        }

        private func subscribe() {
            var subId = Commands.firstSubId
            for key in subscriptionKeys {
                sendDuml(Commands.subscribe(key: key, subId: subId, seq: 0))
                subId += 1
            }
            sendAck()
        }

        // ---- send ------------------------------------------------------------------------------------

        private func sendRaw(pktType: UInt8, payload: [UInt8]) {
            let pkt =
                DumlTransport.transportHeader(
                    pktType: pktType, payloadLen: payload.count,
                    sessionId: sessionId, seq: udpSeq) + payload
            onUDPQueueSync { self.writeOnQueue(pkt) }
            udpSeq = udpSeq &+ 8
        }

        /// Wrap a DUML frame in the transport + routing headers and send it (pktType 0x05).
        /// Stamp + send run on the UDP queue so SET cannot overtake stick/ACK seq.
        @discardableResult
        private func sendDuml(_ frame: Duml.Frame, trackCommand: Bool = false) -> UInt16 {
            var seq: UInt16 = 0
            onUDPQueueSync { seq = self.sendDumlOnQueue(frame, trackCommand: trackCommand) }
            return seq
        }

        private func sendDumlOnQueue(_ frame: Duml.Frame, trackCommand: Bool) -> UInt16 {
            if case .queued(let sequence) = sendDumlOnQueue(
                frame, trackCommand: trackCommand, suppliedAdmission: nil)
            {
                return sequence
            }
            return 0
        }

        private func sendDumlOnQueue(
            _ frame: Duml.Frame, trackCommand: Bool, suppliedAdmission: DJICommandAdmission?
        ) -> DjiAppleCommandWrite {
            if let admission = suppliedAdmission, !admission.admits(commandOwner) {
                return .skipped
            }
            let ready: Bool
            switch conn?.state {
            case .ready: ready = true
            default: ready = false
            }
            guard
                CameraSoftAP.shouldStampCommandSeq(
                    hasConnection: conn != nil, connectionReady: ready, trackCommand: trackCommand)
            else {
                if trackCommand { lastCommandWriteLanded = false }
                return .skipped
            }
            let sid = sessionId
            let (stamped, pkt): (UInt16, [UInt8]) = wire.withLock { w in
                w.sessionId = sid
                w.cmdCounter &+= 1
                var f = frame
                f.seq = w.dumlSeq
                let seq = f.seq
                w.dumlSeq &+= 1
                let routing = DumlTransport.routingHeader(seq: w.udpSeq, cmdCounter: w.cmdCounter)
                let duml = Duml.encode(f)
                let out =
                    DumlTransport.transportHeader(
                        pktType: 0x05, payloadLen: routing.count + duml.count,
                        sessionId: w.sessionId, seq: w.udpSeq) + routing + duml
                w.udpSeq &+= 8
                return (seq, out)
            }
            dumlSeq = stamped &+ 1
            let dispatched = writeOnQueue(
                pkt, trackCommand: trackCommand, suppliedAdmission: suppliedAdmission)
            if dispatched, frame.cmdSet == 0, frame.cmdId == 0x88 {
                let generation = udpGeneration
                ingressMetrics.withLock {
                    $0.record(.registrationSubmission, at: ProcessInfo.processInfo.systemUptime,
                        generation: generation)
                }
            }
            // The original direct caller still receives its stamped sequence if its second SDK
            // readiness check skipped; only explicit supplied work reports a refusal instead.
            return suppliedAdmission != nil && !dispatched ? .skipped : .queued(stamped)
        }

        private func onUDPQueueSync(_ body: () -> Void) {
            if DispatchQueue.getSpecific(key: Self.qKey) != nil {
                body()
            } else {
                q.sync(execute: body)
            }
        }

        /// pktType-0x04 window ACK, sent with seq 0 (echoes the peer's cursor so it opens its downlink).
        private func sendAck() {
            peerCursor = videoAssembler.peerCursor(fallback: peerCursor)
            let (acked, extra) = wire.withLock {
                (
                    DumlTransport.AckWindows.windowCursor(
                        stored: $0.ackedDataCursor, seen: $0.sawAckedData, fallback: $0.baseSeq),
                    DumlTransport.AckWindows.windowCursor(
                        stored: $0.extraCursor, seen: $0.sawExtra, fallback: $0.baseSeq)
                )
            }
            let payload = DumlTransport.ackPayload(
                peerCursor: peerCursor, ackedDataCursor: acked, extraCursor: extra)
            let pkt =
                DumlTransport.transportHeader(
                    pktType: 0x04, payloadLen: payload.count,
                    sessionId: sessionId, seq: 0) + payload
            onUDPQueueSync { self.writeOnQueue(pkt) }
        }

        private func write(_ bytes: [UInt8], trackCommand: Bool = false) {
            onUDPQueueSync { self.writeOnQueue(bytes, trackCommand: trackCommand) }
        }

        /// Must run on `q`. ACK/stick/Flip already do; SET hops here.
        @discardableResult
        private func writeOnQueue(
            _ bytes: [UInt8], trackCommand: Bool = false,
            suppliedAdmission: DJICommandAdmission? = nil
        ) -> Bool {
            if let admission = suppliedAdmission, !admission.admits(commandOwner) { return false }
            if closed { return false }
            guard let conn else {
                writeHealthy = false
                if trackCommand { lastCommandWriteLanded = false }
                return false
            }
            switch conn.state {
            case .ready:
                break
            case .cancelled, .failed:
                if trackCommand { lastCommandWriteLanded = false }
                return false
            default:
                // Not-ready is not a dead flow. Tracked SETs skip - latching
                // writeHealthy here used to tear UDP during LUT / zoom. Enable is
                // untracked so 0xa8 still leaves on `.waiting`.
                if trackCommand {
                    lastCommandWriteLanded = false
                    log.info(
                        "datalink: skip write \u{2014} UDP not ready (\(String(describing: conn.state), privacy: .public))"
                    )
                    return false
                }
            }
            let generation = udpGeneration
            let socket = conn
            if let admission = suppliedAdmission, !admission.admits(commandOwner) { return false }
            if !trackCommand {
                conn.send(content: Data(bytes), completion: noteSendError(on: conn))
                return true
            }
            conn.send(
                content: Data(bytes),
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        Task { @MainActor in
                            guard
                                CameraSoftAP.shouldApplyStaleSocketHealth(
                                    isLiveConnection: self.udpGeneration == generation
                                        && self.conn === socket
                                )
                            else { return }
                            let wasHealthy = self.writeHealthy
                            self.writeHealthy = false
                            self.lastCommandWriteLanded = false
                            if wasHealthy {
                                self.log.info(
                                    "datalink: write rejected (\(error.localizedDescription, privacy: .public))"
                                )
                            }
                        }
                    } else {
                        Task { @MainActor in
                            guard self.udpGeneration == generation else { return }
                            self.lastCommandWriteLanded = true
                        }
                    }
                })
            return true
        }

        /// Mimo ACKs ~41 Hz (p50 24.4 ms) with cursor = latest video transport seq. 1 Hz is not enough
        /// to keep the camera's send window open once live view is flowing.
        /// Runs on the UDP queue - a MainActor Task per tick starved control ACKs.
        private func startAckPump() {
            if closed { return }
            ackTimer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
            t.setEventHandler { @Sendable [weak self] in
                self?.sendWindowAck()
                self?.tickSelfieFlipGET()
                self?.tickGimbalStick()
                self?.tickNativeTarget()
                self?.logDeliveryHealth()
            }
            t.resume()
            ackTimer = t
        }

        /// `.idempotent` hid every rejected ACK/enable, so a dead outbound flow
        /// looked like a healthy 40 Hz pump in field incidents.
        /// Cancelling a retired socket completes its queued sends with ECANCELED;
        /// only errors on the socket still in use are recorded.
        nonisolated private func noteSendError(on socket: NWConnection)
            -> NWConnection.SendCompletion
        {
            .contentProcessed { [wire] error in
                guard let error else { return }
                let code: Int
                switch error {
                case .posix(let posix): code = Int(posix.rawValue)
                case .dns(let dns): code = Int(dns)
                case .tls(let status): code = Int(status)
                default: code = -1
                }
                guard code != Int(POSIXErrorCode.ECANCELED.rawValue) else { return }
                wire.withLock {
                    guard $0.conn === socket else { return }
                    $0.lastSendErrorAt = Date()
                    $0.lastSendErrorCode = code
                }
            }
        }

        /// Window ACK from the UDP queue. Does not hop to MainActor.
        nonisolated private func sendWindowAck() {
            let cursor = videoAssembler.peerCursor(fallback: 0)
            let (session, _, conn, acked, extra) = wire.withLock {
                (
                    $0.sessionId, $0.baseSeq, $0.conn,
                    DumlTransport.AckWindows.windowCursor(
                        stored: $0.ackedDataCursor, seen: $0.sawAckedData, fallback: $0.baseSeq),
                    DumlTransport.AckWindows.windowCursor(
                        stored: $0.extraCursor, seen: $0.sawExtra, fallback: $0.baseSeq)
                )
            }
            guard let conn, case .ready = conn.state else { return }
            let payload = DumlTransport.ackPayload(
                peerCursor: cursor, ackedDataCursor: acked, extraCursor: extra)
            let pkt =
                DumlTransport.transportHeader(
                    pktType: 0x04, payloadLen: payload.count, sessionId: session, seq: 0
                ) + payload
            conn.send(content: Data(pkt), completion: noteSendError(on: conn))
            wire.withLock {
                $0.ackTiming.note(at: ProcessInfo.processInfo.systemUptime)
                $0.totalACKs += 1
            }
        }

        /// Submission cadence, receive cadence and UI delivery pressure are separate
        /// signals. ACK counts are local writes, not proof of camera receipt.
        nonisolated private func logDeliveryHealth() {
            let now = ProcessInfo.processInfo.systemUptime
            let sample = wire.withLock { w -> (DeliveryCadence.Window, Int, Int)? in
                guard now - w.lastDeliveryLogAt >= 1,
                    let ack = w.ackTiming.takeWindow(at: now)
                else { return nil }
                w.lastDeliveryLogAt = now
                let counts = (ack, w.stickWrites, w.nativeWrites)
                w.stickWrites = 0
                w.nativeWrites = 0
                return counts
            }
            guard let (ack, stick, native) = sample else { return }
            let delivery = videoAssembler.takeDeliveryWindow(at: now)
            host.journal(
                "feed: delivery ackHz=\(String(format: "%.1f", ack.hertz)) ackGapMs=\(Int(ack.maximumGapMilliseconds)) "
                    + "\(delivery) stickWrites=\(stick) nativeWrites=\(native)")
        }

        /// Mimo GETs pid `0x38` ~1 Hz on the live UDP socket - same conn as the
        /// window ACK. MainActor `sendUntracked` timestamped writes that never
        /// left, and overlapping Tasks flooded the camera so replies stopped.
        nonisolated private func tickSelfieFlipGET() {
            let now = CFAbsoluteTimeGetCurrent()
            enum Built {
                case wait
                case skip(String)
                case send(NWConnection, [UInt8], UInt16)
            }
            let built: Built = wire.withLock { w in
                guard now - w.lastFlipGetAt >= 1 else { return .wait }
                w.lastFlipGetAt = now
                guard w.liveAccepting else { return .skip("notLive") }
                guard !w.mediaBrowsing else { return .skip("media") }
                guard let conn = w.conn else { return .skip("noConn") }
                guard case .ready = conn.state else { return .skip("notReady") }
                w.cmdCounter &+= 1
                var f = Commands.getSelfieFlip()
                f.seq = w.dumlSeq
                let seq = f.seq
                w.dumlSeq &+= 1
                let routing = DumlTransport.routingHeader(seq: w.udpSeq, cmdCounter: w.cmdCounter)
                let duml = Duml.encode(f)
                let pkt =
                    DumlTransport.transportHeader(
                        pktType: 0x05, payloadLen: routing.count + duml.count,
                        sessionId: w.sessionId, seq: w.udpSeq) + routing + duml
                w.udpSeq &+= 8
                return .send(conn, pkt, seq)
            }
            switch built {
            case .wait:
                return
            case .skip(let why):
                host.journal("flip: skip udp \(why)")
            case .send(let conn, let pkt, let seq):
                switch conn.state {
                case .cancelled, .failed:
                    host.journal(
                        "flip: skip udp conn=\(String(describing: conn.state)) seq=\(seq)")
                    return
                default:
                    break
                }
                conn.send(content: Data(pkt), completion: .idempotent)
                host.journal("flip: send udp seq=\(seq) bytes=\(pkt.count)")
                Task { @MainActor [weak self] in
                    self?.lastSelfieFlipSendAt = Date()
                }
            }
        }

        nonisolated private func tickNativeTarget() {
            let packet: (NWConnection, [UInt8])? = wire.withLock { w in
                guard w.liveAccepting, !w.gimbalStickHeld, !w.gimbalSendRest,
                    let conn = w.conn
                else { return nil }
                let ready: Bool
                if case .ready = conn.state { ready = true } else { ready = false }
                guard
                    var frame = w.nativeTargetStream.next(
                        now: ProcessInfo.processInfo.systemUptime, connectionReady: ready)
                else { return nil }
                if frame.payload.count >= 8, frame.payload[6] == 0x05 {
                    let now = ProcessInfo.processInfo.systemUptime
                    let safe =
                        w.nativeProgramPose.map { live in
                            var target = live
                            target.yawDeg =
                                Double(GimbalStick.i16LE(frame.payload, at: 0) ?? 0) / 10
                            return w.nativeProgramPoseAt.map { now >= $0 && now - $0 <= 0.3 }
                                == true
                                && GimbalMoveEngine.canSendNativeTarget(from: live, to: target)
                        } ?? false
                    if !safe {
                        _ = w.nativeTargetStream.cancel()
                        frame = Commands.gimbalTimedStop()
                    }
                }
                w.cmdCounter &+= 1
                frame.seq = w.dumlSeq
                w.dumlSeq &+= 1
                let routing = DumlTransport.routingHeader(seq: w.udpSeq, cmdCounter: w.cmdCounter)
                let duml = Duml.encode(frame)
                let packet =
                    DumlTransport.transportHeader(
                        pktType: 0x05, payloadLen: routing.count + duml.count,
                        sessionId: w.sessionId, seq: w.udpSeq) + routing + duml
                w.udpSeq &+= 8
                return (conn, packet)
            }
            guard let (conn, bytes) = packet, case .ready = conn.state else { return }
            conn.send(content: Data(bytes), completion: .idempotent)
            wire.withLock { $0.nativeWrites += 1 }
        }

        /// Stick notify on the ACK queue. MainActor `sendUntracked` shared the
        /// socket with this pump and starved window ACK while AirPods IMU hopped
        /// main at ~100 Hz.
        nonisolated private func tickGimbalStick() {
            enum Built {
                case wait
                case send(NWConnection, [UInt8])
            }
            let now = CFAbsoluteTimeGetCurrent()
            let built: Built = wire.withLock { w in
                guard
                    GimbalStick.shouldEmit(
                        held: w.gimbalStickHeld, restPending: w.gimbalSendRest, now: now,
                        lastEmitted: w.lastGimbalStickAt)
                else { return .wait }
                guard
                    GimbalStick.shouldEmitOnSocket(
                        rest: w.gimbalSendRest, liveAccepting: w.liveAccepting,
                        hasConnection: w.conn != nil)
                else { return .wait }
                guard let conn = w.conn else { return .wait }
                guard case .ready = conn.state else { return .wait }
                let rest = w.gimbalSendRest
                let axis0 = rest ? GimbalStick.center : w.gimbalAxis0
                let axis1 = rest ? GimbalStick.center : w.gimbalAxis1
                w.lastGimbalStickAt = now
                if rest {
                    w.gimbalSendRest = false
                    w.gimbalStickHeld = false
                }
                w.cmdCounter &+= 1
                var f = Commands.gimbalStick(axis0: axis0, axis1: axis1)
                f.seq = w.dumlSeq
                w.dumlSeq &+= 1
                let routing = DumlTransport.routingHeader(seq: w.udpSeq, cmdCounter: w.cmdCounter)
                let duml = Duml.encode(f)
                let pkt =
                    DumlTransport.transportHeader(
                        pktType: 0x05, payloadLen: routing.count + duml.count,
                        sessionId: w.sessionId, seq: w.udpSeq) + routing + duml
                w.udpSeq &+= 8
                return .send(conn, pkt)
            }
            guard case .send(let conn, let pkt) = built else { return }
            switch conn.state {
            case .cancelled, .failed:
                return
            default:
                conn.send(content: Data(pkt), completion: .idempotent)
                wire.withLock { $0.stickWrites += 1 }
            }
        }

        public func noteSelfieFlipReply() {
            lastSelfieFlipReply.withLock { $0 = Date() }
        }

        private func syncWire() {
            let sid = sessionId
            let base = baseSeq
            let socket = conn
            wire.withLock {
                if $0.conn !== socket {
                    $0.lastSendErrorAt = nil
                    $0.lastSendErrorCode = nil
                }
                $0.sessionId = sid
                $0.baseSeq = base
                $0.conn = socket
            }
        }

        /// Handshake / reset only. Live `syncWire` must not rewind GET seqs.
        private func primeWireSeqs() {
            let sid = sessionId
            let base = baseSeq
            let socket = conn
            let ds = dumlSeq
            let cc = cmdCounter
            let us = udpSeq
            wire.withLock {
                $0.sessionId = sid
                $0.baseSeq = base
                if $0.conn !== socket {
                    $0.lastSendErrorAt = nil
                    $0.lastSendErrorCode = nil
                }
                $0.conn = socket
                $0.dumlSeq = ds
                $0.cmdCounter = cc
                $0.udpSeq = us
                $0.lastFlipGetAt = 0
                $0.ackedDataCursor = 0
                $0.sawAckedData = false
                $0.extraCursor = 0
                $0.sawExtra = false
                $0.lastAckedDataLogAt = 0
            }
        }

        /// Group 1 is shared by pktType `0x03` command replies and media downloads advertised
        /// through telemetry. Merge both forward-only; a delayed status frame cannot rewind it.
        nonisolated private func noteAckWindows(_ bytes: [UInt8]) {
            let next = wire.withLock { w -> (DumlTransport.AckWindows, Bool) in
                let prev = w.ackedDataCursor
                let advanced = DumlTransport.AckWindows(
                    ackedData: w.ackedDataCursor, extra: w.extraCursor,
                    hasAckedData: w.sawAckedData, hasExtra: w.sawExtra
                ).advancing(datagram: bytes)
                w.ackedDataCursor = advanced.ackedData
                w.sawAckedData = advanced.hasAckedData
                w.extraCursor = advanced.extra
                w.sawExtra = advanced.hasExtra
                let now = CFAbsoluteTimeGetCurrent()
                let logIt =
                    advanced.ackedData != prev
                    && (w.lastAckedDataLogAt == 0 || now - w.lastAckedDataLogAt >= 1)
                if logIt { w.lastAckedDataLogAt = now }
                return (advanced, logIt)
            }
            if next.1 {
                host.journal(
                    "flip: window 0x03 seq=\(next.0.ackedData) extra=\(next.0.extra)")
            }
        }

        // ---- receive ---------------------------------------------------------------------------------

        private func startReceiveLoop() {
            let host = host
            guard let conn else { return }
            // Capture the connection and re-arm from a nonisolated static so the next receiveMessage
            // is scheduled on `q` immediately. `startReceiveLoop()` is MainActor-isolated - calling
            // it from the UDP callback hopped to main and froze the feed when the UI was busy.
            let assembler = videoAssembler
            let handshake = handshakeAdmission
            let inbound = handshakeInbound
            let gate = videoGate
            let metrics = ingressMetrics
            let flipReplyAt = lastSelfieFlipReply
            let generation = udpGeneration
            let genLock = liveGeneration
            genLock.withLock { $0 = generation }
            let socket = conn
            receiveArmed = true
            log.info("datalink: UDP reader armed")
            Self.armReceive(
                conn, queue: q,
                onError: { [weak self] message in
                    let canceled = CameraSoftAP.isCanceledReceive(message)
                    if !canceled {
                        metrics.withLock {
                            $0.record(.receiveError, at: ProcessInfo.processInfo.systemUptime,
                                generation: generation)
                        }
                    }
                    let awaitingAck = !handshake.withLock { $0.acknowledged }
                    Task { @MainActor in
                        guard let self else { return }
                        let live = self.udpGeneration == generation && self.conn === socket
                        if awaitingAck {
                            self.log.info(
                                "datalink: handshake UDP recv error canceled=\(canceled) live=\(live) (\(message, privacy: .public))"
                            )
                        }
                        guard
                            CameraSoftAP.shouldCountReceiveError(
                                isLiveConnection: live, canceled: canceled)
                        else { return }
                        self.receiveErrors += 1
                        self.log.info(
                            "datalink: UDP receive error #\(self.receiveErrors, privacy: .public) (\(message, privacy: .public)) \u{2014} re-arm"
                        )
                    }
                },
                ingest: { [weak self] bytes in
                    guard genLock.withLock({ $0 }) == generation else { return }
                    let video = bytes.count > 6 && bytes[6] == 0x02
                    metrics.withLock {
                        $0.record(.datagram(video: video), at: ProcessInfo.processInfo.systemUptime,
                            generation: generation)
                    }
                    let awaitingAck = !handshake.withLock { $0.acknowledged }
                    if awaitingAck {
                        inbound.withLock { $0 += 1 }
                        let count = bytes.count
                        let pktType = count > 6 ? bytes[6] : 0xFF
                        Task { @MainActor [weak self] in
                            self?.log.info(
                                "datalink: handshake inbound bytes=\(count, privacy: .public) pktType=0x\(String(format: "%02x", pktType), privacy: .public)"
                            )
                        }
                    }
                    if DumlTransport.isHandshake(bytes) {
                        Task { @MainActor [weak self] in
                            self?.log.info("datalink: handshake reply pktType=0x00")
                        }
                    }
                    handshake.withLock { $0.receive(bytes, epoch: generation) }
                    self?.noteAckWindows(bytes)
                    if video {
                        let accept = gate.withLock { $0.accepting }
                        if !CameraSoftAP.shouldIngestLiveVideo(ingestArmed: accept) {
                            metrics.withLock {
                                $0.record(.videoGateDrop, at: ProcessInfo.processInfo.systemUptime,
                                    generation: generation)
                            }
                            let logDrop = gate.withLock { state -> Bool in
                                if state.loggedDrop { return false }
                                state.loggedDrop = true
                                return true
                            }
                            if logDrop {
                                let count = bytes.count
                                Task { @MainActor [weak self] in
                                    self?.log.info(
                                        "datalink: drop leftover video before ingest bytes=\(count, privacy: .public)"
                                    )
                                }
                            }
                            return
                        }
                        #if DEBUG
                            host.debugVideo?.sourceObserved(1, 0)
                            if host.debugVideo?.shouldDropPacket(
                                UInt64(DumlTransport.transportSeq(bytes) ?? 0)) == true
                            {
                                metrics.withLock {
                                    $0.record(.injectedVideoDrop, at: ProcessInfo.processInfo.systemUptime,
                                        generation: generation)
                                }
                                return
                            }
                            host.debugVideo?.sourceDelivered(1, 0)
                        #endif
                        let assembled = assembler.ingest(bytes)
                        #if DEBUG
                            if assembled.accessUnit != nil {
                                host.debugVideo?.sourceObserved(0, 1)
                            }
                        #endif
                        if assembled.firstPacket {
                            let count = bytes.count
                            Task { @MainActor [weak self] in
                                self?.log.info(
                                    "datalink: first video pktType=0x02 bytes=\(count, privacy: .public)"
                                )
                            }
                        }
                        if assembled.shouldHop {
                            Task(priority: .userInitiated) { @MainActor in
                                self?.flushPendingAccessUnits(generation: generation)
                            }
                        }
                        return
                    }
                    let pktType = bytes.count > 6 ? bytes[6] : 0xFF
                    let frames = DumlTransport.scanFrames(bytes)
                    self?.noteNativeProgramPose(frames)
                    for frame in frames where frame.cmdSet == 0x02 && frame.cmdId == 0x8E {
                        let pid: String
                        if let parsed = CameraParam.parseGetReply(frame.payload) {
                            pid = String(format: "0x%04X", parsed.pid)
                        } else if frame.payload.count >= 5 {
                            let raw =
                                UInt16(frame.payload[3]) | (UInt16(frame.payload[4]) << 8)
                            pid = String(format: "0x%04X?", raw)
                        } else {
                            pid = "\u{2014}"
                        }
                        host.journal(
                            "flip: udp 0x8E pkt=0x\(String(format: "%02x", pktType)) seq=\(frame.seq) flags=0x\(String(frame.flags, radix: 16)) pid=\(pid) payload=\(Duml.hex(frame.payload))"
                        )
                    }
                    let flipReply = frames.contains {
                        CameraParam.isSelfieFlipGetReply(
                            set: $0.cmdSet, cmd: $0.cmdId, payload: $0.payload)
                    }
                    if flipReply {
                        flipReplyAt.withLock { $0 = Date() }
                    }
                    // Main only needs DUML frames and the 34-byte telemetry cursor.
                    // Hand over the frames scanned here instead of rescanning on Main.
                    guard !frames.isEmpty || Self.carriesTelemetryCursor(bytes) else { return }
                    let mediaAdmission = self?.mediaIngress.capture()
                    Task(priority: .high) { @MainActor in
                        guard let self, !self.closed, self.udpGeneration == generation,
                            self.conn === socket
                        else { return }
                        self.ingest(bytes, frames: frames, mediaAdmission: mediaAdmission)
                    }
                }
            )
        }

        /// First-connect path updates used to stop `receiveMessage` on the first
        /// error - inbound video and command ACKs died while BLE stayed up.
        nonisolated private static func armReceive(
            _ conn: NWConnection,
            queue: DispatchQueue,
            onError: @escaping @Sendable (String) -> Void,
            ingest: @escaping @Sendable ([UInt8]) -> Void
        ) {
            conn.receiveMessage { data, _, _, error in
                // Re-arm BEFORE ingest. Ingest-first froze videoPkts at the first
                // burst (272, rxErr=0) so the enable-triggered IDR never arrived.
                if let error {
                    let canceled = CameraSoftAP.isCanceledReceive(error.localizedDescription)
                    onError(error.localizedDescription)
                    let live = Self.shouldRearmReceive(conn)
                    if CameraSoftAP.shouldRearmAfterError(
                        isLiveConnection: live, canceled: canceled)
                    {
                        queue.asyncAfter(deadline: .now() + .milliseconds(40)) {
                            guard Self.shouldRearmReceive(conn) else { return }
                            armReceive(conn, queue: queue, onError: onError, ingest: ingest)
                        }
                    }
                } else {
                    armReceive(conn, queue: queue, onError: onError, ingest: ingest)
                    if let data, !data.isEmpty { ingest([UInt8](data)) }
                }
            }
        }

        nonisolated private static func shouldRearmReceive(_ conn: NWConnection) -> Bool {
            switch conn.state {
            case .cancelled, .failed: false
            default: true
            }
        }

        nonisolated private static func carriesTelemetryCursor(_ datagram: [UInt8]) -> Bool {
            datagram.count == 34 && datagram[6] == 0x01
        }

        private func ingest(
            _ datagram: [UInt8], frames: [Duml.Frame],
            mediaAdmission: DjiAppleMediaIngress?
        ) {
            // 0x01 telemetry carries a cursor at [10:12]. Video (0x02) has no such field - Mimo echoes
            // the video packet's own transport seq (bytes 4-5) instead, 96% of ACKs in the capture.
            if Self.carriesTelemetryCursor(datagram) {
                let cursor = UInt16(datagram[10]) | (UInt16(datagram[11]) << 8)
                if videoAssembler.seedPeerCursorIfNeeded(cursor) {
                    peerCursor = cursor
                }
            }

            // Video is assembled on the UDP queue. A stray main-actor copy must not
            // double-count packets or hop the datagram again.
            if datagram.count > 20, datagram[6] == 0x02 {
                return
            }
            // Forward every DUML frame; the session applies CameraStatusDecoder to the ones it recognises.
            if !frames.isEmpty {
                lastStatusDate = Date()
                noteInboundTraffic()
            }
            for frame in frames {
                if CameraParam.isSelfieFlipGetReply(
                    set: frame.cmdSet, cmd: frame.cmdId, payload: frame.payload)
                {
                    lastSelfieFlipReply.withLock { $0 = Date() }
                }
                if frame.cmdSet == 0, frame.cmdId == 0x27 { onMediaFrame?(frame, mediaAdmission) }
                onStatusFrame?(frame)
            }
        }

        /// Receive is the live-socket signal. One command write reject must not
        /// keep the flow marked dead until the next keepalive rebuild.
        private func noteInboundTraffic() {
            guard !writeHealthy else { return }
            writeHealthy = true
            log.info("datalink: inbound restored write health")
        }

        /// Drain AUs assembled on the UDP queue. One hop per batch so a Task-per-AU
        /// cannot stall receive or preempt control ACKs.
        private func flushPendingAccessUnits(generation: Int) {
            guard !closed, udpGeneration == generation else { return }
            noteInboundTraffic()
            let batch = videoAssembler.takeDelivery()
            batch.deliver(
                onDiscontinuity: { self.onVideoDiscontinuity?() },
                onAccessUnit: { accessUnit in
                    #if DEBUG
                        host.debugVideo?.sourceDelivered(0, 1)
                    #endif
                    self.onAccessUnit?(accessUnit)
                })
            if videoAssembler.hasPending {
                Task(priority: .utility) { @MainActor [weak self] in
                    self?.flushPendingAccessUnits(generation: generation)
                }
            }
        }

        // ---- socket helpers --------------------------------------------------------------------------

        private func openUDP() async throws {
            let savedIP = cameraLocalIPv4
            let savedIF = cameraInterface
            var last: Error = DatalinkError.notReady
            let modes: [(String, String?, NWInterface?)] = [
                ("bound", savedIP, savedIF),
                ("interface", nil, savedIF),
                ("wifi-type", nil, nil),
            ]
            for (label, ip, iface) in modes {
                cameraLocalIPv4 = ip
                cameraInterface = iface
                do {
                    try await openUDPOnce(label: label)
                    cameraLocalIPv4 = savedIP
                    cameraInterface = savedIF
                    return
                } catch is CancellationError {
                    cameraLocalIPv4 = savedIP
                    cameraInterface = savedIF
                    throw CancellationError()
                } catch {
                    last = error
                    discardUDP()
                    journal("datalink: UDP \(label) failed (\(error.localizedDescription))")
                    if case DatalinkError.localNetworkDenied = error { break }
                }
            }
            cameraLocalIPv4 = savedIP
            cameraInterface = savedIF
            throw last
        }

        private func openUDPOnce(label: String) async throws {
            let params = wifiUDP()
            let host = remoteHost
            conn = NWConnection(
                host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
            journal(
                "datalink: UDP \(label) open port=\(self.port) if=\(self.cameraInterface?.name ?? "-") local=\(self.cameraLocalIPv4 ?? "-")"
            )
            try await start(conn!)
            startReceiveLoop()
            if let conn { installStateWatch(conn) }
        }

        private func waitForCameraPath(timeout: TimeInterval = 15) async throws {
            #if DEBUG
                if usesLoopbackForTesting { return }
            #endif
            if stationHost == nil {
                try await DjiAppleWiFiJoiner.waitUntilCameraPathReady(timeout: timeout, host: host)
            } else if !pathReady {
                throw DatalinkError.notReady
            }
        }

        private func refreshCameraPath() async throws {
            #if DEBUG
                if usesLoopbackForTesting { return }
            #endif
            if stationHost != nil {
                cameraLocalIPv4 = DjiAppleSharedWiFiPath.address(hotspot: stationHotspot)
                cameraInterface = nil
                guard cameraLocalIPv4 != nil else { throw DatalinkError.notReady }
                return
            }
            cameraLocalIPv4 = DjiAppleWiFiJoiner.cameraLocalIPv4()
            cameraInterface = await DjiAppleWiFiJoiner.resolveCameraInterface()
            #if !targetEnvironment(simulator)
                if cameraLocalIPv4 == nil {
                    journal(
                        "datalink: no 192.168.2.x (\(CameraSoftAP.describe(DjiAppleWiFiJoiner.interfaceAddresses())))"
                    )
                    throw DatalinkError.notReady
                }
            #endif
            journal(
                "datalink: camera path if=\(self.cameraInterface?.name ?? "unlisted") local=\(self.cameraLocalIPv4 ?? "-")"
            )
        }

        private func wifiUDP() -> NWParameters {
            cameraParameters(NWParameters.udp)
        }

        private func wifiTCP() -> NWParameters {
            cameraParameters(NWParameters.tcp)
        }

        /// Bind to the SoftAP IPv4 / interface. `requiredInterfaceType = .wifi` alone
        /// scopes the flow to `en0` (home Wi-Fi) and later writes fail.
        private func cameraParameters(_ p: NWParameters) -> NWParameters {
            #if DEBUG
                if usesLoopbackForTesting { return p }
            #endif
            p.prohibitedInterfaceTypes = [.cellular]
            p.allowLocalEndpointReuse = true
            var boundLocal = false
            #if !targetEnvironment(simulator)
                if let cameraLocalIPv4, let localPort = NWEndpoint.Port(rawValue: 0) {
                    p.requiredLocalEndpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(cameraLocalIPv4), port: localPort)
                    boundLocal = true
                }
            #endif
            if let cameraInterface {
                p.requiredInterface = cameraInterface
            } else if !boundLocal {
                p.requiredInterfaceType = .wifi
            }
            return p
        }

        private func startPathWatch() {
            pathMonitor?.cancel()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if !self.pathReady {
                        self.writeHealthy = false
                        self.log.info("datalink: camera 192.168.2.x left the path")
                    } else if !self.writeHealthy {
                        self.writeHealthy = true
                        self.log.info(
                            "datalink: camera 192.168.2.x returned \u{2014} write health restored")
                    }
                }
            }
            monitor.start(queue: q)
            pathMonitor = monitor
        }

        private func installStateWatch(_ c: NWConnection) {
            let generation = udpGeneration
            c.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    guard
                        CameraSoftAP.shouldApplyStaleSocketHealth(
                            isLiveConnection: self.udpGeneration == generation && self.conn === c
                        )
                    else { return }
                    switch state {
                    case .failed(let error):
                        self.writeHealthy = false
                        self.journal("datalink: UDP failed (\(error.localizedDescription))")
                    case .waiting(let error):
                        self.journal("datalink: UDP waiting (\(error.localizedDescription))")
                    case .cancelled:
                        self.writeHealthy = false
                    default:
                        break
                    }
                }
            }
        }

        private func start(_ c: NWConnection, timeout: TimeInterval = 5) async throws {
            do {
                try await startUntilReady(c, timeout: timeout)
            } catch {
                c.cancel()
                if case DatalinkError.localNetworkDenied = error {
                    host.localNetworkEvidence(.denied, "datalink")
                }
                throw error
            }
        }

        private func startUntilReady(_ c: NWConnection, timeout: TimeInterval) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let waiter = DjiAppleCallbackWaiter<Void>()
                waiter.install(cont)
                let finish: @Sendable (Result<Void, Error>) -> Void = { waiter.resolve($0) }
                let journal = host.journal
                // Local Network denial never fails the connection; it only waits. Name it at
                // the deadline instead of the generic "not ready" (TN3179).
                let waiting = OSAllocatedUnfairLock(initialState: (denied: false, logged: false))
                let label = Self.label(c)
                c.stateUpdateHandler = { [weak c] state in
                    switch state {
                    case .ready: finish(.success(()))
                    case .failed(let e): finish(.failure(e))
                    case .cancelled: finish(.failure(CancellationError()))
                    case .waiting(let e):
                        let isDenied = DjiAppleLocalNetwork.isDenied(e, path: c?.currentPath)
                        let first = waiting.withLock { seen in
                            let first = !seen.logged
                            seen = (denied: seen.denied || isDenied, logged: true)
                            return first
                        }
                        if first {
                            journal(
                                "datalink: \(label) waiting (\(e.debugDescription)) localNetworkDenied=\(isDenied)"
                            )
                        }
                    default: break
                    }
                }
                c.start(queue: q)
                q.asyncAfter(deadline: .now() + timeout) {
                    let denied =
                        waiting.withLock { $0.denied }
                        || DjiAppleLocalNetwork.isDenied(nil, path: c.currentPath)
                    finish(
                        .failure(denied ? DatalinkError.localNetworkDenied : DatalinkError.notReady)
                    )
                }
            }
        }

        nonisolated private static func label(_ c: NWConnection) -> String {
            if case .hostPort(_, let port) = c.endpoint, port == 7001 { return "TCP 7001" }
            return "UDP"
        }

        /// TCP-7001 "poke": write a SetPairingPIN frame to arm the UDP datalink. Mimo keeps this socket
        /// open for the session (camera pushes 0x21/0x06); closing it is what produced the tcp_output RST.
        /// Retry while the camera AP is still coming up - first connect used to ready-then-RST.
        private func poke7001() async throws {
            var last: Error = DatalinkError.notReady
            for attempt in 1...4 {
                try Task.checkCancellation()
                do {
                    try await poke7001Once()
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch DatalinkError.localNetworkDenied {
                    throw DatalinkError.localNetworkDenied
                } catch {
                    last = error
                    journal(
                        "datalink: TCP 7001 attempt \(attempt) failed (\(error.localizedDescription))"
                    )
                    pokeConn?.cancel()
                    pokeConn = nil
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
            throw last
        }

        private func poke7001Once() async throws {
            let tcp = NWConnection(
                host: NWEndpoint.Host(remoteHost), port: 7001, using: wifiTCP())
            pokeConn = tcp
            try await start(tcp, timeout: 2)
            tcp.send(
                content: Data(Duml.encode(Commands.setPairingPin(pin: pairingToken))),
                completion: .idempotent)
            try await Task.sleep(for: .milliseconds(400))
            switch tcp.state {
            case .ready:
                Self.drain(tcp)
                return
            case .failed(let e): throw e
            default: throw DatalinkError.notReady
            }
        }

        /// The camera writes 0x21/0x06 frames to 7001 about 3 times a second for
        /// the whole session. Mimo reads them; leaving them unread fills the
        /// receive window on long takes. The content is not used.
        nonisolated private static func drain(_ tcp: NWConnection) {
            tcp.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                _, _, complete, error in
                guard !complete, error == nil else { return }
                drain(tcp)
            }
        }

        public enum DatalinkError: LocalizedError {
            case noHandshake
            case notReady
            case localNetworkDenied
            public var errorDescription: String? {
                switch self {
                case .noHandshake: "camera never answered the datalink handshake"
                case .notReady: "camera Wi-Fi path was not ready for the datalink"
                case .localNetworkDenied:
                    "Local Network access is denied. Enable Local Network access in Settings, then try again."
                }
            }
        }
    }

#endif
