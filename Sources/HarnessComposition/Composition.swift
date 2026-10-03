import Foundation
import Insta360Apple
import OpenCineCore
import OpenCineDJI
import OpenCineMulticam
import OpenCineNikon

/// One connection route an integration offers, with the host resource it claims (plan 8.4).
/// Routes describe; they never provision. Every route here is hardware-untested in combination
/// (docs/TOPOLOGY.md).
public struct RouteOffer: Hashable, Sendable {
    public var kind: RouteKind
    public var picture: Bool
    public var control: Bool
    /// ponytail: rough unmeasured estimate for admission budgets; measure per route on hardware.
    public var bitsPerSecond: Int

    public init(_ kind: RouteKind, picture: Bool, control: Bool, bitsPerSecond: Int = 0) {
        self.kind = kind
        self.picture = picture
        self.control = control
        self.bitsPerSecond = bitsPerSecond
    }

    /// The admission request for one entry on this route, through OpenCineMulticam's route
    /// claims. `resource` names the network (SSID) or USB interface the operator chose.
    public func request(
        entry: MonitorEntryID, device: CameraDeviceID?, resource: String
    ) -> ResourceRequest {
        ResourceRequest(
            entry: entry, device: device,
            route: SavedRoute(key: kind.rawValue, kind: kind, network: resource), picture: picture,
            bitsPerSecond: bitsPerSecond)
    }
}

/// One integration as the composition root lists it (plan 9.1): identity and routes. Sessions are
/// built by the typed functions on `Composition`, because each integration needs its own port.
public struct IntegrationFactory: Hashable, Sendable {
    public var id: IntegrationID
    public var routes: [RouteOffer]
}

/// The composition root: the explicit list of integration factories (plan 1.3 and 9.1). No
/// registry, no plugin loading, no dependency-injection framework. This is the only module of the
/// harness that names a manufacturer; HarnessEngine, OpenCineMulticam and OpenCineCore never do.
///
/// The factory list is nonisolated (every integration ID is `nonisolated`, F5 fixed); only the
/// session constructors are main-actor isolated, because the sessions are.
public enum Composition {
    public static let factories: [IntegrationFactory] = [dji, nikon, luna, hdmiCapture]

    /// DJI Osmo Pocket: camera access point (SoftAP) or a station network the camera joins.
    public static let dji = IntegrationFactory(
        id: DJICameraSessionAdapter.integration,
        routes: [
            RouteOffer(.cameraAccessPoint, picture: true, control: true, bitsPerSecond: 20_000_000),
            RouteOffer(.infrastructureNetwork, picture: true, control: true, bitsPerSecond: 20_000_000),
        ])

    /// Nikon Z: camera access point, infrastructure network (PTP/IP with JPEG live view) or USB.
    public static let nikon = IntegrationFactory(
        id: NikonCameraSession.integration,
        routes: [
            RouteOffer(.cameraAccessPoint, picture: true, control: true, bitsPerSecond: 8_000_000),
            RouteOffer(.infrastructureNetwork, picture: true, control: true, bitsPerSecond: 8_000_000),
            RouteOffer(.usb, picture: true, control: true, bitsPerSecond: 8_000_000),
        ])

    /// Insta360 Luna: its own access point only. Its route supports no shared network today, so it
    /// is never offered as one (plan 8.4).
    public static let luna = IntegrationFactory(
        id: LunaCameraSession.integration,
        routes: [
            RouteOffer(.cameraAccessPoint, picture: true, control: true, bitsPerSecond: 15_000_000)
        ])

    /// A UVC/HDMI capture device: picture only, no camera behind it as far as the app knows.
    public static let hdmiCapture = IntegrationFactory(
        id: IntegrationID("org.opencapture.harness.uvc-capture"),
        routes: [RouteOffer(.captureDevice, picture: true, control: false, bitsPerSecond: 0)])

    // MARK: Sessions, one typed constructor per integration

    /// The DJI common session over the app's DJI session (`DJIControlPort`). The adapter holds the
    /// port unowned, so the caller keeps the port alive, as an app's session object would.
    @MainActor
    public static func djiSession(over port: any DJIControlPort) -> DJICameraSessionAdapter {
        DJICameraSessionAdapter(session: port)
    }

    /// The Nikon common session over the app's control service (`NikonControlDriver`).
    @MainActor
    public static func nikonSession(
        over driver: any NikonControlDriver, serialNumber: String,
        recordObservationTimeout: Duration = .seconds(5),
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now
    ) -> NikonCameraSession {
        NikonCameraSession(
            driver: driver, serialNumber: serialNumber,
            recordObservationTimeout: recordObservationTimeout, now: now)
    }

    /// The Luna backend with the harness's own names, so it never reads OpenInstaCine's saved
    /// camera credentials.
    public static let lunaConfiguration = LunaIntegrationConfiguration(
        keychainService: "org.opencapture.harness.luna", appName: "OpenCine Harness",
        logPrefix: "harness")

    @MainActor
    public static func lunaBackend() -> LunaCameraBackend {
        LunaCameraBackend(configuration: lunaConfiguration)
    }
}
