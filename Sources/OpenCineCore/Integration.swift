import Foundation

// The integration contract: how shared code finds, pairs, connects and forgets cameras of any
// integration (SHELL-02). Integrations implement `CameraIntegration`; apps list them explicitly.
// Copy (step titles, failure text, prompt text) belongs to the integration; shared code renders it.

/// How the phone reaches a camera.
public enum RouteKind: String, Hashable, Codable, Sendable, CaseIterable {
    /// The phone joins the camera's own Wi-Fi access point.
    case cameraAccessPoint
    /// Phone and camera share a router network.
    case infrastructureNetwork
    /// The camera joins the phone's personal hotspot.
    case phoneHotspot
    /// Camera control over a USB interface.
    case usb
    /// A UVC/HDMI capture device: picture only.
    case captureDevice
}

/// One body an integration knows and how it is reached (the device and profile catalogue).
public struct CameraProfile: Hashable, Sendable {
    /// Namespaced, for example `org.example.cameras.model.0x22`.
    public var id: String
    public var title: String
    public var routes: Set<RouteKind>
    /// Routes the operator can add to a saved camera; non-empty offers "Add setup".
    public var addableRoutes: Set<RouteKind>

    public init(id: String, title: String, routes: Set<RouteKind>, addableRoutes: Set<RouteKind> = []) {
        self.id = id
        self.title = title
        self.routes = routes
        self.addableRoutes = addableRoutes
    }
}

public enum DiscoveryMode: Hashable, Sendable {
    /// Listen only: advertisements, multicast browse, local USB enumeration, and presence dials that
    /// cannot reach a camera's control service. Never a control-port connect, never protocol bytes.
    case passive
    /// May sweep and probe control ports. Only for an operator who is pairing or adding a setup.
    case active
}

/// One camera discovery sees now.
public struct NearbyCamera: Hashable, Sendable, Identifiable {
    /// Sighting key (a peripheral identifier, a hashed hardware address, host and path).
    public var id: String
    /// The saved camera this sighting is, when the integration knows.
    public var savedID: String?
    public var name: String
    public var model: String
    public var routes: Set<RouteKind>
    /// `nil` when the sighting carries no signal strength.
    public var signalBars: Int?
    /// `.unavailable(.busy)`: another device holds the camera.
    public var availability: Availability
    /// The `SavedRoute.key` of the saved camera's route this sighting reaches, when the integration knows.
    public var routeKey: String?

    public init(
        id: String, savedID: String? = nil, name: String, model: String, routes: Set<RouteKind>,
        signalBars: Int? = nil, availability: Availability = .available, routeKey: String? = nil
    ) {
        self.id = id
        self.savedID = savedID
        self.name = name
        self.model = model
        self.routes = routes
        self.signalBars = signalBars
        self.availability = availability
        self.routeKey = routeKey
    }
}

/// A route the operator is adding (from an add-setup slot). The secret goes to the integration's
/// credential store, never into the saved document, and never into a description.
public struct RouteDraft: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var kind: RouteKind
    public var network: String?
    public var secret: String?
    public var title: String?

    public init(kind: RouteKind, network: String? = nil, secret: String? = nil, title: String? = nil) {
        self.kind = kind
        self.network = network
        self.secret = secret
        self.title = title
    }

    public var description: String {
        "RouteDraft(\(kind), network: \(network ?? "nil"), secret: \(secret == nil ? "nil" : "<redacted>"))"
    }
    public var debugDescription: String { description }
}

public enum ConnectTarget: Hashable, Sendable {
    case saved(SavedCamera, route: ConnectionRouteID)
    case nearby(NearbyCamera)
    /// Provisioning a new route on a saved camera.
    case addRoute(SavedCamera, RouteDraft)

    /// The camera an attempt is for: the saved id, else the sighting's saved id, else its key.
    /// At most one attempt per camera is live.
    public var cameraID: String {
        switch self {
        case .saved(let camera, _), .addRoute(let camera, _): camera.id
        case .nearby(let nearby): nearby.savedID ?? nearby.id
        }
    }
}

/// One step of an attempt's plan, in integration copy.
public struct ConnectionStep: Hashable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String = "") {
        self.title = title
        self.detail = detail
    }
}

public struct ConnectionProgress: Hashable, Sendable {
    public var attempt: ConnectionAttemptID
    /// The same phase the session's `ConnectionState` carries.
    public var phase: ConnectionPhase
    /// This attempt's plan (it depends on the route).
    public var steps: [ConnectionStep]
    /// Index into `steps` of the step running now.
    public var current: Int
    /// Live text, for example the network being joined.
    public var note: String?

    public init(
        attempt: ConnectionAttemptID, phase: ConnectionPhase, steps: [ConnectionStep], current: Int,
        note: String? = nil
    ) {
        self.attempt = attempt
        self.phase = phase
        self.steps = steps
        self.current = current
        self.note = note
    }
}

/// An integration-owned prompt type, rendered by the app's prompt slot. It carries its own typed
/// reply closures; `fallbackText` is shown when no slot renders it.
public protocol IntegrationPrompt: Sendable {
    var fallbackText: String { get }
}

/// An explicit operator decision, presented once by the shell for its current source lifetime.
public protocol ConfirmationPrompt: IntegrationPrompt {
    var confirmationID: String { get }
    var confirmationTitle: String { get }
    var confirmTitle: String { get }
    var cancelTitle: String { get }
    var confirm: @MainActor @Sendable () -> Void { get }
    var cancel: @MainActor @Sendable () -> Void { get }
}

/// Something the operator must do for the attempt to continue.
public enum ConnectionPrompt: Sendable {
    /// Approve the connection on the camera; the text is integration copy.
    case approveOnCamera(String)
    /// Accept the phone's prompt to join `network`; the text is integration copy.
    case acceptNetworkJoin(network: String, String)
    case integration(any IntegrationPrompt)

    public var text: String {
        switch self {
        case .approveOnCamera(let text), .acceptNetworkJoin(_, let text): text
        case .integration(let prompt): prompt.fallbackText
        }
    }
}

/// Why an attempt ended without a camera, with integration copy and what the operator can do.
public struct ConnectionFailure: Error, Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        case permission(Permission)
        case radioOff(Radio)
        case notFound
        case timedOut
        case notApproved
        case credentialsRejected
        /// Another device holds the camera.
        case heldElsewhere
        case wrongCamera
        case joinFailed
        case linkLost
        case unsupported
        case cancelled
        case other
    }

    public enum Permission: Hashable, Sendable {
        case bluetooth
        case localNetwork
        case location
        case nearbyDevices
        case usb
    }

    public enum Radio: Hashable, Sendable {
        case bluetooth
        case wifi
    }

    public var reason: Reason
    /// The phase the attempt was in; `nil` when it failed before one started.
    public var phase: ConnectionPhase?
    public var title: String
    public var message: String
    public var actions: [RecoveryAction]
    /// Stable diagnostics code, for example `org.example.cameras.link.silent`.
    public var code: String

    public init(
        reason: Reason, phase: ConnectionPhase? = nil, title: String, message: String,
        actions: [RecoveryAction], code: String
    ) {
        self.reason = reason
        self.phase = phase
        self.title = title
        self.message = message
        self.actions = actions
        self.code = code
    }
}

/// Thrown, a failure reads as its message, so a caller that shows `localizedDescription` keeps
/// the integration's copy.
extension ConnectionFailure: LocalizedError {
    public var errorDescription: String? { message }
}

public enum RecoveryAction: Hashable, Sendable {
    case retry
    case useRoute(ConnectionRouteID)
    case editRoute(ConnectionRouteID)
    case pairAgain
    case openSettings
    /// An integration-only action, for example taking over a camera another device holds.
    case integration(id: String, title: String)
}

public enum ConnectionEvent: Sendable {
    case progress(ConnectionProgress, prompt: ConnectionPrompt?)
    /// Terminal.
    case connected(ConnectedCamera)
    /// Terminal.
    case failed(ConnectionFailure)
}

/// What a successful attempt produces.
public struct ConnectedCamera: Sendable {
    /// The record to upsert; the integration applied its save rules.
    public var saved: SavedCamera
    public var session: any CameraSession
    public var services: CameraServices

    public init(saved: SavedCamera, session: any CameraSession, services: CameraServices = .init()) {
        self.saved = saved
        self.session = session
        self.services = services
    }
}

/// Typed optional services of a connected camera, looked up by type, so Core never names the
/// module that declares one.
public struct CameraServices: Sendable {
    private var services: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    public subscript<S>(_ type: S.Type) -> S? { services[ObjectIdentifier(type)] as? S }

    public mutating func register<S>(_ service: S, as type: S.Type) where S: Sendable {
        services[ObjectIdentifier(type)] = service
    }
}

/// One camera integration as shared code sees it. Apps list their integrations explicitly.
@MainActor
public protocol CameraIntegration: AnyObject {
    /// Registration and diagnostics only: shared code never chooses behavior from it.
    nonisolated var id: IntegrationID { get }
    nonisolated var profiles: [CameraProfile] { get }
    nonisolated var discoveryModes: Set<DiscoveryMode> { get }
    /// The latest nearby list per element; cancelling the consumer stops discovery. A mode not in
    /// `discoveryModes` finishes at once. In `.passive` it never opens a control-port connection
    /// or sends protocol bytes.
    func discover(_ mode: DiscoveryMode) -> AsyncStream<[NearbyCamera]>
    /// Whether discovery is running now: `false` while the radio is off, the permission is denied
    /// or the last scan failed, so the pages never claim to scan when nothing can (IA-336). The
    /// default reports running once for an integration that cannot tell.
    var discoveryRunning: AsyncStream<Bool> { get }
    /// One attempt; cancelling the consumer cancels it. `.connected` and `.failed` are terminal.
    /// Events from an older attempt are never emitted after a newer attempt for the same camera
    /// (`ConnectTarget.cameraID`) starts.
    func connect(_ target: ConnectTarget) -> AsyncStream<ConnectionEvent>
    /// Drops what the integration stores per camera (route credentials). Never the per-install
    /// identity (an approval or pairing identity shared by every camera).
    func forget(_ camera: SavedCamera) async
}

extension CameraIntegration {
    /// An integration that cannot tell whether its radio can scan keeps today's status.
    public var discoveryRunning: AsyncStream<Bool> {
        AsyncStream<Bool> { continuation in
            continuation.yield(true)
            continuation.finish()
        }
    }
}
