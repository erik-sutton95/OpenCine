import Foundation
import OpenCineCore

/// The saved setups OpenZCine's iOS app wrote before the saved-camera document: one JSON array of
/// `PTPIPSavedCameraRecord`, one record per setup (UserDefaults `OpenZCine.PTPIP.SavedCameras`).
/// Android records have their own codec (Kotlin `NikonSavedRecordsV0`).
///
/// Mapping (SHELL-02 design 4):
/// - Records of one body group by serial, as the list groups them (`SavedCameraPathGroups`); a
///   record without a serial is its own camera.
/// - Camera id `serial:<serial>`, else the record's id; `device` is the serial (durable).
/// - One route per record, most recently seen first; the most recent is preferred. Route key: the
///   path kind, plus the network (name, else subnet) for a Wi-Fi setup, so a DHCP move keeps the
///   route. Untyped records are read through the app's own one-time `typed()`.
/// - `setupName` -> route title; a record's `presentation.customName` -> camera name; the path's
///   network -> route network. Every other record field rides in the route's extras (`Extra`).
///
/// The app keeps writing these records with its own save rules (connect upserts, per-setup stream
/// settings). A patch edits only what the shared flow changes: a renamed camera (on every record
/// of the body, as the app renames), setup names, and removed cameras and setups. A document route
/// with no record is appended from its extras. Unknown fields and undecodable records are kept.
public struct NikonSavedRecordsV0: LegacySavedCameraCodec {
    /// Route extras: the record fields the document has no field for.
    public enum Extra {
        public static let host = "host"
        public static let cameraName = "cameraName"
        public static let transport = "transport"
        public static let pairedViaCameraAccessPoint = "pairedViaCameraAccessPoint"
        public static let accessPointSSID = "wifiSSID"
        public static let borderColor = "borderColor"
        public static let icon = "icon"
        public static let streamPreset = "streamPreset"
        public static let qualityBias = "qualityBias"
    }

    public var heldExtras: Set<String> { [] }
    public var holdsRouteTitles: Bool { true }

    public init() {}

    public func cameras(in data: Data) -> [LegacyCamera]? {
        guard let stored = Self.read(data) else { return nil }
        return Self.layout(stored.map(\.record)).map { camera, members in
            LegacyCamera(
                camera: camera,
                records: Dictionary(members.map { (stored[$0.position].key, stored[$0.position].hash) }) { a, _ in a })
        }
    }

    /// The cameras these records describe, as the document stores them.
    public static func cameras(from records: [PTPIPSavedCameraRecord]) -> [SavedCamera] {
        layout(records).map(\.camera)
    }

    public func patched(_ data: Data?, to cameras: [SavedCamera]) -> Data? {
        var array: [Any] = []
        var stored: [Stored] = []
        if let data {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any], let read = Self.read(data)
            else { return nil }
            (array, stored) = (parsed, read)
        }
        var placement: [Int: (camera: String, route: String)] = [:]
        var legacyNames: [String: String?] = [:]
        for (camera, members) in Self.layout(stored.map(\.record)) {
            legacyNames[camera.id] = camera.name
            for member in members { placement[stored[member.position].index] = (camera.id, member.route) }
        }
        let wanted = Dictionary(cameras.map { ($0.id, $0) }) { first, _ in first }
        var matched = Set<String>()
        var changed = false
        var out: [Any] = []
        for (index, element) in array.enumerated() {
            guard var object = element as? [String: Any], let place = placement[index] else {
                out.append(element)
                continue
            }
            guard let camera = wanted[place.camera], let route = camera.routes.first(where: { $0.key == place.route }),
                matched.insert(place.camera + "\u{0}" + place.route).inserted
            else {
                changed = true
                continue
            }
            var presentation = object["presentation"] as? [String: Any] ?? [:]
            if legacyNames[place.camera] != camera.name, Self.trimmed(presentation["customName"] as? String) != camera.name {
                presentation["customName"] = camera.name
                object["presentation"] = presentation.isEmpty ? nil : presentation
                changed = true
            }
            if Self.trimmed(object["setupName"] as? String) != route.title {
                object["setupName"] = route.title
                changed = true
            }
            out.append(object)
        }
        for camera in cameras {
            for route in camera.routes where !matched.contains(camera.id + "\u{0}" + route.key) {
                guard let record = Self.record(camera, route), let encoded = try? JSONEncoder().encode(record),
                    let object = try? JSONSerialization.jsonObject(with: encoded)
                else { continue }
                out.append(object)
                changed = true
            }
        }
        guard changed else { return nil }
        return try? JSONSerialization.data(withJSONObject: out, options: [.withoutEscapingSlashes])
    }

    // MARK: Reading

    /// One stored element that decodes as a record, with its merge-base key and hash.
    struct Stored {
        var index: Int
        var key: String
        var hash: String
        var record: PTPIPSavedCameraRecord
    }

    /// Each element decoded as the app decodes the array, one at a time so a bad record costs
    /// only itself. `nil` when the data is not a JSON array.
    static func read(_ data: Data) -> [Stored]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
            let records = try? JSONDecoder().decode([Lenient].self, from: data), records.count == array.count
        else { return nil }
        var keys = Set<String>()
        return array.indices.compactMap { index in
            guard let raw = array[index] as? [String: Any], let record = records[index].record else { return nil }
            let key = unique(typed(record).id, in: &keys)
            return Stored(index: index, key: key, hash: LegacyRecordHash.fnv1a(raw), record: record)
        }
    }

    private struct Lenient: Decodable {
        var record: PTPIPSavedCameraRecord?
        init(from decoder: Decoder) throws { record = try? PTPIPSavedCameraRecord(from: decoder) }
    }

    // MARK: Layout

    /// Records with a declared path as stored; older ones through the app's one-time typing.
    static func typed(_ record: PTPIPSavedCameraRecord) -> PTPIPSavedCameraRecord {
        record.path == nil ? PTPIPSavedCameraRecords.typed(record).first ?? record : record
    }

    /// Cameras in the order of each body's first record, with each route's record position;
    /// routes most recently seen first.
    static func layout(_ records: [PTPIPSavedCameraRecord]) -> [(
        camera: SavedCamera, members: [(position: Int, route: String)]
    )] {
        var groups: [[Int]] = []
        var bySerial: [String: Int] = [:]
        for (position, record) in records.enumerated() {
            guard let serial = trimmed(record.serialNumber) else {
                groups.append([position])
                continue
            }
            if let group = bySerial[serial] {
                groups[group].append(position)
            } else {
                bySerial[serial] = groups.count
                groups.append([position])
            }
        }
        // Unique even in data the app never canonicalized: a shared id would drop a setup.
        var ids = Set<String>()
        return groups.map { group in
            let members = group.sorted { lhs, rhs in
                let (a, b) = (records[lhs].lastSeenAt ?? .distantPast, records[rhs].lastSeenAt ?? .distantPast)
                return a != b ? a > b : lhs < rhs
            }
            let typedMembers = members.map { typed(records[$0]) }
            var keys = Set<String>()
            let routes = typedMembers.map { record in
                let key = routeKey(record)
                return route(record, key: unique(keys.contains(key) ? key + "|" + record.host : key, in: &keys))
            }
            let first = typedMembers[0]
            let serial = trimmed(first.serialNumber)
            let camera = SavedCamera(
                id: unique(serial.map { "serial:\($0)" } ?? first.id, in: &ids),
                integration: NikonCameraSession.integration,
                device: serial.map { .durable($0, integration: NikonCameraSession.integration) },
                name: typedMembers.lazy.compactMap { trimmed($0.presentation?.customName) }.first,
                advertisedName: first.displayName, model: "", routes: routes, preferredRoute: routes[0].id,
                lastConnected: typedMembers.compactMap(\.lastSeenAt).max())
            return (camera, zip(members, routes).map { ($0.0, $0.1.key) })
        }
    }

    /// The setup's identity within its camera: the path kind, and for a Wi-Fi setup its network
    /// (the app's own setup key: the name when known, else the subnet). Never the host alone.
    static func routeKey(_ record: PTPIPSavedCameraRecord) -> String {
        guard case .infrastructure(let network) = record.path else { return record.path?.kind.rawValue ?? "untyped" }
        return "infrastructure|" + (trimmed(network) ?? CameraDiscovery.subnetBase(for: record.host) ?? record.host)
    }

    private static func unique(_ key: String, in keys: inout Set<String>) -> String {
        var candidate = key
        var suffix = 1
        while !keys.insert(candidate).inserted {
            suffix += 1
            candidate = "\(key)#\(suffix)"
        }
        return candidate
    }

    public static func routeKind(_ kind: CameraPath.Kind) -> RouteKind {
        switch kind {
        case .cameraAccessPoint: .cameraAccessPoint
        case .infrastructure: .infrastructureNetwork
        case .phoneHotspot: .phoneHotspot
        case .usbC: .usb
        case .hdmiCapture: .captureDevice
        }
    }

    public static func pathKind(_ kind: RouteKind) -> CameraPath.Kind {
        switch kind {
        case .cameraAccessPoint: .cameraAccessPoint
        case .infrastructureNetwork: .infrastructure
        case .phoneHotspot: .phoneHotspot
        case .usb: .usbC
        case .captureDevice: .hdmiCapture
        }
    }

    private static func route(_ record: PTPIPSavedCameraRecord, key: String) -> SavedRoute {
        var extras = [Extra.host: record.host, Extra.cameraName: record.displayName, Extra.transport: record.transport]
        extras[Extra.pairedViaCameraAccessPoint] = record.pairedViaCameraAccessPoint.map { $0 ? "true" : "false" }
        extras[Extra.accessPointSSID] = trimmed(record.presentation?.wifiSSID)
        extras[Extra.borderColor] = trimmed(record.presentation?.borderColor)
        extras[Extra.icon] = trimmed(record.presentation?.icon)
        extras[Extra.streamPreset] = record.streamPreset?.rawValue
        extras[Extra.qualityBias] = record.qualityBias?.rawValue
        // A Wi-Fi setup without a network name is told apart by its subnet ("192.168.1.x"), as
        // the app's own chips told two router setups apart.
        let network: String? =
            switch record.path {
            case .cameraAccessPoint(let ssid): trimmed(ssid)
            case .infrastructure(let name): trimmed(name) ?? subnetLabel(record.host)
            default: nil
            }
        return SavedRoute(
            key: key, kind: routeKind(record.path?.kind ?? .infrastructure), title: trimmed(record.setupName),
            network: network, lastConnected: record.lastSeenAt, extras: extras)
    }

    /// A record for a document route that has none, built from its extras; `nil` without a host.
    static func record(_ camera: SavedCamera, _ route: SavedRoute) -> PTPIPSavedCameraRecord? {
        guard let host = route.extras[Extra.host] else { return nil }
        let path: CameraPath =
            switch route.kind {
            case .cameraAccessPoint: .cameraAccessPoint(ssid: route.network)
            case .infrastructureNetwork:
                .infrastructure(networkName: route.network == subnetLabel(host) ? nil : route.network)
            case .phoneHotspot: .phoneHotspot
            case .usb: .usbC
            case .captureDevice: .hdmiCapture
            }
        let presentation = PTPIPSavedCameraPresentation(
            customName: camera.name, borderColor: route.extras[Extra.borderColor], icon: route.extras[Extra.icon],
            wifiSSID: route.extras[Extra.accessPointSSID])
        return PTPIPSavedCameraRecord(
            host: host, displayName: route.extras[Extra.cameraName] ?? camera.advertisedName,
            transport: route.extras[Extra.transport] ?? path.legacyTransportLabel, lastSeenAt: route.lastConnected,
            presentation: presentation == PTPIPSavedCameraPresentation() ? nil : presentation,
            pairedViaCameraAccessPoint: route.extras[Extra.pairedViaCameraAccessPoint].map { $0 == "true" },
            serialNumber: camera.device.flatMap { $0.isProvisional ? nil : $0.value }, path: path,
            streamPreset: route.extras[Extra.streamPreset].flatMap(LiveViewStreamPreset.init(rawValue:)),
            qualityBias: route.extras[Extra.qualityBias].flatMap(LiveViewQualityBias.init(rawValue:)),
            setupName: route.title)
    }

    /// The subnet label a Wi-Fi route without a network name carries (never a network name).
    private static func subnetLabel(_ host: String) -> String? {
        CameraDiscovery.subnetBase(for: host).map { "\($0).x" }
    }

    static func trimmed(_ value: String?) -> String? {
        guard let string = value?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }
}
