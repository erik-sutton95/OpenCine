import Foundation
import OpenCineCore
import OpenCineDJI

/// The native datalink operations used by one connection run. Production and SIMULATED peers
/// cross the same interface; picture demand, controls and presentation are deliberately absent.
@MainActor
public protocol DjiAppleConnectionEndpoint: AnyObject {
    var isClosed: Bool { get }
    func open(identityOnly: Bool, afterHandshake: (@MainActor () async -> Void)?) async throws
    @discardableResult func send(_ frame: Duml.Frame) -> UInt16
    func completeRegistration()
    func close()
}

/// Actual OS operations, grouped by the varying Bluetooth and network adapters.
@MainActor
public struct DjiAppleConnectionTransport {
    @MainActor public struct Bluetooth {
        public var connect: (DJISighting) async throws -> Void
        public var frames: () -> AsyncStream<Duml.Frame>
        public var send: (Duml.Frame) -> Void
        public var disconnectAndWait: () async -> Void
        public var retryableDrop: (Error) -> Bool
        public init(connect: @escaping (DJISighting) async throws -> Void,
            frames: @escaping () -> AsyncStream<Duml.Frame>, send: @escaping (Duml.Frame) -> Void,
            disconnectAndWait: @escaping () async -> Void, retryableDrop: @escaping (Error) -> Bool) {
            self.connect = connect; self.frames = frames; self.send = send
            self.disconnectAndWait = disconnectAndWait; self.retryableDrop = retryableDrop
        }
    }

    public struct AccessPointJoin: Sendable {
        public var ssid: String
        public var password: String
        public var wpa3: Bool
        public var otherSSIDs: [String]
        public var persist: Bool
        /// The requesting attempt's validity, checked before any queued hotspot mutation runs.
        public var isCurrent: CameraNetworkIsCurrent
        public init(ssid: String, password: String, wpa3: Bool, otherSSIDs: [String], persist: Bool,
            isCurrent: @escaping CameraNetworkIsCurrent = { true }) {
            self.ssid = ssid; self.password = password; self.wpa3 = wpa3
            self.otherSSIDs = otherSSIDs; self.persist = persist; self.isCurrent = isCurrent
        }
    }

    @MainActor public struct Network {
        public var cameraPathReady: () -> Bool
        public var stationPathReady: (_ hotspot: Bool) -> Bool
        public var joinAccessPoint: (AccessPointJoin) async throws -> Void
        public var rejectsCredentials: (Error) -> Bool
        public var joinHost: (_ ssid: String, _ password: String) async throws -> String?
        public var leave: (String) -> Void
        /// Leaves only while the requesting attempt is still current, also when queued behind a
        /// native join that is still pending.
        public var leaveIfCurrent: (String, @escaping CameraNetworkIsCurrent) -> Void
        public var currentSSID: () async -> String?
        public var candidates: (_ hotspot: Bool) async throws -> [String]
        public var subnetSize: (_ hotspot: Bool) -> Int?
        public init(cameraPathReady: @escaping () -> Bool,
            stationPathReady: @escaping (Bool) -> Bool,
            joinAccessPoint: @escaping (AccessPointJoin) async throws -> Void,
            rejectsCredentials: @escaping (Error) -> Bool,
            joinHost: @escaping (String, String) async throws -> String?, leave: @escaping (String) -> Void,
            currentSSID: @escaping () async -> String?, candidates: @escaping (Bool) async throws -> [String],
            subnetSize: @escaping (Bool) -> Int?,
            leaveIfCurrent: ((String, @escaping CameraNetworkIsCurrent) -> Void)? = nil) {
            self.cameraPathReady = cameraPathReady; self.stationPathReady = stationPathReady
            self.joinAccessPoint = joinAccessPoint; self.rejectsCredentials = rejectsCredentials
            self.joinHost = joinHost; self.leave = leave; self.currentSSID = currentSSID
            self.leaveIfCurrent = leaveIfCurrent ?? { ssid, current in if current() { leave(ssid) } }
            self.candidates = candidates; self.subnetSize = subnetSize
        }
    }

    public var bluetooth: Bluetooth
    public var network: Network
    public var makeEndpoint: (_ camera: DJISighting, _ host: String?, _ hotspot: Bool) -> any DjiAppleConnectionEndpoint
    public var localNetworkDenied: (Error) -> Bool
    public init(bluetooth: Bluetooth, network: Network,
        makeEndpoint: @escaping (DJISighting, String?, Bool) -> any DjiAppleConnectionEndpoint,
        localNetworkDenied: @escaping (Error) -> Bool) {
        self.bluetooth = bluetooth; self.network = network; self.makeEndpoint = makeEndpoint
        self.localNetworkDenied = localNetworkDenied
    }
}

/// Wall deadlines and monotonic diagnostics retain their distinct native clocks.
@MainActor
public struct DjiAppleConnectionTiming {
    public var wallNow: () -> TimeInterval
    public var uptime: () -> TimeInterval
    public var sleep: (Duration) async throws -> Void
    public init(wallNow: @escaping () -> TimeInterval, uptime: @escaping () -> TimeInterval,
        sleep: @escaping (Duration) async throws -> Void) {
        self.wallNow = wallNow; self.uptime = uptime; self.sleep = sleep
    }
    public static var continuous: Self {
        .init(wallNow: { Date.timeIntervalSinceReferenceDate },
            uptime: { ProcessInfo.processInfo.systemUptime }, sleep: { try await Task.sleep(for: $0) })
    }
}

