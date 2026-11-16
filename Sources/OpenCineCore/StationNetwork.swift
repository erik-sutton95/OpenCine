import Foundation

/// A shared network cameras and this phone meet on: a router or venue Wi-Fi, or this phone's
/// hotspot. The station-network wizard offers, prefills and joins it; the Multiview seams
/// (`StationCommissioner`, `StationHostPath`) carry it. The app keeps where it is stored.
/// Kotlin twin: `StationNetwork` in `com.opencapture.opencine.core`.
public struct StationNetwork: Equatable, Sendable {
    public var ssid: String
    public var password: String
    public var hotspot: Bool

    public init(ssid: String, password: String, hotspot: Bool) {
        self.ssid = ssid
        self.password = password
        self.hotspot = hotspot
    }
}
