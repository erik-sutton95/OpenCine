import Foundation
import OpenCineCore

/// The persisted part of a group: slot order, names, the device and route each slot reconnects
/// through, and the staged slot. Live sessions, pictures and authority are never persisted. The
/// app stores the encoded value wherever it likes and recreates entries with the saved IDs.
public struct MulticamLayout: Hashable, Codable, Sendable {
    public struct Slot: Hashable, Codable, Sendable {
        public var entry: MonitorEntryID
        public var name: String
        public var device: CameraDeviceID?
        public var route: ConnectionRouteID?

        public init(
            entry: MonitorEntryID, name: String, device: CameraDeviceID? = nil,
            route: ConnectionRouteID? = nil
        ) {
            self.entry = entry
            self.name = name
            self.device = device
            self.route = route
        }
    }

    /// Bump on an incompatible change and migrate older values when decoding.
    public var version = 1
    public var slots: [Slot]
    public var stage: MonitorEntryID?

    public init(slots: [Slot], stage: MonitorEntryID? = nil) {
        self.slots = slots
        self.stage = stage
    }

    /// The layout of `group`. Routes come from the app, which knows how each entry connected.
    public init(_ group: MulticamGroup, routes: [MonitorEntryID: ConnectionRouteID] = [:]) {
        slots = group.entries.map {
            Slot(entry: $0.id, name: $0.name, device: $0.device, route: routes[$0.id])
        }
        stage = group.stage
    }
}
