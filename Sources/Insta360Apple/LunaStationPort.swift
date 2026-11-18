import Foundation
import OpenCineCore

/// What Luna's Multiview pieces (`LunaStationCommissioner`, `LunaMemberLink`) need from one camera
/// connection: the two Bluetooth steps of a station move, the LAN probe and LAN-only open, the
/// return to the access point and the live picture's clocks. `LunaCameraBackend` is the one
/// implementation; tests script `FakeLunaStationPort`. Kotlin twin: `LunaStationPort`.
@MainActor
public protocol LunaStationPort: AnyObject {
    /// Hosts other connections of this app hold on the shared network; no search or open of this
    /// port reaches them.
    var stationHostsInUse: (@MainActor () -> Set<String>)? { get set }
    /// Bluetooth, approval on the camera and the credential read; returns the serial. The
    /// authorized link stays open for `moveOntoStation(_:)` until `disconnect()`.
    func authorizeForStation(_ camera: MonitorCamera) async throws -> String
    /// The authorized camera joins `network`; Bluetooth closes. Returns any address it reported.
    func moveOntoStation(_ network: LunaStationNetwork) async throws -> String?
    /// Whether a Luna answers its control port at `host`, without a session.
    func probeStation(_ host: String, on network: LunaStationNetwork) async -> Bool
    /// Opens the camera at `host`, LAN only, checking `host.serial`, and starts its picture.
    func connect(to camera: MonitorCamera, at host: LunaStationHost, on network: LunaStationNetwork)
        async throws
    /// One try at asking the camera back onto its own access point over Bluetooth.
    func returnToAccessPoint(cameraID: UUID) async throws -> LunaAccessPointReturn
    /// The connection's common session; it follows every later connect of this port.
    func openSession() -> LunaCameraSession
    /// The serial the open control link proved; nil while none is open.
    var connectedSerial: String? { get }
    /// The control link is open and live started.
    var isControlReady: Bool { get }
    /// Seconds since the last video unit; nil before the first.
    var secondsSinceVideo: TimeInterval? { get }
    func requestKeyframe() async
    func restartLive() async throws
    /// Ends the connection (Bluetooth and control link). Never a camera command but stop-live.
    func disconnect()
}

extension LunaCameraBackend: LunaStationPort {}
