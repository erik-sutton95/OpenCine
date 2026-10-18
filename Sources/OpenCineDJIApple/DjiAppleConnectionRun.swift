import Foundation
import OpenCineDJI

/// One finite Bluetooth/pair/AP-or-station/registration workflow. Host policy stays at
/// grouped credential and native-source actions; no CameraSession-shaped interface exists.
@MainActor
public final class DjiAppleConnectionRun {
    public enum Failure: Error, Equatable {
        case timeout, pairingTimeout, pairingDeferred, disconnected
        case commandTimeout(String), credentialsEmpty(String), disconnectedDuring(String)
        case credentialsRefused(String, UInt8), heldSession, wrongCamera
        case setupNotSaved, hostWiFi(String), stationCameraMissing(String), nanoWake
        case connectionNotOwned
    }

    public struct KnownWiFi: Sendable {
        public var ssid: String?
        public var password: String?
        public var source: String
        public var skipBLE: Bool
        public init(ssid: String? = nil, password: String? = nil, source: String = "none", skipBLE: Bool = false) {
            self.ssid = ssid; self.password = password; self.source = source; self.skipBLE = skipBLE
        }
    }
    public struct NetworkCredentials: Sendable {
        public var ssid: String
        public var password: String
        public init(ssid: String, password: String) { self.ssid = ssid; self.password = password }
    }
    public struct SavedPath: Sendable {
        public var isSaved: Bool
        public var mayBeInStationRole: Bool
        public var station: NetworkCredentials?
        public init(isSaved: Bool = false, mayBeInStationRole: Bool = false, station: NetworkCredentials? = nil) {
            self.isSaved = isSaved; self.mayBeInStationRole = mayBeInStationRole; self.station = station
        }
    }
    public struct JoinPolicy: Sendable {
        public var persist: Bool
        public var otherSSIDs: [String]
        public init(persist: Bool = false, otherSSIDs: [String] = []) {
            self.persist = persist; self.otherSSIDs = otherSSIDs
        }
    }
    public enum SSIDUse { case fallback, join }

    /// Saved facts are sampled after pairing, credentials immediately before GET, join facts
    /// at the original stage boundaries. The caller owns storage keys, formats and prompts.
    @MainActor public struct Credentials {
        public var savedPath: (DJISighting, DJIConnectionRoute) -> SavedPath
        public var resolveWiFi: (DJISighting) -> KnownWiFi
        public var joinPolicy: (DJISighting, String, Bool) -> JoinPolicy
        public var validateSSID: (DJISighting, String, SSIDUse) throws -> Void
        public var persist: (DJISighting, String, String) -> Void
        public var rejectCached: (DJISighting, String) -> Void
        public init(savedPath: @escaping (DJISighting, DJIConnectionRoute) -> SavedPath,
            resolveWiFi: @escaping (DJISighting) -> KnownWiFi,
            joinPolicy: @escaping (DJISighting, String, Bool) -> JoinPolicy,
            validateSSID: @escaping (DJISighting, String, SSIDUse) throws -> Void,
            persist: @escaping (DJISighting, String, String) -> Void,
            rejectCached: @escaping (DJISighting, String) -> Void) {
            self.savedPath = savedPath; self.resolveWiFi = resolveWiFi; self.joinPolicy = joinPolicy
            self.validateSSID = validateSSID; self.persist = persist; self.rejectCached = rejectCached
        }
    }
    public struct Path: Equatable, Sendable {
        public var joinedSSID: String?
        public var stationSSID: String?
        public var stationHost: String?
        public init(joinedSSID: String? = nil, stationSSID: String? = nil, stationHost: String? = nil) {
            self.joinedSSID = joinedSSID; self.stationSSID = stationSSID; self.stationHost = stationHost
        }
    }
    @MainActor public struct NativeContext {
        /// Local owned/borrowed connection authority, independent of decoder ownership.
        public var ownsConnection: Bool?
        public var endpoint: (any DjiAppleConnectionEndpoint)?
        public var path: Path
        /// Host's actual local initial-enable write fact, used only for legacy timeline.
        public var initialLiveViewEnableSent: Bool?
        public init(ownsConnection: Bool? = nil, endpoint: (any DjiAppleConnectionEndpoint)? = nil,
            path: Path = .init(), initialLiveViewEnableSent: Bool? = nil) {
            self.ownsConnection = ownsConnection; self.endpoint = endpoint; self.path = path
            self.initialLiveViewEnableSent = initialLiveViewEnableSent
        }
    }
    /// Passed into grouped native actions so a reentrant host can refuse the rest of A's
    /// source work after replacement by B. This token cannot admit a borrowed connection.
    @MainActor public final class Attempt {
        public let id = UUID()
        fileprivate weak var owner: DjiAppleConnectionRun?
        fileprivate var task: Task<Void, Never>?
        fileprivate var request: DjiAppleControlExchange.Request?
        fileprivate var endpoint: (any DjiAppleConnectionEndpoint)?
        fileprivate var path = Path()
        fileprivate init(owner: DjiAppleConnectionRun) { self.owner = owner }
        public var isCurrent: Bool { owner?.current === self && !Task.isCancelled }
    }
    @MainActor public struct NativeActions {
        public var observe: () -> NativeContext
        public var prepare: (DJISighting, Bool, Attempt) -> Void
        /// nil disposes the captured current native endpoint, preserving existing teardown.
        public var attach: ((any DjiAppleConnectionEndpoint)?, Path, Attempt) -> Void
        /// Must remain synchronous at subscribe/verified-registration before initial enable.
        public var registered: (any DjiAppleConnectionEndpoint, Path, Attempt) -> Void
        public init(observe: @escaping () -> NativeContext,
            prepare: @escaping (DJISighting, Bool, Attempt) -> Void,
            attach: @escaping ((any DjiAppleConnectionEndpoint)?, Path, Attempt) -> Void,
            registered: @escaping (any DjiAppleConnectionEndpoint, Path, Attempt) -> Void) {
            self.observe = observe; self.prepare = prepare; self.attach = attach; self.registered = registered
        }
    }
    public enum Event {
        case stage(DJIConnectionStage, String?)
        case progress(String?)
        case path(Path)
        case finished(Result<Path, Error>, preservingSource: Bool)
    }

    private var current: Attempt?
    private var retirementGeneration: UInt64 = 0
    private let transport: DjiAppleConnectionTransport
    private let exchange: DjiAppleControlExchange
    private let heartbeat: DjiAppleSessionHeartbeat
    private let credentials: Credentials
    private let native: NativeActions
    private let timing: DjiAppleConnectionTiming
    private let event: (Event) -> Void
    private let journal: (String) -> Void
    private let info: (String) -> Void
    private var stationSequence: UInt16 = 1200
    public var isRunning: Bool { current?.task != nil }
    public var currentRunID: UUID? { current?.id }

    public init(transport: DjiAppleConnectionTransport, exchange: DjiAppleControlExchange,
        heartbeat: DjiAppleSessionHeartbeat, credentials: Credentials, native: NativeActions,
        timing: DjiAppleConnectionTiming = .continuous, event: @escaping (Event) -> Void,
        journal: @escaping (String) -> Void = { _ in }, info: @escaping (String) -> Void = { _ in }) {
        self.transport = transport; self.exchange = exchange; self.heartbeat = heartbeat
        self.credentials = credentials; self.native = native; self.timing = timing
        self.event = event; self.journal = journal; self.info = info
    }

    @discardableResult
    public func replace(target: DJISighting, setup: DJISetup, preservingSource: Bool = false) -> UUID {
        let route: DJIConnectionRoute = switch setup {
        case .cameraWiFi: .cameraAccessPoint
        case .wifi: .infrastructureNetwork
        case .phoneHotspot: .phoneHotspot
        }
        return replace(target: target, route: route, preservingSource: preservingSource)
    }

    /// The route kind is captured, while credentials are sampled after pairing. A known
    /// station route with an unknown network must not become an empty network or fail early.
    @discardableResult
    public func replace(target: DJISighting, route: DJIConnectionRoute, preservingSource: Bool = false) -> UUID {
        retire()
        let attempt = Attempt(owner: self); current = attempt
        attempt.task = Task { [weak self, attempt] in
            guard let self, self.current === attempt else { return }
            defer { if self.current === attempt { attempt.task = nil } }
            do {
                try self.check(attempt)
                attempt.path = try self.observe(attempt).path
                switch route {
                case .cameraAccessPoint, .infrastructureNetwork, .phoneHotspot: break
                case .usb, .captureDevice: throw Failure.setupNotSaved
                }
                self.native.prepare(target, preservingSource, attempt)
                try self.check(attempt)
                // A new workflow cannot consume an old drain's held pairing approval.
                // These retire only local delivery/requests/mailbox; host teardown retains
                // native transport and motion authority. Preparation may reentrantly retire A.
                self.exchange.stopBLEDrain()
                try self.check(attempt)
                self.exchange.retire(Failure.disconnected)
                try self.check(attempt)
                try await self.run(target, route: route, attempt: attempt)
                try self.check(attempt)
                self.event(.finished(.success(attempt.path), preservingSource: preservingSource))
            } catch {
                guard self.current === attempt else { return }
                self.event(.finished(.failure(error), preservingSource: preservingSource))
            }
        }
        return attempt.id
    }

    private func check(_ attempt: Attempt) throws {
        guard attempt.isCurrent else { throw CancellationError() }
        let host = native.observe()
        guard attempt.isCurrent else { throw CancellationError() }
        guard host.ownsConnection == true else { throw Failure.connectionNotOwned }
    }
    private func observe(_ attempt: Attempt) throws -> NativeContext {
        try check(attempt)
        let host = native.observe()
        try check(attempt)
        return host
    }
    private func stage(_ value: DJIConnectionStage, text: String? = nil, attempt: Attempt) throws {
        try check(attempt); event(.stage(value, text)); try check(attempt)
    }
    private func pathChanged(_ attempt: Attempt) throws {
        try check(attempt); event(.path(attempt.path)); try check(attempt)
    }
    private func sendBLE(_ frame: Duml.Frame, attempt: Attempt) throws {
        try check(attempt); transport.bluetooth.send(frame); try check(attempt)
    }
    private func pause(_ duration: Duration, attempt: Attempt) async throws {
        try check(attempt); try await timing.sleep(duration); try check(attempt)
    }
    private func wall(_ attempt: Attempt) throws -> TimeInterval {
        try check(attempt); let value = timing.wallNow(); try check(attempt); return value
    }
    private func uptime(_ attempt: Attempt) throws -> TimeInterval {
        try check(attempt); let value = timing.uptime(); try check(attempt); return value
    }
    private func request(_ commands: [(UInt8, UInt8)], timeout: Duration,
        consumeHold: Bool = true, send: (() -> Void)? = nil, attempt: Attempt) async throws -> Duml.Frame {
        try check(attempt)
        let pending = exchange.request(matching: commands, timeout: timeout, consumeHold: consumeHold,
            send: { [weak attempt] in if attempt?.isCurrent == true { send?() } })
        defer { pending.cancel(); if attempt.request === pending { attempt.request = nil } }
        try check(attempt)
        attempt.request = pending
        do {
            let frame = try await pending.value(); try check(attempt); return frame
        } catch {
            try check(attempt)
            if case DjiAppleControlExchange.Error.timeout = error { throw Failure.timeout }
            if case DjiAppleControlExchange.Error.disconnected = error { throw Failure.disconnected }
            throw error
        }
    }
    private func completePairing(_ attempt: Attempt) async throws {
        let frame = try await request([(7, 0x45), (7, 0x46)], timeout: .seconds(90), attempt: attempt)
        guard frame.cmdSet == 7, frame.cmdId == 0x45, frame.payload.count >= 2 else { return }
        switch frame.payload[1] {
        case 2: _ = try await request([(7, 0x46)], timeout: .seconds(90), attempt: attempt)
        case 6: throw Failure.pairingDeferred
        default: break
        }
    }
    private func connectBLE(_ camera: DJISighting, attempt: Attempt) async throws {
        for retry in 1...3 {
            try check(attempt)
            do { try await transport.bluetooth.connect(camera); try check(attempt); return }
            catch {
                try check(attempt)
                let dropped = transport.bluetooth.retryableDrop(error); try check(attempt)
                guard dropped, retry < 3 else { throw error }
                journal("ble: camera dropped the new link; retry \(retry) of 2")
                try await pause(.seconds(3), attempt: attempt)
            }
        }
    }
    private func run(_ camera: DJISighting, route: DJIConnectionRoute, attempt: Attempt) async throws {
        var timeline = ConnectTimeline(now: try uptime(attempt))
        for retry in 1...3 {
            try stage(.connectingBluetooth, attempt: attempt)
            try await connectBLE(camera, attempt: attempt)
            if retry == 1 { timeline.mark("gatt", now: try uptime(attempt)) }
            let frames = transport.bluetooth.frames(); try check(attempt)
            exchange.startBLEDrain(frames); try check(attempt)
            try stage(.pairing, attempt: attempt)
            try sendBLE(Commands.sessionWake(), attempt: attempt)
            try sendBLE(Commands.setPairingPin(pin: camera.model.pairingToken), attempt: attempt)
            try stage(.awaitingApproval, attempt: attempt)
            do { try await completePairing(attempt); break }
            catch Failure.timeout { throw Failure.pairingTimeout }
            catch Failure.pairingDeferred where retry < 3 {
                journal("pair: camera deferred pairing (00 06), retry \(retry) of 2")
                try check(attempt); exchange.stopBLEDrain()
                await transport.bluetooth.disconnectAndWait(); try check(attempt)
                try await pause(.seconds(3), attempt: attempt)
            }
        }
        timeline.mark("pair", now: try uptime(attempt))
        try check(attempt); heartbeat.start(monitorMaintenanceEnabled: false); try check(attempt)
        let saved = credentials.savedPath(camera, route); try check(attempt)
        if route != .cameraAccessPoint {
            guard route == .infrastructureNetwork || route == .phoneHotspot else { throw Failure.setupNotSaved }
            try await runStation(camera, route: route, saved: saved, attempt: attempt)
            timeline.mark("hs", now: try uptime(attempt))
            info(timeline.line()); try check(attempt)
            heartbeat.start(monitorMaintenanceEnabled: true); try check(attempt)
            return
        }
        try stage(.readingWiFi, attempt: attempt)
        if saved.mayBeInStationRole { try await restoreAccessPoint(attempt) }
        let known = credentials.resolveWiFi(camera); try check(attempt)
        let pathReady = transport.network.cameraPathReady(); try check(attempt)
        let skipSettle = !saved.mayBeInStationRole && pathReady && known.skipBLE
        if !skipSettle { try await pause(.milliseconds(200), attempt: attempt) }
        journal("creds: sending 0x53/0x10 (wake AP)")
        try check(attempt)
        try sendBLE(Commands.session5310(), attempt: attempt)
        do { _ = try await request([(0x53, 0x10)], timeout: .seconds(2), attempt: attempt) }
        catch Failure.timeout { journal("creds: 0x53/0x10 no reply \u{2014} continuing (Pocket 3 often answers e0/silent)") }
        catch Failure.disconnected { throw Failure.disconnectedDuring("0x53/0x10") }
        if !skipSettle { try await pause(.milliseconds(600), attempt: attempt) }
        let pair = try await wifiCredentials(camera, attempt: attempt)
        try check(attempt); try credentials.validateSSID(camera, pair.0, .join); try check(attempt)
        journal("creds: SSID \(pair.0) (\(pair.1.count) char password, \(known.skipBLE ? "cached" : "from BLE")) body=\(camera.model.name)")
        try check(attempt)
        let policy = credentials.joinPolicy(camera, pair.0, saved.isSaved); try check(attempt)
        try stage(.joiningWiFi, attempt: attempt)
        let others = credentials.joinPolicy(camera, pair.0, saved.isSaved).otherSSIDs; try check(attempt)
        journal("wifi: switch to \(pair.0) kicking \(others.joined(separator: ","))"); try check(attempt)
        do {
            try await transport.network.joinAccessPoint(.init(ssid: pair.0, password: pair.1,
                wpa3: camera.model.wpa3, otherSSIDs: others, persist: policy.persist,
                isCurrent: { [weak attempt] in attempt?.isCurrent == true }))
        } catch is CancellationError { throw CancellationError()
        } catch {
            try check(attempt)
            let rejected = transport.network.rejectsCredentials(error); try check(attempt)
            if known.skipBLE, rejected {
                journal("creds: join failed with cached creds \u{2014} dropping cache"); try check(attempt)
                credentials.rejectCached(camera, pair.0); try check(attempt)
            } else if known.skipBLE {
                journal("creds: join missed the camera address, keeping cache"); try check(attempt)
            }
            throw error
        }
        try check(attempt); credentials.persist(camera, pair.0, pair.1); try check(attempt)
        attempt.path.joinedSSID = pair.0
        try pathChanged(attempt)
        timeline.mark("path", now: try uptime(attempt))
        try stage(.openingDatalink, attempt: attempt)
        let existing = try observe(attempt).endpoint
        let endpoint: any DjiAppleConnectionEndpoint
        if let existing {
            let closed = existing.isClosed; try check(attempt)
            if CameraSoftAP.shouldReuseDatalink(isClosed: closed) { endpoint = existing }
            else { endpoint = try createEndpoint(camera, host: nil, hotspot: false, attempt: attempt) }
        } else { endpoint = try createEndpoint(camera, host: nil, hotspot: false, attempt: attempt) }
        attempt.endpoint = endpoint
        try await openAP(endpoint, attempt: attempt)
        timeline.mark("hs", now: try uptime(attempt))
        if try observe(attempt).initialLiveViewEnableSent == true {
            timeline.mark("enable", now: try uptime(attempt))
        }
        info(timeline.line()); try check(attempt)
        heartbeat.start(monitorMaintenanceEnabled: true); try check(attempt)
    }
    private func nextStationSequence() -> UInt16 {
        stationSequence &+= 1
        return stationSequence
    }
    private func exchangeBLE(_ frame: Duml.Frame, timeout: TimeInterval, attempt: Attempt)
        async throws -> Duml.Frame {
        try await request([(frame.cmdSet, frame.cmdId)], timeout: .seconds(timeout),
            consumeHold: false, send: { self.transport.bluetooth.send(frame) }, attempt: attempt)
    }
    private func restoreAccessPoint(_ attempt: Attempt) async throws {
        let reply = try? await exchangeBLE(
            MulticamCommands.stationMode(false, seq: nextStationSequence()), timeout: 12, attempt: attempt)
        try check(attempt)
        let accepted = reply?.payload == [0] || reply?.payload == [0, 0]
        journal("wifi: restore camera access point accepted=\(accepted)"); try check(attempt)
        let started = try wall(attempt)
        for _ in 0..<15 {
            let role = try? await exchangeBLE(
                MulticamCommands.wifiWorkMode(seq: nextStationSequence()), timeout: 4, attempt: attempt)
            try check(attempt)
            let hex = role?.payload.map { String(format: "%02x", $0) }.joined(separator: " ")
            let elapsed = try wall(attempt) - started
            journal("wifi: camera role after restore \(hex ?? "no reply") at \(String(format: "%.1f", elapsed)) s")
            try check(attempt)
            if role?.payload == [0, 0] { break }
            try? await pause(.seconds(1), attempt: attempt)
        }
        try check(attempt)
    }
    private func runStation(_ camera: DJISighting, route: DJIConnectionRoute, saved: SavedPath, attempt: Attempt)
        async throws {
        guard let network = saved.station else { throw Failure.setupNotSaved }
        let hotspot = route == .phoneHotspot
        try stage(.joiningWiFi, attempt: attempt)
        attempt.path.stationSSID = network.ssid
        try pathChanged(attempt)
        if let joined = attempt.path.joinedSSID {
            transport.network.leaveIfCurrent(joined, { [weak attempt] in attempt?.isCurrent == true })
            try check(attempt)
            attempt.path.joinedSSID = nil; try pathChanged(attempt)
        }
        if !hotspot {
            try stage(.joiningWiFi, text: "Joining \(network.ssid) on this iPhone", attempt: attempt)
            let address = try await transport.network.joinHost(network.ssid, network.password)
            try check(attempt)
            guard address != nil else { throw Failure.hostWiFi(network.ssid) }
        }
        if camera.model.family == .nano {
            try stage(.joiningWiFi, text: "Waking camera Wi-Fi", attempt: attempt)
            let wake = try await exchangeBLE(Commands.session5310(id: nextStationSequence()),
                timeout: 12, attempt: attempt)
            guard wake.payload == [1, 0, 0, 0] else { throw Failure.nanoWake }
            try await pause(.seconds(1), attempt: attempt)
        }
        let identity = try await exchangeBLE(Commands.getWifiSsid(id: nextStationSequence()),
            timeout: 12, attempt: attempt).payload
        var join = StationJoin(model: camera.model, ssid: network.ssid, password: network.password,
            hotspot: hotspot)
        join.probeExistingStation = true
        join.experimental = !MulticamSupport.hasPreview(camera.model)
        let outcome = try await join.run(identity: identity,
            exchange: { try await self.exchangeBLE($0, timeout: $1, attempt: attempt) },
            send: { frame in try? self.sendBLE(frame, attempt: attempt) },
            next: { attempt.isCurrent ? self.nextStationSequence() : self.stationSequence },
            status: { text in try? self.stage(.joiningWiFi, text: text, attempt: attempt) },
            hotspotReady: {
                guard attempt.isCurrent else { return false }
                let ready = self.transport.network.stationPathReady(true)
                return attempt.isCurrent && ready
            }, verifyOnNetwork: {
                try await self.openStation(camera, identity: identity, hotspot: hotspot, within: 0, attempt: attempt)
            }, log: { line in
                guard attempt.isCurrent else { return }
                self.journal("station: \(line)")
            }, sleep: { try await self.pause(.seconds($0), attempt: attempt) })
        try check(attempt)
        if outcome == .joined {
            try stage(.joiningWiFi, text: "Finding the camera on \(network.ssid)", attempt: attempt)
            guard try await openStation(camera, identity: identity, hotspot: hotspot,
                within: 60, attempt: attempt) else { throw Failure.stationCameraMissing(network.ssid) }
        }
        // The donor clears only progress; the registered native action already set live.
        try check(attempt); event(.progress(nil)); try check(attempt)
    }
    private func openStation(_ camera: DJISighting, identity: [UInt8], hotspot: Bool,
        within patience: TimeInterval, attempt: Attempt) async throws -> Bool {
        let deadline = try wall(attempt) + patience
        var sweep = 0
        repeat {
            sweep += 1
            if try await openStationOnce(camera, identity: identity, hotspot: hotspot, sweep: sweep,
                attempt: attempt) { return true }
            guard try wall(attempt) < deadline else { break }
            try await pause(.seconds(2), attempt: attempt)
        } while try wall(attempt) < deadline
        return false
    }
    private func openStationOnce(_ camera: DJISighting, identity: [UInt8], hotspot: Bool, sweep: Int,
        attempt: Attempt) async throws -> Bool {
        try check(attempt)
        let ready = transport.network.stationPathReady(hotspot); try check(attempt)
        guard ready else {
            journal("station: sweep \(sweep) no \(hotspot ? "hotspot" : "Wi-Fi") address")
            try check(attempt); return false
        }
        let known = attempt.path.stationHost.map { [$0] } ?? []
        let ssid = await transport.network.currentSSID(); try check(attempt)
        let phoneNetwork = ssid == nil ? "unnamed" : ssid == attempt.path.stationSSID ? "same" : "other"
        let started = try wall(attempt)
        var found: [String]
        do { found = try await transport.network.candidates(hotspot); try check(attempt) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try check(attempt)
            journal("station: sweep \(sweep) cannot scan this subnet (\(error.localizedDescription))")
            try check(attempt); found = []
        }
        let subnet = transport.network.subnetSize(hotspot); try check(attempt)
        let elapsed = try wall(attempt) - started
        journal("station: sweep \(sweep) phone=\(hotspot ? "hotspot" : phoneNetwork) hosts=\(subnet ?? 0) answering=\(found.count) known=\(known.count) in \(String(format: "%.1f", elapsed)) s")
        try check(attempt)
        for host in known + found.filter({ !known.contains($0) }) {
            try check(attempt)
            native.attach(nil, attempt.path, attempt); try check(attempt)
            let endpoint = try createEndpoint(camera, host: host, hotspot: hotspot, attempt: attempt)
            attempt.endpoint = endpoint
            do {
                try checkedEndpoint(endpoint, attempt: attempt)
                try await endpoint.open(identityOnly: true, afterHandshake: nil)
                try checkedEndpoint(endpoint, attempt: attempt)
                let reply = try await request([(7, 7)], timeout: .seconds(8), consumeHold: false,
                    send: { _ = endpoint.send(Commands.getWifiSsid(id: 0)) }, attempt: attempt)
                try checkedEndpoint(endpoint, attempt: attempt)
                guard reply.payload == identity else {
                    journal("station: an answering device is another camera"); try check(attempt)
                    continue
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try check(attempt)
                journal("station: an answering device did not open the datalink"); try check(attempt)
                continue
            }
            journal("station: camera identity verified on the network"); try check(attempt)
            attempt.path.stationHost = host; try pathChanged(attempt)
            try checkedEndpoint(endpoint, attempt: attempt)
            endpoint.completeRegistration(); try checkedEndpoint(endpoint, attempt: attempt)
            native.registered(endpoint, attempt.path, attempt); try checkedEndpoint(endpoint, attempt: attempt)
            return true
        }
        try check(attempt); native.attach(nil, attempt.path, attempt); try check(attempt)
        attempt.endpoint = nil
        return false
    }

    private func createEndpoint(_ camera: DJISighting, host: String?, hotspot: Bool, attempt: Attempt)
        throws -> any DjiAppleConnectionEndpoint {
        try check(attempt)
        let endpoint = transport.makeEndpoint(camera, host, hotspot)
        do {
            try check(attempt)
            native.attach(endpoint, attempt.path, attempt); try check(attempt)
            guard try observe(attempt).endpoint === endpoint else { throw CancellationError() }
            return endpoint
        } catch {
            // The factory creates an endpoint for this attempt. An adopted or handed-off
            // endpoint belongs to the host; retirement can close only the unadopted value.
            let generation = retirementGeneration
            let host = native.observe()
            if generation == retirementGeneration, host.endpoint !== endpoint {
                let closed = endpoint.isClosed
                if generation == retirementGeneration, !closed { endpoint.close() }
            }
            throw error
        }
    }
    private func checkedEndpoint(_ endpoint: any DjiAppleConnectionEndpoint, attempt: Attempt) throws {
        let host = try observe(attempt)
        guard host.endpoint === endpoint else { throw CancellationError() }
        let closed = endpoint.isClosed; try check(attempt)
        guard !closed else { throw CancellationError() }
    }
    private func openAP(_ endpoint: any DjiAppleConnectionEndpoint, attempt: Attempt) async throws {
        try checkedEndpoint(endpoint, attempt: attempt)
        var misses = 0
        while true {
            try check(attempt)
            do {
                try await endpoint.open(identityOnly: false, afterHandshake: { [weak self, attempt, weak endpoint] in
                    guard let self, let endpoint else { return }
                    do {
                        try self.checkedEndpoint(endpoint, attempt: attempt)
                        self.native.registered(endpoint, attempt.path, attempt)
                        try self.checkedEndpoint(endpoint, attempt: attempt)
                    } catch { return }
                })
                try checkedEndpoint(endpoint, attempt: attempt)
                return
            } catch is CancellationError { throw CancellationError()
            } catch {
                try check(attempt)
                let denied = transport.localNetworkDenied(error); try check(attempt)
                if denied { throw error }
                let pathReady = transport.network.cameraPathReady(); try check(attempt)
                if CameraSoftAP.shouldKickAfterHandshakeTimeout(pathReady: pathReady) { throw error }
                misses += 1
                if CameraSoftAP.shouldGiveUpOpenRetry(attempts: misses) {
                    info("session: handshake give-up after \(misses) opens"); try check(attempt)
                    throw error
                }
                info("session: handshake miss #\(misses) \u{2014} SoftAP up, retry (no kick)")
                try? await pause(.milliseconds(CameraSoftAP.handshakeRetryPauseMilliseconds), attempt: attempt)
            }
        }
    }
    private func wifiCredentials(_ camera: DJISighting, attempt: Attempt) async throws -> (String, String) {
        try check(attempt)
        let known = credentials.resolveWiFi(camera); try check(attempt)
        if known.skipBLE, let ssid = known.ssid, let password = known.password {
            journal("creds: skipping BLE GetSSID/GetPassword \u{2014} \(known.source) SSID \(ssid)")
            try check(attempt); return (ssid, password)
        }
        let advertised = camera.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = [known.ssid, advertised.isEmpty ? nil : advertised].compactMap { $0 }.first { !$0.isEmpty }
        let ssid: String
        if let stored = known.ssid, !stored.isEmpty, known.password == nil {
            info("creds: skipping GetSSID \u{2014} using \(known.source) SSID \(stored)")
            try check(attempt); ssid = stored
        }
        else {
            do { ssid = try await wifiString("GetSSID", set: 7, command: 7, cached: known.ssid,
                send: { self.transport.bluetooth.send(Commands.getWifiSsid()) }, attempt: attempt) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try check(attempt)
                if isDisconnect(error) { throw Failure.disconnectedDuring("GetSSID") }
                guard let fallback else { throw Failure.heldSession }
                do { try credentials.validateSSID(camera, fallback, .fallback); try check(attempt) }
                catch {
                    try check(attempt)
                    info("creds: GetSSID fallback \(fallback) belongs to another camera"); try check(attempt)
                    throw error
                }
                info("creds: GetSSID refused \u{2014} using SSID \(fallback)"); try check(attempt)
                ssid = fallback
            }
        }
        do {
            let password = try await wifiString("GetPassword", set: 7, command: 0x0e, cached: known.password,
                send: { self.transport.bluetooth.send(Commands.getWifiPassword()) }, attempt: attempt)
            return (ssid, password)
        } catch is CancellationError { throw CancellationError()
        } catch {
            try check(attempt)
            if isDisconnect(error) { throw Failure.disconnectedDuring("GetPassword") }
            if let password = known.password, !password.isEmpty {
                info("creds: GetPassword refused \u{2014} using \(known.source) password")
                try check(attempt); return (ssid, password)
            }
            throw Failure.heldSession
        }
    }
    private func wifiString(_ name: String, set: UInt8, command: UInt8, cached: String?,
        send: @escaping () -> Void, attempt: Attempt) async throws -> String {
        let deadline = try wall(attempt) + 12
        var last: Error = Failure.commandTimeout(name)
        var retries = 0
        while try wall(attempt) < deadline {
            retries += 1
            info("creds: \(name) attempt \(retries)"); try check(attempt)
            do {
                let frame = try await request([(set, command)], timeout: .seconds(4),
                    consumeHold: false, send: send, attempt: attempt)
                let status = frame.payload.first ?? 0xff
                let value = Duml.unpackStatusString(frame.payload)
                if !value.isEmpty {
                    journal("creds: \(name) ok (\(value.count) chars)"); try check(attempt); return value
                }
                if frame.payload.count <= 1 || (0xe0...0xef).contains(status) {
                    if let cached, !cached.isEmpty {
                        journal("creds: \(name) status=\(status) (\(frame.payload.count)B) \u{2014} using cached value")
                        try check(attempt); return cached
                    }
                    throw Failure.credentialsRefused(name, status)
                }
                journal("creds: \(name) empty reply (status=\(status))"); try check(attempt)
                last = Failure.credentialsEmpty(name)
            } catch Failure.timeout {
                journal("creds: \(name) attempt \(retries) timed out"); try check(attempt)
                last = Failure.commandTimeout(name)
            }
            catch Failure.disconnected { throw Failure.disconnectedDuring(name) }
            try await pause(.milliseconds(400), attempt: attempt)
        }
        if let cached, !cached.isEmpty {
            journal("creds: \(name) giving up \u{2014} using cached value")
            try check(attempt); return cached
        }
        throw last
    }
    private func isDisconnect(_ error: Error) -> Bool {
        guard let error = error as? Failure else { return false }
        switch error { case .disconnected, .disconnectedDuring: return true; default: return false }
    }

    /// Local task/request retirement only; explicit host close retains native motion/transport
    /// teardown. A delayed completion may retire only its own request, never a successor's.
    public func retire() {
        retirementGeneration &+= 1
        let old = current; current = nil
        old?.task?.cancel(); old?.request?.cancel()
        old?.task = nil; old?.request = nil
    }
}
