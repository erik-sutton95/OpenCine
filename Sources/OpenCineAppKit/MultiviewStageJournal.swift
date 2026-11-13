import Foundation

/// The saved Multiview stage: what an app writes so a relaunch restores the operator's layout and
/// finishes a pending camera network cleanup (Kotlin twin: `MultiviewStageJournal`).
///
/// Values and rules only. Where the stage lives (Keychain, preferences) stays in the app; it
/// loads and saves through these Codable values, and passes its own tile count to `validated`.
/// The JSON keys are the ones the camera apps already store, so earlier saved stages decode
/// unchanged. Network credentials never belong here.
public enum MultiviewStageJournal {
    public struct Camera: Codable, Equatable, Sendable {
        public var slot: Int
        public var id: UUID
        public var name: String
        /// The integration's model code.
        public var modelId: Int?
        /// The integration's identity proof.
        public var identity: [UInt8]?
        /// A platform address to reconnect by (a Bluetooth address on Android); stored as `bleAddress`.
        public var deviceAddress: String?
        public var address: String
        public var experimental: Bool
        public var lutEnabled: Bool

        public init(
            slot: Int, id: UUID, name: String, modelId: Int? = nil, identity: [UInt8]? = nil,
            deviceAddress: String? = nil, address: String, experimental: Bool, lutEnabled: Bool
        ) {
            self.slot = slot
            self.id = id
            self.name = name
            self.modelId = modelId
            self.identity = identity
            self.deviceAddress = deviceAddress
            self.address = address
            self.experimental = experimental
            self.lutEnabled = lutEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case slot, id, name, modelId, identity, address, experimental, lutEnabled
            case deviceAddress = "bleAddress"
        }
    }

    public struct Stage: Codable, Equatable, Sendable {
        public var version = 1
        public var ssid: String
        public var hotspot: Bool
        public var layout: String
        public var focusedIndex: Int
        public var cameras: [Camera]
        public var pendingReset: [Camera]?
        public var returnedToCameraWiFi: Bool?
        public var fill: Bool?

        public init(
            version: Int = 1, ssid: String, hotspot: Bool, layout: String, focusedIndex: Int,
            cameras: [Camera], pendingReset: [Camera]? = nil, returnedToCameraWiFi: Bool? = nil,
            fill: Bool? = nil
        ) {
            self.version = version
            self.ssid = ssid
            self.hotspot = hotspot
            self.layout = layout
            self.focusedIndex = focusedIndex
            self.cameras = cameras
            self.pendingReset = pendingReset
            self.returnedToCameraWiFi = returnedToCameraWiFi
            self.fill = fill
        }

        /// The stage when it is safe to restore with `tileCount` tiles, else nil. A stage needs a
        /// network unless it is only a cleanup ledger (no cameras, something left to reset).
        public func validated(tileCount: Int) -> Stage? {
            let cleanup = pendingReset ?? []
            guard version == 1,
                !ssid.isEmpty || (cameras.isEmpty && !cleanup.isEmpty),
                cameras.count <= tileCount,
                (0..<tileCount).contains(focusedIndex),
                Set(cameras.map(\.slot)).count == cameras.count,
                Set(cameras.map(\.id)).count == cameras.count,
                Set(cleanup.map(\.id)).count == cleanup.count,
                cleanup.allSatisfy({ !$0.name.isEmpty }),
                cameras.allSatisfy({ (0..<tileCount).contains($0.slot) && !$0.name.isEmpty })
            else { return nil }
            return self
        }
    }

    /// `pending` with each of `cameras` replacing the entry of the same id, or appended when new.
    public static func cleanupTargets(_ pending: [Camera], including cameras: [Camera]) -> [Camera] {
        var result = pending
        for camera in cameras {
            if let index = result.firstIndex(where: { $0.id == camera.id }) {
                result[index] = camera
            } else {
                result.append(camera)
            }
        }
        return result
    }
}
