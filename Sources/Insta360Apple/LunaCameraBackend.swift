import CryptoKit
import Foundation
import Insta360Protocol
import OpenCineCore
import OpenCineMedia

/// Insta360 Luna adapter: BLE consent + encrypted Wi-Fi credential bootstrap, then
/// plaintext UCD2 on TCP 6666 for control, status and HEVC preview.
///
/// ISO, shutter, white balance and record go through `session` (OpenCineCore), which owns
/// their requests and reported state. Other controls still use `send(_:)` with `LunaProtocol`
/// encoders and the typed `on…` callbacks. Wire bytes live in `Insta360Protocol`.
@MainActor
public final class LunaCameraBackend: CameraBackend {
    public let capabilities: CameraCapabilities = [
        .liveVideo, .recording, .exposure, .captureFormat, .whiteBalance, .focus, .zoom, .gimbal,
        .cameraMedia,
    ]
    public var eventHandler: ((CameraBackendEvent) -> Void)?
    /// Typed Luna status. Fired on the main actor.
    public var onDeviceStatus: ((LunaDeviceStatus) -> Void)?
    public var onSettings: ((LunaPhotographySettings) -> Void)?
    public var onCapture: ((LunaCaptureStatus) -> Void)?
    public var onNotification: ((LunaNotification) -> Void)?
    /// Deep Track box and state from the stream; only changes are delivered.
    public var onTrackFrame: ((LunaTrackFrame) -> Void)?
    /// Camera-head IMU (media 0x30), ~100 samples every 100 ms.
    public var onIMU: (([LunaIMUSample]) -> Void)?
    private var lastTrackFrame: LunaTrackFrame?
    public var onDeviceInformation: ((LunaDeviceInformation) -> Void)?
    /// Every request/notification summary, for the shell's diagnostics journal.
    public var onLog: ((String) -> Void)?
    /// Local Network evidence from the current connect only: a completed control handshake, or
    /// the camera link's explicit policy denial. Ordinary waiting is never reported.
    public var onLocalNetworkEvidence: ((CameraNetworkPermissionEvidence) -> Void)?
    /// Media packets seen per UCD2 subtype, with the first bytes of the latest (lab).
    public var mediaSubtypeStats: [UInt8: (count: Int, last: Data)] = [:]

    public var isOnCameraNetwork: Bool { LunaWiFi.localAddress != nil }
    public var isControlReady: Bool { handshakeComplete && isTCP }
    /// Settings bank of the camera's reported shooting mode (video 7 until one is reported).
    public private(set) var functionMode: UInt32 = LunaFunctionMode.normalVideo.rawValue
    /// The OpenCineCore session for the camera being connected; `openSession()` replaces it.
    public private(set) var session: LunaCameraSession?
    public private(set) var credentials: LunaStoredWiFi?
    public private(set) var deviceInformation: LunaDeviceInformation?

    /// App-supplied names (keychain service, operator-facing app name, log prefix).
    public let configuration: LunaIntegrationConfiguration
    private let store: LunaSecureStore
    private let bluetooth: LunaBluetooth
    private let tcp = LunaTCPTransport()
    private let existingNetwork: Bool
    private var identity: UUID?
    private var selected: MonitorCamera?
    private var sessionKey: SymmetricKey?
    private var bleParser = try! UCD2Reassembler(maximumFrameSize: 1024 * 1024)
    private var tcpParser = try! UCD2Reassembler()
    private var counter = LunaRequestCounter()
    private var heartbeat: Task<Void, Never>?
    private var statusPoll: Task<Void, Never>?
    private var generation = 0
    /// When the current connect first held its camera network address.
    private var reachableAt: ContinuousClock.Instant?
    /// The app's one retained hotspot owner for this backend; nil keeps the direct native calls.
    private let hotspot: CameraHotspotHost?
    private var connectedMedia: LunaMediaService?
    let mediaIO: (any LunaMediaIO)?
    /// App-owned native preparation, fenced by the captured session/epoch at composition.
    public var prepareMediaLiveReturn: (@MainActor (MediaBrowseBinding) async -> Void)?
    private var isTCP = false
    private var liveStartAttempted = false
    private var handshakeComplete = false
    private var greetingOperation: UUID?
    private var bleHasNotification = false
    private var tcpGreetingSeen = false
    private var tcpGreetingWaiter: CheckedContinuation<Void, Error>?
    private var tcpGreetingTimeout: Task<Void, Never>?
    private var approval: UCD2Message?
    private var receivedNonces = Set<Data>()
    private var lastVideoAt: Date?
    private struct Pending {
        let generation: Int
        let operation: UUID
        let continuation: CheckedContinuation<Data, Error>
        let encrypted: Bool
        var dispatched = true
        var writeCompleted = false
        var responseBody: Data?
        let timeout: Task<Void, Never>
    }
    private var pending: [UInt32: Pending] = [:]
    #if DEBUG
        /// Debug review harnesses only: the SIMULATED camera behind the control link.
        private var reviewCamera: LunaReviewCamera?
    #endif

    /// Existing-network mode serves a Mac/Simulator already on the camera AP.
    public init(
        useExistingNetwork: Bool = false, configuration: LunaIntegrationConfiguration = .init(),
        mediaIO: (any LunaMediaIO)? = nil, hotspot: CameraHotspotHost? = nil
    ) {
        existingNetwork = useExistingNetwork
        self.hotspot = hotspot
        self.configuration = configuration
        self.mediaIO = mediaIO
        store = LunaSecureStore(service: configuration.keychainService)
        bluetooth = LunaBluetooth(appName: configuration.appName)
        bluetooth.onCamera = { [weak self] camera in
            guard let self else { return }
            self.eventHandler?(
                .discovered(
                    MonitorCamera(
                        id: camera.id, name: camera.name, model: camera.model,
                        capabilities: self.capabilities)))
        }
        bluetooth.onData = { [weak self] in self?.receive($0, fromTCP: false) }
        bluetooth.onDisconnect = { [weak self] reason in self?.transportDropped(reason) }
        tcp.onData = { [weak self] in self?.receive($0, fromTCP: true) }
        tcp.onDisconnect = { [weak self] reason in self?.transportDropped(reason) }
    }

    /// Saved Wi-Fi for a camera id (Keychain). Used for the watcher Wi-Fi QR and rejoin.
    public func storedWiFi(cameraID: UUID) -> LunaStoredWiFi? {
        store.credentials(cameraID: cameraID)
    }

    /// Whether this run has heard the camera advertise (Bluetooth can reach it now).
    public func hasSeen(_ cameraID: UUID) -> Bool { bluetooth.hasSeen(cameraID) }

    /// Whether saved camera Wi-Fi exists for a camera that is not advertising.
    public func hasSavedWiFi(cameraID: UUID) -> Bool { store.credentials(cameraID: cameraID) != nil }

    public func startScan() async throws {
        try Task.checkCancellation()
        emit(.scanning)
        if existingNetwork {
            guard isOnCameraNetwork else {
                throw ConnectionFailure.luna(
                    .notFound, "existing-network.absent",
                    "Join the Luna camera Wi-Fi on this device before opening the feed.")
            }
            eventHandler?(
                .discovered(
                    MonitorCamera(
                        id: Self.existingNetworkCameraID, name: "Luna Ultra",
                        model: LunaProtocol.model, capabilities: capabilities)))
            return
        }
        try await bluetooth.startScan()
    }

    public static let existingNetworkCameraID = UUID(
        uuidString: "B5BB58F0-02EC-4DBD-AC83-70329F77C144")!

    public func stopScan() { bluetooth.stopScan() }

    public func connect(to camera: MonitorCamera) async throws {
        try Task.checkCancellation()
        disconnect()
        generation += 1
        let token = generation
        reachableAt = nil
        selected = camera
        identity = try store.identity()
        guard let identity else {
            throw ConnectionFailure.luna(
                .other, "identity.unavailable",
                "A camera authorization identity could not be created.")
        }
        var expectedSerial: String?
        do {
            let stored = store.credentials(cameraID: camera.id)
            if !existingNetwork {
                // Bluetooth first whenever the camera advertises: it is quick once
                // approved, and it wakes the camera Wi-Fi, which Luna turns off when idle.
                // Saved Wi-Fi is the fallback for a camera that is not advertising.
                if !bluetooth.hasSeen(camera.id), let stored, await quickJoin(stored, token: token)
                {
                    credentials = stored
                } else {
                    expectedSerial = try await bootstrapOverBluetooth(
                        camera: camera, identity: identity, token: token)
                }
            }
            try validate(token)
            emit(.openingVideo)
            try await openControl(token: token, identity: identity, expectedSerial: expectedSerial)
            liveStartAttempted = true
            _ = try? await send(
                LunaProtocol.setAccessCameraFileState(LunaProtocol.shootingViewAccessState))
            _ = try await send(LunaProtocol.startLiveRequest)
            try validate(token)
            handshakeComplete = true
            onLocalNetworkEvidence?(.operationSucceeded)
            emit(.streaming)
            startStatusPoll(token: token)
        } catch {
            if token == generation {
                if (error as? ConnectionFailure)?.reason == .permission(.localNetwork) {
                    onLocalNetworkEvidence?(.policyDenied)
                }
                disconnect()
            }
            throw error
        }
    }

    /// Joins saved Wi-Fi and proves TCP 6666 answers. False sends the caller to BLE.
    private func quickJoin(_ stored: LunaStoredWiFi, token: Int) async -> Bool {
        emit(.joiningWiFi)
        do {
            try await joinRetrying(stored, token: token, budget: .seconds(20))
            try validate(token)
            eventHandler?(.joinedWiFi(ssid: stored.ssid))
            return true
        } catch {
            onLog?(
                "luna: saved Wi-Fi join failed, falling back to Bluetooth: \(error.localizedDescription)"
            )
            return false
        }
    }

    /// The camera AP needs a few seconds (sometimes most of a minute) after the BLE
    /// handoff wakes it; the attempts and their timeout live in `LunaJoinAttempts`.
    private func joinRetrying(
        _ wifi: LunaStoredWiFi, token: Int, budget: Duration = .seconds(60)
    ) async throws {
        guard let hotspot else {
            try await joinRetrying(wifi, token: token, budget: budget, operations: nil)
            return
        }
        // One scope for the whole loop: a replacement connect retires this loop's queued
        // removals, and no retry reaches the OS while an earlier apply is still pending.
        try await hotspot.withAttempt({ [weak self] in self?.generation == token }) { [weak self] operations in
            guard let self else { throw CancellationError() }
            try await self.joinRetrying(wifi, token: token, budget: budget, operations: operations)
        }
    }

    private func joinRetrying(
        _ wifi: LunaStoredWiFi, token: Int, budget: Duration, operations: CameraHotspotOperations?
    ) async throws {
        let prefix = configuration.logPrefix
        let appName = configuration.appName
        try await LunaJoinAttempts.run(
            budget: budget,
            onCameraNetwork: { [weak self] in
                // Already on the camera subnet (auto-join, the operator joined in Settings, or
                // the operator answered the system Join alert late).
                guard LunaWiFi.localAddress != nil else { return false }
                self?.noteReachable(token)
                return true
            },
            validate: { [weak self] in
                guard let self else { throw CancellationError() }
                try self.validate(token)
            },
            attemptStarts: { [weak self] attempt in
                guard attempt == 3 else { return }
                self?.eventHandler?(
                    .note(
                        "If this takes long, open Settings › Wi-Fi and join “\(wifi.ssid)”. \(appName) continues automatically."
                    ))
            },
            log: { [weak self] in self?.onLog?($0) },
            leave: { LunaWiFi.leave(ssid: wifi.ssid, remove: operations?.remove) },
            join: { [weak self] once, prompt in
                try await LunaWiFi.join(
                    wifi, joinOnce: once, logPrefix: prefix, apply: operations?.apply, prompt: prompt,
                    reachable: { [weak self] in self?.noteReachable(token) })
            })
    }

    private func bootstrapOverBluetooth(camera: MonitorCamera, identity: UUID, token: Int)
        async throws -> String
    {
        emit(.connecting)
        onLog?("luna: BLE connect \(camera.name)")
        try await bluetooth.connect(id: camera.id)
        try validate(token)
        let greetingDeadline = Date().addingTimeInterval(5)
        while !bleHasNotification, Date() < greetingDeadline {
            try validate(token)
            try await Task.sleep(for: .milliseconds(50))
        }
        try validate(token)
        emit(.negotiating)
        let info = try LunaProtocol.deviceInformation(
            response: await send(LunaProtocol.deviceInformationRequest(includeSerial: true)))
        // BE80 is shared by more Insta360 cameras. Only apply the verified Luna profile.
        guard info.model == LunaProtocol.model else {
            throw ConnectionFailure.luna(
                .unsupported, "model.unsupported",
                "This camera is \(info.model). \(configuration.appName) currently supports the Insta360 Luna Ultra.",
                phase: .negotiating)
        }
        guard let serial = info.serial, !serial.isEmpty else {
            throw ConnectionFailure.luna(
                .other, "serial.missing",
                "The camera did not provide an identity to verify its Wi-Fi handoff.",
                phase: .negotiating)
        }
        deviceInformation = info
        onDeviceInformation?(info)
        eventHandler?(
            .information(CameraInformation(model: info.model, firmware: info.firmware)))
        let schemes = try LunaProtocol.encryptionSchemes(
            response: await send(LunaProtocol.encryptionCapabilitiesRequest))
        guard schemes.contains(3) else {
            throw ConnectionFailure.luna(
                .unsupported, "encryption.unsupported",
                "The camera does not support the verified encrypted connection handshake.",
                phase: .negotiating)
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let exchange = try LunaProtocol.keyExchangeRequest(
            publicKey: privateKey.publicKey.x963Representation)
        let cameraKey = try LunaProtocol.cameraPublicKey(response: await send(exchange))
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: cameraKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        sessionKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: LunaProtocol.hkdfSalt, sharedInfo: LunaProtocol.hkdfInfo,
            outputByteCount: LunaProtocol.sessionKeyByteCount)
        let authenticated = try LunaProtocol.deviceInformation(
            response: await send(LunaProtocol.deviceInformationRequest(encrypted: true)))
        guard authenticated.model == info.model else {
            throw ConnectionFailure.luna(
                .wrongCamera, "identity.mismatch",
                "The encrypted camera identity did not match the selected device.",
                phase: .negotiating)
        }
        emit(.awaitingApproval)
        let authorization = try LunaProtocol.authorizationStatus(
            response: await send(LunaProtocol.authorizationCheck(identity: identity)))
        if authorization == .approvalRequired {
            _ = try await send(LunaProtocol.requestAuthorization)
            try await waitForApproval(identity: identity)
        } else if authorization != .authorized {
            throw ConnectionFailure.lunaHeldElsewhere
        }
        emit(.readingWiFi)
        let wifi = try LunaProtocol.wifiCredentials(
            response: await send(LunaProtocol.wifiCredentialsRequest))
        let saved = LunaStoredWiFi(ssid: wifi.ssid, password: wifi.password)
        try store.save(saved, cameraID: camera.id)
        credentials = saved
        bluetooth.disconnect()
        sessionKey = nil
        receivedNonces.removeAll()
        try validate(token)
        emit(.joiningWiFi)
        try await joinRetrying(saved, token: token, budget: .seconds(120))
        eventHandler?(.joinedWiFi(ssid: saved.ssid))
        return serial
    }

    /// Records when this connect first held its camera network address: the Local Network
    /// denial deadline counts from here, not from the later control link start.
    private func noteReachable(_ token: Int) {
        guard token == generation, reachableAt == nil else { return }
        reachableAt = .now
        onLog?("luna: camera network reachable")
    }

    private func openControl(token: Int, identity: UUID, expectedSerial: String?) async throws {
        isTCP = true
        counter = LunaRequestCounter()
        let reachableFor = reachableAt.map { ContinuousClock.now - $0 } ?? .zero
        let seconds = Double(reachableFor.components.seconds)
            + Double(reachableFor.components.attoseconds) / 1e18
        onLog?("luna: control link starts \(String(format: "%.1f", seconds)) s after the network was reachable")
        try await tcp.connect(
            host: LunaProtocol.defaultHost, port: LunaProtocol.defaultPort,
            localAddress: LunaWiFi.localAddress, reachableFor: reachableFor)
        try await tcp.send(LunaProtocol.tcpPreface)
        try await waitForTCPGreeting()
        try validate(token)
        startHeartbeat(token: token)
        let info = try LunaProtocol.deviceInformation(
            response: await send(LunaProtocol.deviceInformationRequest(includeSerial: true)))
        guard info.model == LunaProtocol.model else {
            throw ConnectionFailure.luna(
                .wrongCamera, "wifi.not-luna", "The Wi-Fi device is not a supported Luna camera.",
                phase: .negotiating)
        }
        if let expectedSerial, info.serial != expectedSerial {
            throw ConnectionFailure.luna(
                .wrongCamera, "wifi.serial-mismatch",
                "The Wi-Fi connection reached a different camera. Join the selected camera's network and retry.",
                phase: .negotiating)
        }
        deviceInformation = info
        onDeviceInformation?(info)
        eventHandler?(.information(CameraInformation(model: info.model, firmware: info.firmware)))
        let authorization = try LunaProtocol.authorizationStatus(
            response: await send(LunaProtocol.authorizationCheck(identity: identity)))
        guard authorization == .authorized else {
            // Saved Wi-Fi reached the camera but this install is not approved (reset,
            // or another phone owns it). Forget the shortcut so the next try asks over BLE.
            if let id = selected?.id { store.forget(cameraID: id) }
            throw ConnectionFailure.luna(
                .notApproved, "approval.missing",
                "The camera has not approved this iPhone yet. Connect again and accept the request on the camera's screen.",
                phase: .awaitingApproval)
        }
        await refreshStatus()
    }

    #if DEBUG
        /// Debug review harnesses only: `camera` stands behind the control link as a connected,
        /// approved camera (`isControlReady`) and answers every request, so the session and media
        /// service this backend opens run for real without a network. `disconnect()` drops it.
        public func connect(review camera: LunaReviewCamera) {
            disconnect()
            reviewCamera = camera
            isTCP = true
            handshakeComplete = true
        }
    #endif

    public func disconnect() {
        #if DEBUG
            reviewCamera = nil
        #endif
        session?.retireCommandSource()
        connectedMedia?.retire()
        generation += 1
        handshakeComplete = false
        heartbeat?.cancel()
        heartbeat = nil
        statusPoll?.cancel()
        statusPoll = nil
        if liveStartAttempted,
            let frame = try? LunaProtocol.stopLiveRequest.plainFrame(
                identifier: counter.nextIdentifier(), sequence: counter.nextSequence())
        {
            tcp.sendBeforeClosing(frame.raw)
        } else {
            tcp.disconnect()
        }
        liveStartAttempted = false
        isTCP = false
        tcpGreetingSeen = false
        bleHasNotification = false
        bluetooth.disconnect()
        sessionKey = nil
        receivedNonces.removeAll()
        bleParser = try! UCD2Reassembler(maximumFrameSize: 1024 * 1024)
        tcpParser = try! UCD2Reassembler()
        failPending(CancellationError())
        counter = LunaRequestCounter()
        approval = nil
        lastVideoAt = nil
        emit(.idle)
    }

    public func forget(cameraID: UUID) {
        store.forget(cameraID: cameraID)
        if selected?.id == cameraID { credentials = nil }
    }

    public func leaveCameraNetwork() {
        disconnect()
        if let credentials { leaveNetwork(ssid: credentials.ssid) }
    }

    /// Leaves `ssid` through this backend's hotspot owner (the direct call without one). Queued
    /// behind a still pending apply, the removal runs only if no newer connect started first.
    public func leaveNetwork(ssid: String, isCurrent: @escaping CameraNetworkIsCurrent = { true }) {
        guard let hotspot else {
            if isCurrent() { LunaWiFi.leave(ssid: ssid) }
            return
        }
        let retired = generation
        LunaWiFi.leave(ssid: ssid) { [weak self] ssid in
            hotspot.remove(ssid) { self?.generation == retired && isCurrent() }
        }
    }

    public func rejoinCameraNetwork() async throws {
        guard let selected else { return }
        try await connect(to: selected)
    }

    /// Restart the HEVC stream on the open control socket (media return, stall repair).
    public func restartLive() async throws {
        guard isControlReady else { return }
        _ = try? await send(LunaProtocol.stopLiveRequest)
        _ = try? await send(
            LunaProtocol.setAccessCameraFileState(LunaProtocol.shootingViewAccessState))
        _ = try await send(LunaProtocol.startLiveRequest)
    }

    /// Stop live video while the socket stays open (media browsing over HTTP).
    public func pauseLive() async {
        guard isControlReady else { return }
        _ = try? await send(LunaProtocol.stopLiveRequest)
    }

    public var secondsSinceVideo: TimeInterval? {
        lastVideoAt.map { Date().timeIntervalSince($0) }
    }

    // MARK: - Session

    /// A new OpenCineCore session for the next connection. The previous one closes as replaced.
    public func openSession() -> LunaCameraSession {
        connectedMedia?.retire()
        connectedMedia = nil
        let previous = session
        let next = LunaCameraSession(
            send: { [weak self] request in
                guard let self else { throw ConnectionFailure.lunaLinkClosed }
                return try await self.send(request)
            },
            sendWithin: { [weak self] request, timeout in
                guard let self else { throw ConnectionFailure.lunaLinkClosed }
                return try await self.send(request, timeout: timeout)
            },
            functionMode: { [weak self] in
                self?.functionMode ?? LunaFunctionMode.normalVideo.rawValue
            },
            readSettings: { [weak self] in await self?.refreshSettings() },
            readCapture: { [weak self] in await self?.refreshCapture() },
            sendAdmitted: { [weak self] build, admission, didDispatch in
                guard let self else { throw LunaCommandAdmissionError.expired }
                return try await self.sendAdmitted(
                    build, admission: admission, didDispatch: didDispatch)
            },
            sendAdmittedWithin: { [weak self] build, admission, timeout, didDispatch in
                guard let self else { throw LunaCommandAdmissionError.expired }
                return try await self.sendAdmitted(
                    build, admission: admission, timeout: timeout,
                    didDispatch: didDispatch)
            }, backendCapabilities: { [weak self] in self?.capabilities })
        next.configureLens(zoomDomain: 1...LunaProtocol.maximumZoomScale)
        session = next
        previous?.close(.replaced)
        if isControlReady { next.linkChanged(.streaming, serial: deviceInformation?.serial) }
        return next
    }

    private func emit(_ phase: CameraConnectionPhase) {
        session?.linkChanged(phase, serial: deviceInformation?.serial)
        eventHandler?(.phase(phase))
    }

    private func deliver(_ status: LunaDeviceStatus) {
        if let mode = status.shootingMode?.functionMode { functionMode = mode.rawValue }
        session?.ingest(device: status)
        onDeviceStatus?(status)
    }

    private func deliver(_ settings: LunaPhotographySettings) {
        session?.ingest(settings: settings)
        onSettings?(settings)
    }

    private func deliver(_ capture: LunaCaptureStatus) {
        session?.ingest(capture: capture)
        onCapture?(capture)
    }

    // MARK: - Status

    /// One full read: device status, video settings for the active mode, capture state.
    public func refreshStatus() async {
        guard isTCP else { return }
        if let body = try? await send(LunaProtocol.statusRequest()),
            let status = try? LunaDeviceStatus(response: body)
        {
            deliver(status)
        }
        await refreshShootingMode()
        await refreshSettings()
        await refreshRemainingTime()
        await refreshCapture()
    }

    /// Device options 40/41: which shooting mode (and so which settings bank) is active.
    public func refreshShootingMode() async {
        guard isTCP, let body = try? await send(LunaProtocol.shootingModeRequest()),
            let status = try? LunaDeviceStatus(response: body)
        else { return }
        deliver(status)
    }

    public func refreshSettings() async {
        guard isTCP else { return }
        if let body = try? await send(
            LunaProtocol.getPhotographyOptions(Self.settingTypes, mode: functionMode)),
            let settings = try? LunaPhotographySettings(response: body)
        {
            deliver(settings)
        }
    }

    /// Photography option 99 for the active mode: remaining record time per card, as the
    /// official app polls it. The reply carries only option 99, so other settings stay.
    func refreshRemainingTime() async {
        guard isTCP,
            let body = try? await send(LunaProtocol.remainingTimeRequest(functionMode: functionMode)),
            let settings = try? LunaPhotographySettings(response: body)
        else { return }
        deliver(settings)
    }

    /// Capture state (cmd 15): recording and the record timer.
    public func refreshCapture() async {
        guard isTCP, let body = try? await send(LunaProtocol.captureStatusRequest),
            let capture = try? LunaCaptureStatus(captureStatusResponse: body)
        else { return }
        deliver(capture)
    }

    /// Every photography type the monitor shows.
    public static let settingTypes: [UInt32] = [
        6, 7, 18, 20, 21, 24, 31, 33, 35, 39, 40, 43, 46, 53, 72, 73, 91, 92, 93, 100, 104,
    ]

    private func startStatusPoll(token: Int) {
        statusPoll?.cancel()
        statusPoll = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, token == self.generation, self.isTCP else { return }
                tick += 1
                // Capture state every second (record timer); battery/storage every 5 s.
                await self.refreshCapture()
                if tick % 5 == 0,
                    let body = try? await self.send(LunaProtocol.statusRequest()),
                    let status = try? LunaDeviceStatus(response: body)
                {
                    self.deliver(status)
                }
                if tick % 5 == 0 { await self.refreshRemainingTime() }
            }
        }
    }

    // MARK: - Requests

    /// Send one request and return the camera's 200 body. Throws on 500 or timeout.
    @discardableResult
    public func send(_ request: LunaRequest, timeout: Duration = .seconds(8)) async throws -> Data {
        try await send(
            request, timeout: timeout, suppliedAdmission: nil, build: nil, didDispatch: nil)
    }

    private func sendAdmitted(
        _ build: @escaping LunaCommandRequestBuilder,
        admission: LunaCommandAdmission, timeout: Duration = .seconds(8),
        didDispatch: @escaping LunaCommandDidDispatch
    ) async throws -> Data {
        try admission.require(owner: session?.commandOwner)
        let request = try build()
        return try await send(
            request, timeout: timeout, suppliedAdmission: admission,
            build: build, didDispatch: didDispatch)
    }

    private func encodeRequest(_ request: LunaRequest, identifier id: UInt32, sequence: UInt8)
        throws -> UCD2Frame
    {
        if request.requiresEncryption {
            guard let key = sessionKey else {
                throw ConnectionFailure.luna(
                    .linkLost, "session.not-encrypted",
                    "The encrypted camera session is not established.")
            }
            let payload = try request.message(identifier: id).payload
            let aad = try UCD2Frame.scheme3AssociatedData(
                sequence: sequence, plaintextLength: payload.count)
            let box = try AES.GCM.seal(payload, using: key, authenticating: aad)
            return try UCD2Frame.scheme3(
                sequence: sequence, ciphertext: box.ciphertext, nonce: Data(box.nonce), tag: box.tag
            )
        }
        return try request.plainFrame(identifier: id, sequence: sequence)
    }

    private func send(
        _ request: LunaRequest, timeout: Duration,
        suppliedAdmission admission: LunaCommandAdmission?, build: LunaCommandRequestBuilder?,
        didDispatch: LunaCommandDidDispatch?
    ) async throws -> Data {
        if let admission { try admission.require(owner: session?.commandOwner) }
        #if DEBUG
            if let reviewCamera {
                let current = try build?() ?? request
                didDispatch?()
                return try reviewCamera.answer(current)
            }
        #endif
        guard isTCP || !request.requiresEncryption || sessionKey != nil else {
            throw ConnectionFailure.lunaLinkClosed
        }
        let requestGeneration = generation
        let operation = UUID()
        let id = counter.nextIdentifier()
        let sequence = counter.nextSequence()
        // Nil/direct framing still happens before scheduling, as it did before admission.
        let directFrame =
            admission == nil ? try encodeRequest(request, identifier: id, sequence: sequence) : nil
        let useTCP = isTCP
        let tcpSource = admission == nil ? nil : tcp.commandSource
        let bluetoothSource = admission == nil ? nil : bluetooth.commandSource
        let code = request.wireCode
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, let self,
                        let entry = self.takePending(
                            id, generation: requestGeneration, operation: operation)
                    else { return }
                    entry.continuation.resume(
                        throwing: ConnectionFailure.luna(
                            .timedOut, "command.timeout",
                            "The camera did not answer command \(code)."))
                }
                pending[id] = Pending(
                    generation: requestGeneration, operation: operation,
                    continuation: continuation, encrypted: request.requiresEncryption,
                    dispatched: admission == nil,
                    timeout: timer)
                Task { [weak self] in
                    guard let self, requestGeneration == self.generation, self.pending[id] != nil
                    else { return }
                    do {
                        if let admission {
                            try admission.require(owner: self.session?.commandOwner)
                            guard self.isTCP == useTCP, let build, let didDispatch,
                                let waiting = self.pending[id],
                                waiting.generation == requestGeneration,
                                waiting.operation == operation
                            else { throw LunaCommandAdmissionError.expired }
                            let currentRequest = try build()
                            let frame = try self.encodeRequest(
                                currentRequest, identifier: id, sequence: sequence)
                            let entered: LunaCommandDidDispatch = { [weak self] in
                                guard let self, self.generation == requestGeneration,
                                    var entry = self.pending[id],
                                    entry.generation == requestGeneration,
                                    entry.operation == operation
                                else { return }
                                entry.dispatched = true
                                self.pending[id] = entry
                                didDispatch()
                            }
                            if useTCP, let tcpSource {
                                try await self.tcp.send(
                                    frame.raw, admission: admission,
                                    source: tcpSource, didDispatch: entered)
                            } else if !useTCP, let bluetoothSource {
                                try await self.bluetooth.write(
                                    frame.raw, admission: admission,
                                    source: bluetoothSource, didDispatch: entered)
                            } else {
                                throw LunaCommandAdmissionError.expired
                            }
                        } else if self.isTCP, let directFrame {
                            try await self.tcp.send(directFrame.raw)
                        } else {
                            guard let directFrame else { throw ConnectionFailure.lunaLinkClosed }
                            try await self.bluetooth.write(directFrame.raw)
                        }
                        if var entry = self.pending[id], entry.generation == requestGeneration,
                            entry.operation == operation
                        {
                            entry.writeCompleted = true
                            self.pending[id] = entry
                            self.finishPendingIfComplete(
                                id, generation: requestGeneration, operation: operation)
                        }
                    } catch {
                        if let entry = self.takePending(
                            id, generation: requestGeneration, operation: operation)
                        {
                            entry.timeout.cancel()
                            entry.continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let entry = self?.takePending(
                    id, generation: requestGeneration, operation: operation)
                {
                    entry.timeout.cancel()
                    entry.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func validate(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func takePending(_ id: UInt32, generation: Int, operation: UUID) -> Pending? {
        guard let entry = pending[id], entry.generation == generation, entry.operation == operation
        else { return nil }
        return pending.removeValue(forKey: id)
    }

    private func finishPendingIfComplete(_ id: UInt32, generation: Int, operation: UUID) {
        guard let candidate = pending[id], candidate.generation == generation,
            candidate.operation == operation, candidate.dispatched, candidate.writeCompleted,
            let body = candidate.responseBody,
            let entry = takePending(id, generation: generation, operation: operation)
        else { return }
        entry.timeout.cancel()
        entry.continuation.resume(returning: body)
    }

    private func receive(_ data: Data, fromTCP: Bool) {
        guard fromTCP == isTCP else { return }
        if !fromTCP, !data.isEmpty { bleHasNotification = true }
        let frames = fromTCP ? tcpParser.feed(data) : bleParser.feed(data)
        for frame in frames {
            do {
                if frame.type == UCD2Frame.heartbeatType, fromTCP {
                    tcpGreetingSeen = true
                    tcpGreetingTimeout?.cancel()
                    tcpGreetingTimeout = nil
                    let waiter = tcpGreetingWaiter
                    tcpGreetingWaiter = nil
                    greetingOperation = nil
                    waiter?.resume()
                    continue
                }
                if frame.type == UCD2Frame.mediaType, fromTCP {
                    guard liveStartAttempted else { continue }
                    let media = try LunaMediaPacket(frame: frame)
                    mediaSubtypeStats[media.subtype, default: (0, Data())].count += 1
                    mediaSubtypeStats[media.subtype]?.last = media.bytes.prefix(64)
                    if let video = media.hevcAnnexB {
                        lastVideoAt = Date()
                        eventHandler?(
                            .videoAccessUnit(video, timestampMilliseconds: media.timestamp))
                    } else if let imu = media.imuSamples, !imu.isEmpty {
                        onIMU?(imu)
                    } else if let track = media.trackFrame, track != lastTrackFrame {
                        if track.rawState != lastTrackFrame?.rawState {
                            onLog?("luna: track state \(track.rawState)")
                        }
                        lastTrackFrame = track
                        onTrackFrame?(track)
                    }
                    continue
                }
                guard frame.type == UCD2Frame.messageType else { continue }
                let message: UCD2Message
                if frame.isScheme3Encrypted {
                    guard let sessionKey else {
                        throw ConnectionFailure.luna(
                            .other, "session.unexpected-encrypted",
                            "An encrypted camera message arrived outside its authorized session.")
                    }
                    let envelope = try frame.scheme3Envelope()
                    guard !receivedNonces.contains(envelope.nonce) else { continue }
                    let box = try AES.GCM.SealedBox(
                        nonce: AES.GCM.Nonce(data: envelope.nonce),
                        ciphertext: envelope.ciphertext, tag: envelope.tag)
                    let plaintext = try AES.GCM.open(
                        box, using: sessionKey, authenticating: envelope.associatedData)
                    receivedNonces.insert(envelope.nonce)
                    message = try UCD2Message(payload: plaintext)
                } else {
                    guard let plain = try frame.plainMessage() else { continue }
                    message = plain
                }
                if message.code == 8209 || message.code == 8228 {
                    if !fromTCP { approval = message }
                    continue
                }
                if message.code >= 8192 {
                    handleNotification(message)
                    continue
                }
                guard message.code == 200 || message.code == 500,
                    var waiting = pending[message.identifier], waiting.generation == generation,
                    waiting.dispatched,
                    waiting.responseBody == nil
                else { continue }
                do {
                    waiting.responseBody = try message.successfulResponseBody(
                        for: message.identifier, encrypted: frame.isScheme3Encrypted,
                        requiresEncryption: waiting.encrypted)
                    pending[message.identifier] = waiting
                    finishPendingIfComplete(
                        message.identifier, generation: generation, operation: waiting.operation)
                } catch {
                    onLog?(
                        "luna: reply \(message.identifier) code=\(message.code) contentType=\(message.contentType) reserved=\(message.reserved) bytes=\(message.body.count) rejected: \(error)"
                    )
                    if let entry = takePending(
                        message.identifier, generation: generation, operation: waiting.operation)
                    {
                        entry.timeout.cancel()
                        entry.continuation.resume(throwing: error)
                    }
                }
            } catch {
                onLog?("luna: undecodable frame \(error.localizedDescription)")
            }
        }
    }

    private func handleNotification(_ message: UCD2Message) {
        guard let note = try? LunaNotification(message: message) else { return }
        switch note {
        case .captureStatus(let capture):
            deliver(capture)
        case .photographyChanged(let settings):
            deliver(settings)
        case .subMode, .storage, .battery, .batteryLow:
            // The notice carries a partial view; re-read the whole status.
            Task { [weak self] in
                guard let self, self.isTCP,
                    let body = try? await self.send(LunaProtocol.statusRequest()),
                    let status = try? LunaDeviceStatus(response: body)
                else { return }
                self.deliver(status)
                await self.refreshShootingMode()
                await self.refreshSettings()
            }
        default:
            break
        }
        onNotification?(note)
    }

    private func waitForTCPGreeting() async throws {
        if tcpGreetingSeen { return }
        let token = generation
        let operation = UUID()
        greetingOperation = operation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                tcpGreetingWaiter = continuation
                tcpGreetingTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, let self, self.generation == token,
                        self.greetingOperation == operation, let waiter = self.tcpGreetingWaiter
                    else { return }
                    self.tcpGreetingWaiter = nil
                    self.greetingOperation = nil
                    waiter.resume(
                        throwing: ConnectionFailure.luna(
                            .timedOut, "video.greeting-timeout",
                            "The camera did not complete the video connection greeting.",
                            phase: .negotiating))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.greetingOperation == operation
                else { return }
                self.failPending(CancellationError())
            }
        }
    }

    private func waitForApproval(identity: UUID) async throws {
        let token = generation
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try validate(token)
            if let approval {
                try LunaProtocol.validateAuthorizationNotification(approval)
                return
            }
            let status = try LunaProtocol.authorizationStatus(
                response: await send(LunaProtocol.authorizationCheck(identity: identity)))
            if status == .authorized { return }
            if status != .approvalRequired { throw ConnectionFailure.lunaHeldElsewhere }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw ConnectionFailure.luna(
            .notApproved, "approval.timeout",
            "Approval timed out. Connect again and tap Allow on the camera's screen.",
            phase: .awaitingApproval)
    }

    private func startHeartbeat(token: Int) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(LunaProtocol.heartbeatInterval))
                    guard let self, token == self.generation else { return }
                    let frame = try LunaProtocol.heartbeat(sequence: self.counter.nextSequence())
                    try await self.tcp.send(frame.raw)
                } catch {
                    if !Task.isCancelled {
                        self?.transportDropped(
                            "The camera stopped responding to the live connection.")
                    }
                    return
                }
            }
        }
    }

    private func transportDropped(_ reason: String) {
        failPending(ConnectionFailure.luna(.linkLost, "link.dropped", reason))
        guard handshakeComplete else { return }
        disconnect()
        eventHandler?(.disconnected(reason: reason))
    }

    private func failPending(_ error: Error) {
        greetingOperation = nil
        tcpGreetingTimeout?.cancel()
        tcpGreetingTimeout = nil
        let greeting = tcpGreetingWaiter
        tcpGreetingWaiter = nil
        greeting?.resume(throwing: error)
        let entries = pending
        pending.removeAll()
        for entry in entries.values {
            entry.timeout.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    // MARK: - Media

    /// Every file URI on the camera, newest first, with metadata where the camera gives it.
    public func listFiles() async throws -> [LunaMediaFile] {
        guard isControlReady else {
            throw CameraBackendError.unavailable("Connect the camera to browse clips.")
        }
        _ = try? await send(LunaProtocol.setAccessCameraFileState(LunaProtocol.albumAccessState))
        let listing = try LunaProtocol.fileList(
            response: await send(LunaProtocol.fileListRequest()))
        var files = listing.uris.map { LunaMediaFile(uri: $0) }
        if let body = try? await send(LunaProtocol.fileInfoListRequest()),
            let infos = try? LunaProtocol.fileInfoList(response: body)
        {
            let byURI = Dictionary(infos.map { ($0.uri, $0) }, uniquingKeysWith: { a, _ in a })
            files = files.map { byURI[$0.uri] ?? $0 }
        }
        return files.filter { !$0.isProxy }
    }

    /// Camera-rendered thumbnail (NV12 inside cmd 11 type 2).
    public func thumbnail(uri: String) async throws -> LunaThumbnail {
        try LunaThumbnail(
            response: await send(
                LunaProtocol.fileExtraRequest(uri, extraType: .thumbnail), timeout: .seconds(10)))
    }

    public func deleteFile(uri: String) async throws {
        _ = try await send(LunaProtocol.deleteFiles(uri))
    }
}

extension LunaCameraBackend: LunaMediaSourcePort, LunaMediaCatalogRecordSource {
    var mediaSourceState: LunaMediaSourceState? {
        guard isControlReady, let session, session.current.connection == .ready,
            session.current.authority == .owner
        else { return nil }
        return .init(session: session.id, epoch: session.current.epoch, connection: generation)
    }

    public func mediaService(for id: CameraSessionID) -> (any CameraMediaService)? {
        guard session?.id == id else { return nil }
        if let connectedMedia, connectedMedia.sessionID == id { return connectedMedia }
        let media = LunaMediaService(session: id, port: self)
        connectedMedia = media
        return media
    }

    public func mediaCatalogRecord(_ asset: MediaAssetID, binding: MediaBrowseBinding)
        -> LunaMediaCatalogRecord?
    {
        connectedMedia?.catalogRecord(asset, binding: binding)
    }

    func mediaRequest(_ request: LunaRequest, source: LunaMediaSourceState) async throws -> Data {
        guard mediaSourceState == source, let session else { throw MediaServiceError.retired }
        let reply = try await session.mediaRequest(request, epoch: source.epoch)
        guard mediaSourceState == source else { throw MediaServiceError.retired }
        return reply
    }

    func prepareMediaReturn(_ binding: MediaBrowseBinding) async {
        await prepareMediaLiveReturn?(binding)
    }
}
