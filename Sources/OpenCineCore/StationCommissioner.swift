import Foundation

/// What a commissioner remembers of a camera it may have moved onto a station network: enough to
/// find it again nearby and return it to its own access point after the session closed. The
/// identifiers are the integration's (a Bluetooth peripheral id; `deviceAddress` where the
/// platform exposes a hardware address). Kotlin twin: `StationCameraRecord`, whose `id` is a
/// `String` on purpose: Apple names a Bluetooth peripheral by a UUID, Android discovery by text.
public struct StationCameraRecord: Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// The integration's model code; nil when the camera did not report one.
    public var modelId: Int?
    /// The camera's Bluetooth address where the platform exposes it; nil on iOS.
    public var deviceAddress: String?

    public init(id: UUID, name: String, modelId: Int?, deviceAddress: String? = nil) {
        self.id = id
        self.name = name
        self.modelId = modelId
        self.deviceAddress = deviceAddress
    }
}

/// How a camera's move onto a station network ended.
public enum StationCommissionOutcome: Equatable, Sendable {
    /// The camera accepted the network; the caller still finds and identifies it there.
    case joined
    /// The caller's `verifyOnNetwork` already found and identified the camera.
    case verified
}

/// One nearby camera's setup link (for example its Bluetooth link) while a commissioner moves it
/// onto a station network. The caller closes it when the move ended either way.
@MainActor
public protocol StationCommission: AnyObject {
    /// The integration's proof of this camera: a camera found on the network is this one only when
    /// its member link reports the same bytes (`MultiviewMemberLink.open`).
    func identity() async throws -> [UInt8]
    /// Moves the camera onto `network`. `progress` reports operator-facing steps.
    /// `verifyOnNetwork` lets the caller find and open the camera on the network while this link
    /// is still up; it returns true when it did.
    func join(
        _ network: StationNetwork, identity: [UInt8], experimental: Bool,
        progress: @escaping @MainActor (String) -> Void,
        verifyOnNetwork: @escaping @MainActor () async throws -> Bool
    ) async throws -> StationCommissionOutcome
    func close()
}

/// An integration that moves a nearby camera from its own access point onto a shared station
/// network and back. Optional: an integration whose cameras join a network only from their own
/// menus supplies none. Whether a camera may join a stage and shows a picture is the
/// integration's `MultiviewCameraPolicy`, which every integration supplies. Kotlin twin:
/// `StationCommissioner`.
@MainActor
public protocol StationCommissioner<Camera>: AnyObject {
    /// A nearby camera as the integration's discovery reports it.
    associatedtype Camera: Sendable

    /// The record kept in the cleanup journal before the camera leaves its access point.
    func record(_ camera: Camera) -> StationCameraRecord
    /// Opens the camera's setup link (pairing, waking its Wi-Fi). `progress` reports
    /// operator-facing steps.
    func connect(
        _ camera: Camera, progress: @escaping @MainActor (String) -> Void
    ) async throws -> any StationCommission
    /// Closes every commission link still open, connecting or not (the stage stopped). A network
    /// scan's link is left to finish returning its camera.
    func closeCommissions()
    /// Returns the camera to its own access point, with the integration's own bounded retry.
    /// False when the camera did not confirm; never throws, cancellation included.
    func restoreAccessPoint(_ record: StationCameraRecord) async -> Bool
    /// Whether this integration can list the networks a camera sees. Without it `scanNetworks`
    /// throws `StationScanUnsupported`.
    var scansNetworks: Bool { get }
    /// Networks `camera` can see, reported as they arrive. `beforeStationChange` runs before the
    /// camera leaves its access point (the caller journals the cleanup there and may refuse);
    /// `onRestored` reports whether it returned. The camera is always asked back, cancelled or not.
    func scanNetworks(
        through camera: Camera,
        beforeStationChange: @escaping @MainActor () throws -> Void,
        onRestored: @escaping @MainActor (Bool) -> Void,
        onFound: @escaping @MainActor (String) -> Void
    ) async throws
}

extension StationCommissioner {
    public var scansNetworks: Bool { false }

    public func scanNetworks(
        through camera: Camera,
        beforeStationChange: @escaping @MainActor () throws -> Void,
        onRestored: @escaping @MainActor (Bool) -> Void,
        onFound: @escaping @MainActor (String) -> Void
    ) async throws {
        throw StationScanUnsupported()
    }
}

/// `StationCommissioner.scanNetworks` of an integration that cannot list networks (its
/// `scansNetworks` is false). A plain error, never a cancellation, so a caller cannot mistake it
/// for its own task ending. Kotlin twin: `StationScanUnsupported`.
public struct StationScanUnsupported: Error, Equatable, Sendable {
    public init() {}
}
