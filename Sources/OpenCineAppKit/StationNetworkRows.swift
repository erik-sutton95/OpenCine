import Foundation
import OpenCineCore

/// The network page's rows, in the order it lists them: the network this device is on, the saved
/// ones, then the ones nearby (found by a camera, or by a computer's own Wi-Fi). Each name appears
/// once, in its first section; blank names and cameras' own access points are never listed.
/// Swift only: the Android wizard keeps its own lists and has no computer host.
public struct StationNetworkRows: Equatable, Sendable {
    public let current: String?
    public let saved: [String]
    public let nearby: [String]

    public init(
        current: String?, saved: [String], nearby: [String], isCameraNetwork: (String) -> Bool
    ) {
        var seen = Set<String>()
        func keep(_ name: String) -> Bool {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !isCameraNetwork(name)
            else { return false }
            return seen.insert(name).inserted
        }
        self.current = current.flatMap { keep($0) ? $0 : nil }
        self.saved = saved.filter(keep)
        self.nearby = nearby.filter(keep)
    }

    /// No network to choose from: the page leads with Other network and says why.
    public var isEmpty: Bool { current == nil && saved.isEmpty && nearby.isEmpty }

    /// The line under an empty list: a computer refused Location cannot name its Wi-Fi; otherwise
    /// the operator types the network's name.
    public static func emptyNote(host: HostDevice, locationDenied: Bool) -> String {
        host.isComputer && locationDenied
            ? "Allow Location for this module in System Settings to show the Mac’s Wi-Fi."
            : "Type the name of the Wi-Fi the cameras should join."
    }
}
