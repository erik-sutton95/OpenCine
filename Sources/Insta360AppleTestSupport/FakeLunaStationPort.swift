import Foundation
import Insta360Apple
import OpenCineCore

/// A scripted Luna connection behind the Multiview pieces, for tests: it records every step a
/// commissioner or member link asks of it, answers from what the test set, and backs its session
/// with a `FakeLuna`. Like the backend, a new authorization or connect, and `disconnect()`, end the
/// one before.
@MainActor
public final class FakeLunaStationPort: LunaStationPort {
    /// One thing the port was asked to do, in order.
    public enum Step: Equatable, Sendable {
        case authorize(UUID)
        case move(LunaStationNetwork)
        case probe(String)
        case connect(UUID, host: String, serial: String)
        case returnToAccessPoint(UUID)
        case keyframe
        case restartLive
        case disconnect
    }

    public var stationHostsInUse: (@MainActor () -> Set<String>)?
    /// The serial Bluetooth reads; `authorizeFailure` is thrown instead when set.
    public var serial = "LUNA-A"
    public var authorizeFailure: Error?
    /// What the move answers: the reported address, or `moveFailure`.
    public var reportedAddress: String?
    public var moveFailure: Error?
    /// Hosts where a Luna answers the probe.
    public var answering: Set<String> = []
    /// The serial of the camera at each host; a connect to a host not listed throws not found.
    public var cameras: [String: String] = [:]
    /// What the next returns answer, in order; `.returned` once empty.
    public var returns: [LunaAccessPointReturn] = []
    /// Runs inside each Bluetooth step and connect before it answers (a test holds it on a gate).
    public var during: (@MainActor (Step) async -> Void)?
    public var secondsSinceVideo: TimeInterval?
    public private(set) var isControlReady = false
    public private(set) var connectedSerial: String?
    public private(set) var steps: [Step] = []
    /// Whether the Bluetooth link `authorizeForStation` opened is still open.
    public private(set) var bluetoothOpen = false
    /// Sessions this port opened.
    public private(set) var sessionsOpened = 0
    public let camera = FakeLuna()
    private var session: LunaCameraSession?

    public init() {}

    public func authorizeForStation(_ camera: MonitorCamera) async throws -> String {
        disconnect()
        steps.append(.authorize(camera.id))
        await during?(.authorize(camera.id))
        try Task.checkCancellation()
        if let authorizeFailure { throw authorizeFailure }
        bluetoothOpen = true
        return serial
    }

    public func moveOntoStation(_ network: LunaStationNetwork) async throws -> String? {
        guard bluetoothOpen else {
            throw FakeLunaStationPort.failure(.other, "station.not-authorized")
        }
        steps.append(.move(network))
        await during?(.move(network))
        bluetoothOpen = false
        if let moveFailure { throw moveFailure }
        return reportedAddress
    }

    public func probeStation(_ host: String, on network: LunaStationNetwork) async -> Bool {
        steps.append(.probe(host))
        return answering.contains(host)
    }

    public func connect(
        to camera: MonitorCamera, at host: LunaStationHost, on network: LunaStationNetwork
    ) async throws {
        if (stationHostsInUse?() ?? []).contains(host.host) {
            throw FakeLunaStationPort.failure(.other, "station.host-in-use")
        }
        disconnect()
        steps.append(.connect(camera.id, host: host.host, serial: host.serial))
        let step = Step.connect(camera.id, host: host.host, serial: host.serial)
        await during?(step)
        try Task.checkCancellation()
        guard let found = cameras[host.host] else {
            throw FakeLunaStationPort.failure(.notFound, "station.known-host-silent")
        }
        guard found == host.serial else {
            throw FakeLunaStationPort.failure(.wrongCamera, "wifi.serial-mismatch")
        }
        connectedSerial = found
        isControlReady = true
        secondsSinceVideo = 0
        session?.linkChanged(.streaming, serial: found)
    }

    public func returnToAccessPoint(cameraID: UUID) async throws -> LunaAccessPointReturn {
        disconnect()
        steps.append(.returnToAccessPoint(cameraID))
        await during?(.returnToAccessPoint(cameraID))
        try Task.checkCancellation()
        return returns.isEmpty ? .returned : returns.removeFirst()
    }

    public func openSession() -> LunaCameraSession {
        sessionsOpened += 1
        let next = camera.makeSession()
        session = next
        return next
    }

    public func requestKeyframe() async { steps.append(.keyframe) }

    public func restartLive() async throws {
        steps.append(.restartLive)
        await during?(.restartLive)
    }

    public func disconnect() {
        guard bluetoothOpen || isControlReady || connectedSerial != nil else { return }
        steps.append(.disconnect)
        bluetoothOpen = false
        isControlReady = false
        connectedSerial = nil
        secondsSinceVideo = nil
        session?.linkChanged(.idle, serial: nil)
    }

    /// A Luna connection failure with `code`, as the backend names it.
    public static func failure(_ reason: ConnectionFailure.Reason, _ code: String) -> ConnectionFailure {
        ConnectionFailure(
            reason: reason, phase: .joiningNetwork, title: "Couldn't connect", message: code,
            actions: [.retry], code: "\(LunaCameraSession.integration.rawValue).\(code)")
    }

    /// The control link dropped (the camera left the network): nothing was asked of the port.
    public func dropLink() {
        isControlReady = false
        connectedSerial = nil
        session?.linkChanged(.idle, serial: nil)
    }
}
