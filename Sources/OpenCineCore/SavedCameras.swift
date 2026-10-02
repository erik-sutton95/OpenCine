import Foundation

/// One saved way to reach a camera (a "setup"). Dates are epoch milliseconds in stored JSON.
public struct SavedRoute: Hashable, Codable, Sendable, Identifiable {
    /// Minted once and kept in the saved document.
    public var id: ConnectionRouteID
    /// Codec-stable identity within the camera, for example `ap`, `wifi`, `hotspot`.
    public var key: String
    public var kind: RouteKind
    /// The operator's setup name; `nil` uses the shell's title for the kind.
    public var title: String?
    /// Network name (SSID) or interface name. Never a secret.
    public var network: String?
    /// Needs Bluetooth commissioning before the route comes up.
    public var bluetooth: Bool
    public var lastConnected: Date?
    /// Integration-owned values, kept verbatim.
    public var extras: [String: String]

    public init(
        id: ConnectionRouteID = .init(), key: String, kind: RouteKind, title: String? = nil,
        network: String? = nil, bluetooth: Bool = false, lastConnected: Date? = nil,
        extras: [String: String] = [:]
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.title = title
        self.network = network
        self.bluetooth = bluetooth
        self.lastConnected = lastConnected
        self.extras = extras
    }
}

/// One saved camera with its routes.
public struct SavedCamera: Hashable, Codable, Sendable, Identifiable {
    /// Stable local key. A migrated camera keeps its legacy record id verbatim, so credentials,
    /// media and calibration keyed by it keep working.
    public var id: String
    public var integration: IntegrationID
    /// Durable identity when known (a serial); never derived from a host or a name.
    public var device: CameraDeviceID?
    /// The operator's rename.
    public var name: String?
    public var advertisedName: String
    public var model: String
    /// In chip order.
    public var routes: [SavedRoute]
    public var preferredRoute: ConnectionRouteID?
    public var lastConnected: Date?
    /// Integration-owned values, kept verbatim.
    public var extras: [String: String]

    public init(
        id: String, integration: IntegrationID, device: CameraDeviceID? = nil, name: String? = nil,
        advertisedName: String, model: String, routes: [SavedRoute] = [],
        preferredRoute: ConnectionRouteID? = nil, lastConnected: Date? = nil,
        extras: [String: String] = [:]
    ) {
        self.id = id
        self.integration = integration
        self.device = device
        self.name = name
        self.advertisedName = advertisedName
        self.model = model
        self.routes = routes
        self.preferredRoute = preferredRoute
        self.lastConnected = lastConnected
        self.extras = extras
    }

    /// The rename, else the advertised name.
    public var displayName: String { name ?? advertisedName }
}

/// The saved cameras of one app, as stored. A reader that finds a `version` above
/// `currentVersion` never writes the document.
public struct SavedCamerasDocument: Hashable, Codable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var cameras: [SavedCamera]
    /// Merge base per legacy source: record key -> hash of that record as last imported or
    /// mirrored.
    public var legacy: [String: [String: String]]

    public init(
        version: Int = currentVersion, cameras: [SavedCamera] = [], legacy: [String: [String: String]] = [:]
    ) {
        self.version = version
        self.cameras = cameras
        self.legacy = legacy
    }
}

/// One camera as a legacy saved-camera format describes it, with the records it came from.
public struct LegacyCamera: Hashable, Sendable {
    public var camera: SavedCamera
    /// Record key -> hash of the record as stored.
    public var records: [String: String]

    public init(camera: SavedCamera, records: [String: String]) {
        self.camera = camera
        self.records = records
    }
}

/// A saved-camera format an app wrote before the document. The store reads it on every launch
/// and keeps it mirrored, so an older build still sees current data (add, migrate, remove).
public protocol LegacySavedCameraCodec: Sendable {
    /// Integration extras the legacy records hold. They come from legacy only, absence included.
    var heldExtras: Set<String> { get }
    /// Whether legacy records own setup titles, including an explicitly cleared title.
    var holdsRouteTitles: Bool { get }
    /// Every decodable camera in stored order; undecodable records are skipped. `nil` when the
    /// data is not readable at all.
    func cameras(in data: Data) -> [LegacyCamera]?
    /// `data` (`nil`: nothing stored yet) patched to describe `cameras`: changed fields edited in
    /// place, forgotten cameras removed, new ones appended, unknown fields and undecodable records
    /// kept verbatim. `nil` when nothing changes or the data is not readable.
    func patched(_ data: Data?, to cameras: [SavedCamera]) -> Data?
}

extension LegacySavedCameraCodec {
    /// Per-body formats without setup names leave document titles unchanged.
    public var holdsRouteTitles: Bool { false }
}

extension SavedCamerasDocument {
    /// Three-way merge of one legacy source. Base: `legacy[source]`; theirs: `records`; ours: this
    /// document. A camera whose records changed since the base takes the fields legacy holds and
    /// keeps the document's own (route ids, a learned device, titles the codec does not hold, and
    /// extras). An unchanged camera keeps the document version except legacy-owned titles, which
    /// also repair fingerprints recorded by older stores. A camera legacy no longer lists is removed,
    /// unless nothing was ever mirrored from this source. New legacy cameras are added. The base
    /// becomes `records`.
    public mutating func merge(
        _ records: [LegacyCamera], from source: String, heldExtras: Set<String>,
        holdsRouteTitles: Bool = false
    ) {
        let base = legacy[source] ?? [:]
        var theirs: [String: LegacyCamera] = [:]
        var order: [String] = []
        for record in records where theirs[record.camera.id] == nil {
            theirs[record.camera.id] = record
            order.append(record.camera.id)
        }
        // A record gone since the base: with one record per setup, the camera's other records
        // can be unchanged, so a camera whose routes legacy no longer lists changed too.
        let current = Set(records.flatMap(\.records.keys))
        let removedSome = base.keys.contains { !current.contains($0) }
        var merged: [SavedCamera] = []
        for ours in cameras {
            guard let record = theirs.removeValue(forKey: ours.id) else {
                if base.isEmpty { merged.append(ours) }
                continue
            }
            let lostRoute = removedSome && !Set(ours.routes.map(\.key)).isSubset(of: record.camera.routes.map(\.key))
            let changed = lostRoute || record.records.contains { base[$0.key] != $0.value }
            var camera = changed
                ? Self.overlay(record.camera, onto: ours, heldExtras: heldExtras, holdsRouteTitles: holdsRouteTitles)
                : ours
            if !changed && holdsRouteTitles {
                for index in camera.routes.indices {
                    if let route = record.camera.routes.first(where: { $0.key == camera.routes[index].key }) {
                        camera.routes[index].title = route.title
                    }
                }
            }
            merged.append(camera)
        }
        merged += order.compactMap { theirs[$0]?.camera }
        cameras = merged
        recordMirror(records, from: source)
    }

    /// Sets the merge base of `source` to these records (after reading or writing it).
    public mutating func recordMirror(_ records: [LegacyCamera], from source: String) {
        legacy[source] = records.reduce(into: [:]) { base, record in
            base.merge(record.records) { first, _ in first }
        }
    }

    static func overlay(
        _ theirs: SavedCamera, onto ours: SavedCamera, heldExtras: Set<String>,
        holdsRouteTitles: Bool = false
    ) -> SavedCamera {
        var result = theirs
        result.device = theirs.device ?? ours.device
        result.routes = theirs.routes.map { route in
            guard let mine = ours.routes.first(where: { $0.key == route.key }) else { return route }
            var merged = route
            merged.id = mine.id
            merged.title = holdsRouteTitles ? route.title : route.title ?? mine.title
            merged.lastConnected = route.lastConnected ?? mine.lastConnected
            merged.extras = mine.extras.merging(route.extras) { _, legacy in legacy }
            return merged
        }
        let preferredKey = theirs.routes.first { $0.id == theirs.preferredRoute }?.key
        result.preferredRoute = result.routes.first { $0.key == preferredKey }?.id
        result.extras = ours.extras.filter { !heldExtras.contains($0.key) }
            .merging(theirs.extras) { _, legacy in legacy }
        return result
    }
}

/// Change detection for legacy records: FNV-1a 64 of the record's sorted-key JSON.
// ponytail: change detection only, not integrity; a collision merely skips one legacy edit.
public enum LegacyRecordHash {
    public static func fnv1a(_ object: [String: Any]) -> String {
        let bytes = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
