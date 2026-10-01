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
    public enum Kind: Hashable, Sendable {
        /// The phone joins the camera's own Wi-Fi access point (one association per phone).
        case cameraAccessPoint
        /// Phone and camera share a router or hotspot.
        case infrastructureNetwork
        /// Camera control (PTP) over a USB interface.
        case usb
        /// A UVC/HDMI capture device: picture only, no camera control.
        case captureCard
    }

    public var kind: Kind
    public var picture: Bool
    public var control: Bool
    /// ponytail: rough unmeasured estimate for admission budgets; measure per route on hardware.
    public var bitsPerSecond: Int

    public init(_ kind: Kind, picture: Bool, control: Bool, bitsPerSecond: Int = 0) {
        self.kind = kind
        self.picture = picture
        self.control = control
        self.bitsPerSecond = bitsPerSecond
    }

    /// The admission request for one entry on this route. `resource` names the network (SSID) or
    /// USB interface the operator chose.
    public func request(
        entry: MonitorEntryID, device: CameraDeviceID?, resource: String
    ) -> ResourceRequest {
        let claim: ResourceClaim =
            switch kind {
            case .cameraAccessPoint: .cameraAccessPoint(network: resource)
            case .infrastructureNetwork: .infrastructureNetwork(resource)
            case .usb, .captureCard: .usbInterface(resource)
            }
        return ResourceRequest(
            entry: entry, device: device, claims: [claim], bitsPerSecond: bitsPerSecond,
            decoders: picture ? 1 : 0)
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
/// Main-actor isolated only because `DJICameraSessionAdapter.integration` and
/// `NikonCameraSession.integration` are (their classes are `@MainActor`; Luna's is `nonisolated`).
/// See README.md, Seam findings, F5.
@MainActor
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
        routes: [RouteOffer(.captureCard, picture: true, control: false, bitsPerSecond: 0)])

    // MARK: Sessions, one typed constructor per integration

    /// The DJI common session over the app's DJI session (`DJIControlPort`). The adapter holds the
    /// port unowned, so the caller keeps the port alive, as an app's session object would.
    public static func djiSession(over port: any DJIControlPort) -> DJICameraSessionAdapter {
        DJICameraSessionAdapter(session: port)
    }

    /// The Nikon common session over the app's control service (`NikonControlDriver`).
    public static func nikonSession(
        over driver: any NikonControlDriver, serialNumber: String,
        recordObservationTimeout: Duration = .seconds(5)
    ) -> NikonCameraSession {
        NikonCameraSession(
            driver: driver, serialNumber: serialNumber,
            recordObservationTimeout: recordObservationTimeout)
    }

    /// The Luna backend with the harness's own names, so it never reads OpenInstaCine's saved
    /// camera credentials.
    public static let lunaConfiguration = LunaIntegrationConfiguration(
        keychainService: "org.opencapture.harness.luna", appName: "OpenCine Harness",
        logPrefix: "harness")

    public static func lunaBackend() -> LunaCameraBackend {
        LunaCameraBackend(configuration: lunaConfiguration)
    }
}
