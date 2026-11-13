import Foundation

/// The phone's side of a shared station network: its IPv4 address and netmask there, and joining
/// it. A platform adapter implements it (iOS `SharedWiFiPath` in `OpenCineApple`, Android
/// `SharedWiFiPath` in `:platform`); the Multiview coordinator and the integrations' station
/// setups use it so neither reads network interfaces itself. Kotlin twin: `StationHostPath`.
@MainActor
public protocol StationHostPath: AnyObject {
    /// This phone's IPv4 address on Wi-Fi (`hotspot` false) or on the hotspot it hosts; nil when
    /// it is not on that network.
    func address(hotspot: Bool) -> String?
    /// The netmask of the same interface; nil when it is not on that network.
    func netmask(hotspot: Bool) -> String?
    /// A router's Wi-Fi: joins it and returns this phone's address there, nil when the phone did
    /// not join. A hotspot is this phone's own: nothing is joined, and its current hotspot address
    /// is returned (nil until a client associates).
    func join(_ network: StationNetwork) async throws -> String?
}
