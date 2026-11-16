import Foundation
import OpenCineCore

/// One Multiview member's link to its Luna on the shared network (Kotlin twin: `LunaMemberLink`),
/// over its own connection (`LunaStationPort`, a `LunaCameraBackend` the app keeps for the member):
/// a greeting probe that opens no session, a LAN-only open that proves the camera by its serial,
/// the member's one common session, the camera's record reports, Luna's own picture repair and the
/// Auto LUT source. It never sends a record command; closing only disconnects. Bluetooth is used
/// only by a repair, inside the coordinator's Bluetooth turn. Hardware-untested.
@MainActor
public final class LunaMemberLink: MultiviewMemberLink {
    public typealias Camera = NearbyCamera

    /// The member's connection; the app reads its pictures and status from it.
    public let port: any LunaStationPort
    /// The member's one common session, for the member's lifetime: it follows every reconnect.
    public let lunaSession: LunaCameraSession
    public var session: any CameraSession { lunaSession }
    public var snapshot: CameraSnapshot { lunaSession.current }
    public private(set) var pictureHealth: PictureHealth = .starting
    public var onStatus: (@MainActor (MultiviewLinkStatus) -> Void)?
    public private(set) var recordReport: MultiviewRecordReport?
    /// A repair may reach the camera over Bluetooth, wait for its approval and move it onto the
    /// network again; the coordinator gives up on it after this long.
    public var repairDeadline: Duration { .seconds(120) }

    private let clock: HostClock
    private let conversion: @MainActor (String) -> String?
    private let preview: @MainActor (String) -> String
    /// What the last `open` reached: the camera, its address, the network and its serial.
    private var opened: (camera: NearbyCamera, address: String, network: StationNetwork, serial: String)?
    private var previewing = false
    private var previewStartedAt: MonotonicInstant?
    private var reportedLive = false
    private var stall = LunaFeedStall()
    private var recordObservedAt: MonotonicInstant?

    /// - Parameters:
    ///   - port: the member's own connection.
    ///   - clock: the coordinator's clock (record reports are stamped on it).
    ///   - conversion: the app's monitoring conversion for the color profile the picture carries (a
    ///     LUT title), nil when that profile needs none.
    ///   - preview: the color profile the picture carries for a recorded one: Luna's Color Recovery
    ///     may grade an I-Log recording's feed before it reaches the phone, so the Auto LUT follows
    ///     the app's preview rule (the one its Live View uses), never the recording profile alone.
    ///     By default the recorded profile itself.
    public init(
        port: any LunaStationPort, clock: HostClock = .live,
        conversion: @escaping @MainActor (_ colorProfile: String) -> String? = LunaMemberLink.noConversion,
        preview: @escaping @MainActor (_ recordedProfile: String) -> String = { $0 }
    ) {
        self.port = port
        self.clock = clock
        self.conversion = conversion
        self.preview = preview
        lunaSession = port.openSession()
    }

    /// The default `conversion`: the app grades nothing.
    public static func noConversion(_ colorProfile: String) -> String? { nil }

    public func probe(_ address: String, on network: StationNetwork) async -> Bool {
        await port.probeStation(address, on: Self.luna(network))
    }

    /// Opens the camera at `address`, LAN only, with the serial `identity` carries checked before
    /// anything else is sent. A Luna is always opened with its serial: without one the open is
    /// refused (the commissioner proves it over Bluetooth first). Control and live start are one
    /// step on Luna, so the picture starts here; `startPreview` reports it.
    public func open(
        _ camera: NearbyCamera, at address: String, expecting identity: [UInt8]?,
        on network: StationNetwork
    ) async throws -> [UInt8] {
        guard let serial = identity.flatMap(LunaMultiview.serial(identity:)) else {
            throw ConnectionFailure(
                reason: .unsupported, phase: .joiningNetwork, title: "Couldn’t connect",
                message: "This camera's serial is not known yet. Add it again.", actions: [.retry],
                code: "\(LunaCameraSession.integration.rawValue).multiview.no-serial")
        }
        close()
        onStatus?(.opening)
        let host = LunaStationHost(
            network: network.ssid, hotspot: network.hotspot, host: address, serial: serial)
        try await port.connect(to: LunaMultiview.monitorCamera(camera), at: host, on: Self.luna(network))
        opened = (camera, address, network, serial)
        return LunaMultiview.identity(serial: port.connectedSerial ?? serial)
    }

    public func startPreview(_ camera: NearbyCamera) async throws {
        guard opened != nil, port.isControlReady else {
            throw ConnectionFailure(
                reason: .linkLost, phase: .link, title: "Couldn’t connect",
                message: "The camera connection closed.", actions: [.retry],
                code: "\(LunaCameraSession.integration.rawValue).link.closed")
        }
        onStatus?(.controlling)
        previewing = true
        previewStartedAt = clock.now()
        reportedLive = false
        stall = LunaFeedStall()
        pictureHealth = .starting
        onStatus?(.awaitingPicture)
        observePicture()
    }

    /// Follows the picture and the camera's record report, once a second.
    public func keepalive() async {
        observeRecording()
        observePicture()
    }

    public func close() {
        port.disconnect()
        opened = nil
        previewing = false
        previewStartedAt = nil
        reportedLive = false
        recordReport = nil
        recordObservedAt = nil
        pictureHealth = .failed
    }

    /// Luna's picture repair, once a second while the member publishes. A stalled picture on an
    /// open link follows `LunaFeedStall` in place (keyframe, at most two live restarts); a stall it
    /// gives up on, or a lost control link, is repaired by finding the camera again: a camera that
    /// does not answer at its address is moved onto the network over Bluetooth (in the
    /// coordinator's Bluetooth turn), then the coordinator rejoins it, LAN only.
    public func repair(_ context: MultiviewRepairContext) -> MultiviewRepairStep {
        guard previewing, let opened else { return .healthy }
        if port.isControlReady {
            let silence = silenceSeconds()
            let now = Self.seconds(clock.now())
            switch stall.tick(silence: silence, now: now) {
            case .none:
                let healthy = silence <= LunaFeedStall.keyframeAfter
                context.observeHealth(healthy)
                return healthy ? .healthy : .handled
            case .requestKeyframe:
                context.observeHealth(false)
                let port = port
                Task { await port.requestKeyframe() }
                return .handled
            case .restartLive:
                context.observeHealth(false)
                // The picture reports Live again once it returns.
                reportedLive = false
                onStatus?(.reconnecting)
                return .repair { [weak self] in
                    guard let self else { return .done }
                    try? await self.port.restartLive()
                    self.stall.restartFinished()
                    return .done
                }
            case .escalate:
                context.observeHealth(false)
            }
        } else if !context.pathReady {
            // This phone left the shared network: the coordinator's path rule decides.
            return .healthy
        } else {
            context.observeHealth(false)
        }
        pictureHealth = .failed
        onStatus?(.reconnecting)
        return .repair { [weak self] in
            guard let self else { return .done }
            return await self.findAgain(opened.camera, address: opened.address, on: opened.network, context)
        }
    }

    /// The camera at its address answers: the coordinator rejoins it there. Otherwise it is moved
    /// onto the network again over Bluetooth, in the coordinator's turn, and then rejoined. A camera
    /// that refuses this phone waits for the operator.
    private func findAgain(
        _ camera: NearbyCamera, address: String, on network: StationNetwork,
        _ context: MultiviewRepairContext
    ) async -> MultiviewRepairResult {
        port.disconnect()
        if await port.probeStation(address, on: Self.luna(network)) { return .rejoin }
        guard context.running(), let release = await context.bluetoothTurn() else { return .done }
        defer { release() }
        do {
            _ = try await port.authorizeForStation(LunaMultiview.monitorCamera(camera))
            _ = try await port.moveOntoStation(Self.luna(network))
            return .rejoin
        } catch {
            port.disconnect()
            if error is CancellationError { return .done }
            if let failure = error as? ConnectionFailure,
                failure.reason == .notApproved || failure.reason == .heldElsewhere
            {
                return .waitForOperator(failure.message)
            }
            return .rejoin
        }
    }

    /// The Auto LUT follows what the picture carries: the camera's reported color profile through
    /// the app's `preview` rule, and the app's conversion for that.
    public var autoLUT: MultiviewAutoLUT {
        let profile = lunaSession.current.recordingFormat.profile.value.map(preview)
        return MultiviewAutoLUT(colorMode: profile, conversion: profile.flatMap(conversion))
    }

    private func observePicture() {
        guard previewing else { return }
        guard port.isControlReady else {
            pictureHealth = .failed
            return
        }
        let silence = silenceSeconds()
        if silence <= LunaFeedStall.keyframeAfter, port.secondsSinceVideo != nil {
            pictureHealth = .live
            if !reportedLive {
                reportedLive = true
                onStatus?(.live)
            }
        } else if port.secondsSinceVideo != nil {
            pictureHealth = .stalled
        }
    }

    /// The camera's own record state, stamped on the coordinator's clock when a new report arrived.
    private func observeRecording() {
        guard opened != nil, port.isControlReady else {
            recordReport = nil
            return
        }
        let reported = lunaSession.current.recording
        guard let at = reported.observedAt, at != recordObservedAt, let value = reported.value else {
            return
        }
        recordObservedAt = at
        recordReport = MultiviewRecordReport(recording: value == .recording, receivedAt: clock.date())
    }

    /// Seconds without video since the picture started (or since the last unit).
    private func silenceSeconds() -> TimeInterval {
        if let video = port.secondsSinceVideo { return video }
        guard let started = previewStartedAt else { return 0 }
        return Self.seconds(clock.now()) - Self.seconds(started)
    }

    private static func seconds(_ instant: MonotonicInstant) -> TimeInterval {
        let parts = instant.sinceReference.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func luna(_ network: StationNetwork) -> LunaStationNetwork {
        LunaStationNetwork(ssid: network.ssid, password: network.password, hotspot: network.hotspot)
    }
}
