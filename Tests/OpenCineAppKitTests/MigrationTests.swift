import Foundation
import OpenCineAppKit
import OpenCineCore
import Testing

/// Saved-camera migration (SHELL-02 design 4, tests 1-6) on synthetic fixtures for both date
/// flavors. Kotlin mirror: `MigrationTest` in `Android/appkit`, same method names.
private let integration = IntegrationID("test.cameras")
private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/saved-cameras")

@MainActor
@Suite struct Migration {

    enum Flavor: String, CaseIterable, CustomTestStringConvertible {
        case secondsSince2001
        case epochMilliseconds

        var testDescription: String { rawValue }

        var fixture: Data {
            let name = self == .secondsSince2001 ? "body-records-v0-seconds-2001" : "body-records-v0-epoch-ms"
            return try! Data(contentsOf: fixtures.appending(path: "\(name).json"))
        }

        var codec: BodyRecordsV0 {
            BodyRecordsV0(integration: integration, dates: self == .secondsSince2001 ? .secondsSince2001 : .epochMilliseconds)
        }

        var ids: [String] {
            self == .secondsSince2001
                ? ["6F9619FF-8B86-D011-B42D-00C04FC964FF", "7A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9", "0D1E2F30-4152-4637-8899-AABBCCDDEEFF"]
                : ["AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:02", "AA:BB:CC:DD:EE:03"]
        }
    }

    func store(_ defaults: Defaults, _ flavor: Flavor) -> SavedCamerasStore {
        SavedCamerasStore(
            document: defaults.at("document"),
            legacy: .init(data: defaults.at("legacy"), codec: flavor.codec, source: "records"))
    }

    func upgraded(_ flavor: Flavor) -> (Defaults, SavedCamerasStore) {
        let defaults = Defaults(["legacy": flavor.fixture])
        let store = store(defaults, flavor)
        store.load()
        return (defaults, store)
    }

    @Test(arguments: Flavor.allCases)
    func upgradeImportsEveryCameraAndLeavesLegacyAlone(_ flavor: Flavor) throws {
        let (defaults, store) = upgraded(flavor)
        #expect(defaults.values["legacy"] == flavor.fixture)
        #expect(defaults.writes == ["document"])
        #expect(store.cameras.map(\.id) == flavor.ids)
        #expect(store.cameras.allSatisfy { $0.integration == integration && $0.device == nil })

        let a = store.cameras[0]
        #expect(a.name == "A cam" && a.advertisedName == "CAM-AAAA" && a.model == "Test Body")
        #expect(a.routes.map(\.key) == ["ap", "wifi"])
        #expect(a.routes.map(\.kind) == [.cameraAccessPoint, .infrastructureNetwork])
        #expect(a.routes.map(\.network) == ["CAM-AAAA", "studio"])
        #expect(a.routes.allSatisfy { $0.bluetooth })
        #expect(a.preferredRoute == a.routes[1].id)
        #expect(milliseconds(a.lastConnected) == 1_759_307_200_250)
        #expect(a.extras == (flavor == .secondsSince2001 ? ["modelId": "34"] : [:]))

        // `lastSetup` names a setup that is gone: kept verbatim, no preferred route.
        let b = store.cameras[1]
        #expect(b.name == nil && b.model == "Test Body Mini")
        #expect(b.routes.map(\.key) == ["ap", "hotspot"] && b.routes.map(\.network) == [nil, "phone"])
        #expect(b.preferredRoute == nil && b.extras == ["lastSetup": "wifi"])
        #expect(milliseconds(b.lastConnected) == 1_758_307_200_000)

        let c = store.cameras[2]
        #expect(c.routes.map(\.key) == ["ap"] && c.routes[0].network == nil)
        #expect(milliseconds(c.lastConnected) == 1_757_307_200_500)

        let document = try decoded(defaults.values["document"])
        #expect(document.version == 1 && document.cameras == store.cameras)
        #expect(document.legacy["records"]?.keys.sorted() == flavor.ids.sorted())
    }

    @Test(arguments: Flavor.allCases)
    func migrationIsIdempotent(_ flavor: Flavor) {
        let (defaults, first) = upgraded(flavor)
        let document = defaults.values["document"]
        for _ in 0..<2 {
            let again = store(defaults, flavor)
            again.load()
            #expect(again.cameras == first.cameras)
        }
        #expect(defaults.values["document"] == document)
        #expect(defaults.values["legacy"] == flavor.fixture)
        #expect(defaults.writes == ["document"])
    }

    @Test func mirrorRoundTripDecodesWithTheOldDecoder() throws {
        let (defaults, store) = upgraded(.secondsSince2001)
        var cameras = store.cameras
        cameras[0].name = "Renamed"
        cameras[0].routes.append(SavedRoute(key: "hotspot", kind: .phoneHotspot, network: "phone-2", bluetooth: true))
        cameras[1].lastConnected = date(1_760_000_000_000)
        cameras[1].preferredRoute = cameras[1].routes[0].id
        cameras.remove(at: 2)
        let added = SavedCamera(
            id: "11111111-2222-4333-8444-555555555555", integration: integration, advertisedName: "CAM-DDDD",
            model: "Test Body", routes: [SavedRoute(key: "ap", kind: .cameraAccessPoint, bluetooth: true)],
            lastConnected: date(1_760_000_001_000))
        store.save(cameras + [added])

        let legacy = try #require(defaults.values["legacy"])
        let old = try JSONDecoder().decode([OldRecord].self, from: legacy)
        #expect(old.map(\.id.uuidString) == [Flavor.secondsSince2001.ids[0], Flavor.secondsSince2001.ids[1], added.id])
        #expect(old[0].customName == "Renamed" && old[0].hotspotSSID == "phone-2")
        #expect(old[0].wifiSSID == "studio" && old[0].lastSetup == "wifi" && old[0].modelId == 34)
        #expect(old[1].lastSetup == "cameraWiFi" && milliseconds(old[1].lastConnectedAt) == 1_760_000_000_000)
        #expect(old[2].advertisedName == "CAM-DDDD" && old[2].lastSSID == nil && old[2].customName == nil)
        let raw = try #require(try JSONSerialization.jsonObject(with: legacy) as? [[String: Any]])
        #expect((raw[1]["futureField"] as? [String: Any])?["kept"] as? Bool == true)

        // The mirror is the new merge base: a reload keeps the document as saved.
        let again = self.store(defaults, .secondsSince2001)
        again.load()
        #expect(again.cameras == store.cameras)
        #expect(defaults.values["legacy"] == legacy)
    }

    @Test func downgradeEditsMergeBackOnUpgrade() throws {
        let (defaults, store) = upgraded(.secondsSince2001)
        var cameras = store.cameras
        cameras[0].device = .durable("SN-1", integration: integration)
        cameras[0].routes[1].title = "Studio"
        store.save(cameras)
        let routeIDs = cameras[0].routes.map(\.id)

        // The older build edits through its own encoder.
        let mirrored = try #require(defaults.values["legacy"])
        var old = try JSONDecoder().decode([OldRecord].self, from: mirrored)
        old[0].customName = "Old rename"
        old[0].hotspotSSID = "phone-3"
        old[0].lastSetup = "phoneHotspot"
        old[2].wifiSSID = "office"
        old.remove(at: 1)
        old.append(
            OldRecord(
                id: UUID(uuidString: "99999999-2222-4333-8444-555555555555")!, advertisedName: "CAM-EEEE",
                modelName: "Test Body", lastConnectedAt: date(1_760_000_002_000)))
        defaults.values["legacy"] = try JSONEncoder().encode(old)

        let upgraded = self.store(defaults, .secondsSince2001)
        upgraded.load()
        let ids = Flavor.secondsSince2001.ids
        #expect(upgraded.cameras.map(\.id) == [ids[0], ids[2], "99999999-2222-4333-8444-555555555555"])
        let a = upgraded.cameras[0]
        #expect(a.name == "Old rename" && a.device == .durable("SN-1", integration: integration))
        #expect(a.routes.map(\.key) == ["ap", "wifi", "hotspot"] && a.routes[2].network == "phone-3")
        #expect(Array(a.routes.map(\.id).prefix(2)) == routeIDs && a.routes[1].title == "Studio")
        #expect(a.preferredRoute == a.routes[2].id)
        #expect(upgraded.cameras[1].routes.map(\.network) == [nil, "office"])
        #expect(upgraded.cameras[2].advertisedName == "CAM-EEEE")
    }

    @Test(arguments: Flavor.allCases)
    func aBadRecordIsKeptAndSkipped(_ flavor: Flavor) throws {
        var array = try #require(try JSONSerialization.jsonObject(with: flavor.fixture) as? [Any])
        array.insert("not a record", at: 1)
        array.append(["advertisedName": "No id"])
        let legacy = try JSONSerialization.data(withJSONObject: array)
        let defaults = Defaults(["legacy": legacy])
        let store = store(defaults, flavor)
        store.load()
        #expect(store.cameras.map(\.id) == flavor.ids)
        #expect(defaults.values["legacy"] == legacy)

        var cameras = store.cameras
        cameras[0].name = "Renamed"
        store.save(cameras)
        let written = try #require(defaults.values["legacy"])
        let patched = try #require(try JSONSerialization.jsonObject(with: written) as? [Any])
        #expect(patched.count == 5)
        #expect(patched[1] as? String == "not a record")
        #expect((patched[4] as? [String: Any])?["advertisedName"] as? String == "No id")
        #expect((patched[0] as? [String: Any])?["customName"] as? String == "Renamed")
    }

    @Test(arguments: Flavor.allCases)
    func aFutureDocumentIsNeverWritten(_ flavor: Flavor) throws {
        // The document an upgrade wrote, kept to stand in for a later build's merge.
        let (earlier, _) = upgraded(flavor)
        let future = Data(#"{"version":2,"shape":"unknown"}"#.utf8)
        let defaults = Defaults(["document": future, "legacy": flavor.fixture])
        let store = store(defaults, flavor)
        store.load()
        #expect(!store.writesDocument)
        #expect(store.cameras.map(\.id) == flavor.ids)
        var cameras = store.cameras
        cameras[2].name = "Edited while newer"
        store.save(cameras)
        #expect(defaults.values["document"] == future)
        #expect(defaults.writes == ["legacy"])

        // A build that merges again sees the edit.
        defaults.values["document"] = earlier.values["document"]
        let later = self.store(defaults, flavor)
        later.load()
        #expect(later.cameras[2].name == "Edited while newer")
    }

    @Test func nothingStoredStartsEmptyAndWritesNoLegacy() {
        let defaults = Defaults([:])
        let store = store(defaults, .epochMilliseconds)
        store.load()
        #expect(store.cameras.isEmpty && defaults.values["legacy"] == nil)
    }
}

/// In-memory defaults that log which keys were written.
final class Defaults {
    var values: [String: Data]
    var writes: [String] = []

    init(_ values: [String: Data]) { self.values = values }

    func at(_ key: String) -> StoredData {
        StoredData(read: { self.values[key] }, write: { self.values[key] = $0; self.writes.append(key) })
    }
}

/// The per-body record as the older iOS builds encode it (their `Codable` struct).
struct OldRecord: Codable {
    var id: UUID
    var advertisedName: String
    var modelName: String
    var modelId: Int?
    var lastSSID: String?
    var lastConnectedAt: Date
    var customName: String?
    var wifiSSID: String?
    var hotspotSSID: String?
    var lastSetup: String?
}

func milliseconds(_ date: Date?) -> Int64? { date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } }

func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

func decoded(_ data: Data?) throws -> SavedCamerasDocument {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(SavedCamerasDocument.self, from: try #require(data))
}
