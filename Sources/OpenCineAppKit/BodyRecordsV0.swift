import Foundation
import OpenCineCore

/// The per-body saved-camera records apps wrote before the document: one JSON array, one object
/// per body. Fields: `id`, `advertisedName`, `modelName`, optional `modelId` (a number),
/// `lastConnectedAt`, optional `customName`, `lastSSID` (the camera's access point),
/// `wifiSSID`, `hotspotSSID` and `lastSetup` (`cameraWiFi`, `wifi` or `phoneHotspot`).
///
/// Mapping: routes `ap` (access point, always present), `wifi` (infrastructure) and `hotspot`,
/// each over Bluetooth first; `lastSetup` -> `preferredRoute` (kept verbatim in
/// `extras["lastSetup"]` when its route is gone); `modelId` -> `extras["modelId"]`;
/// `customName` -> `name`. An empty string is absent. A record without an `id` is undecodable.
public struct BodyRecordsV0: LegacySavedCameraCodec {
    public enum Dates: Sendable {
        /// `Date`'s default `Codable` form: seconds since 2001-01-01.
        case secondsSince2001
        case epochMilliseconds
    }

    public var integration: IntegrationID
    public var dates: Dates
    public var heldExtras: Set<String> { ["modelId", "lastSetup"] }

    public init(integration: IntegrationID, dates: Dates) {
        self.integration = integration
        self.dates = dates
    }

    private struct Setup {
        var raw: String
        var key: String
        var kind: RouteKind
        var field: String
    }

    private static let setups = [
        Setup(raw: "cameraWiFi", key: "ap", kind: .cameraAccessPoint, field: "lastSSID"),
        Setup(raw: "wifi", key: "wifi", kind: .infrastructureNetwork, field: "wifiSSID"),
        Setup(raw: "phoneHotspot", key: "hotspot", kind: .phoneHotspot, field: "hotspotSSID"),
    ]

    public func cameras(in data: Data) -> [LegacyCamera]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return array.compactMap { element in
            guard let object = element as? [String: Any], let camera = camera(from: object) else { return nil }
            return LegacyCamera(camera: camera, records: [camera.id: LegacyRecordHash.fnv1a(object)])
        }
    }

    public func patched(_ data: Data?, to cameras: [SavedCamera]) -> Data? {
        var array: [Any] = []
        if let data {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
            array = parsed
        }
        let wanted = Dictionary(cameras.map { ($0.id, $0) }) { first, _ in first }
        var written = Set<String>()
        var changed = false
        var out: [Any] = []
        for element in array {
            guard var object = element as? [String: Any], let current = camera(from: object) else {
                out.append(element)
                continue
            }
            guard let camera = wanted[current.id], written.insert(current.id).inserted else {
                changed = true
                continue
            }
            let now = values(of: current)
            let next = values(of: camera)
            for key in Self.fields where now[key] != next[key] {
                object[key] = next[key].map { stored(key, $0) }
                changed = true
            }
            out.append(object)
        }
        for camera in cameras where written.insert(camera.id).inserted {
            var object: [String: Any] = ["id": camera.id]
            for (key, value) in values(of: camera) { object[key] = stored(key, value) }
            out.append(object)
            changed = true
        }
        guard changed else { return nil }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Fields

    private func camera(from object: [String: Any]) -> SavedCamera? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        let routes = Self.setups.compactMap { setup -> SavedRoute? in
            let network = Self.string(object[setup.field])
            guard setup.key == "ap" || network != nil else { return nil }
            return SavedRoute(key: setup.key, kind: setup.kind, network: network, bluetooth: true)
        }
        var extras: [String: String] = [:]
        if let modelId = object["modelId"] as? NSNumber { extras["modelId"] = modelId.stringValue }
        var preferred: ConnectionRouteID?
        if let lastSetup = Self.string(object["lastSetup"]) {
            let key = Self.setups.first { $0.raw == lastSetup }?.key
            if let route = routes.first(where: { $0.key == key }) {
                preferred = route.id
            } else {
                extras["lastSetup"] = lastSetup
            }
        }
        return SavedCamera(
            id: id, integration: integration, name: Self.string(object["customName"]),
            advertisedName: object["advertisedName"] as? String ?? "",
            model: object["modelName"] as? String ?? "", routes: routes, preferredRoute: preferred,
            lastConnected: (object["lastConnectedAt"] as? NSNumber).map { date(from: $0.doubleValue) },
            extras: extras)
    }

    private static let fields = [
        "advertisedName", "modelName", "customName", "lastConnectedAt", "modelId", "lastSSID", "wifiSSID",
        "hotspotSSID", "lastSetup",
    ]

    /// The stored fields of a camera, normalized for comparison (dates as epoch milliseconds). A
    /// missing key is an absent field; names and `lastConnectedAt` are always present, because
    /// older decoders require them.
    private func values(of camera: SavedCamera) -> [String: AnyHashable] {
        var values: [String: AnyHashable] = [
            "advertisedName": camera.advertisedName,
            "modelName": camera.model,
            "lastConnectedAt": camera.lastConnected.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0,
        ]
        values["customName"] = camera.name
        values["modelId"] = camera.extras["modelId"].flatMap { Int($0) }
        for setup in Self.setups {
            values[setup.field] = camera.routes.first { $0.key == setup.key }?.network
        }
        let preferredKey = camera.routes.first { $0.id == camera.preferredRoute }?.key
        values["lastSetup"] = Self.setups.first { $0.key == preferredKey }?.raw ?? camera.extras["lastSetup"]
        return values
    }

    private func stored(_ key: String, _ value: AnyHashable) -> Any {
        guard key == "lastConnectedAt", let milliseconds = value as? Int64 else { return value }
        switch dates {
        case .epochMilliseconds: return milliseconds
        case .secondsSince2001:
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000).timeIntervalSinceReferenceDate
        }
    }

    private func date(from number: Double) -> Date {
        switch dates {
        case .epochMilliseconds: Date(timeIntervalSince1970: number / 1000)
        case .secondsSince2001: Date(timeIntervalSinceReferenceDate: number)
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
