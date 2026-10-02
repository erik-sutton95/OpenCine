import Foundation
import OpenCineCore
import OpenCineNikon
import Testing

/// OpenZCine iOS saved setups (SHELL-02 design 4, tests 1-5 and 7) on a golden fixture written by
/// the app's own encoder: `NativeCameraConnectionStore` saves
/// `JSONEncoder().encode(PTPIPSavedCameraRecords.canonicalized(records))`, and `appRecords()`
/// builds the records through the same store functions. Regenerate with
/// `OPENCINE_WRITE_FIXTURES=1 swift test --filter NikonSavedRecords`. Kotlin mirror (Android
/// records): `NikonSavedRecordsTest` in `Android/nikon`.
private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/saved-cameras/nikon-records-v0-ios.json")

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: 781_000_000.25 + seconds) }

/// Body A (serial) paired on its access point, then given a Studio Wi-Fi setup and a USB-C setup,
/// renamed on every path; body B (no serial) on the phone's hotspot; body C (serial) on its
/// access point under a pending host key.
private func appRecords() -> [PTPIPSavedCameraRecord] {
    typealias Records = PTPIPSavedCameraRecords
    var records: [PTPIPSavedCameraRecord] = []
    records = Records.upserting(
        host: "192.168.1.1", displayName: "ZR_3001234", transport: "Wi-Fi", lastSeenAt: at(0),
        pairedViaCameraAccessPoint: true, serialNumber: "3001234", path: .cameraAccessPoint(ssid: "NIKON_ZR_3001234"),
        into: records)
    records = Records.updatingWiFiSSID(host: "192.168.1.1", wifiSSID: "NIKON_ZR_3001234", in: records)
    records = Records.upserting(
        host: "192.168.50.23", displayName: "ZR_3001234", transport: "Wi-Fi", lastSeenAt: at(200),
        serialNumber: "3001234", path: .infrastructure(networkName: "Studio"), into: records)
    records = Records.upserting(
        host: "usb:0x1a2b3c", displayName: "ZR_3001234", transport: "USB-C", lastSeenAt: at(100),
        serialNumber: "3001234", path: .usbC, into: records)
    for host in ["192.168.1.1", "192.168.50.23", "usb:0x1a2b3c"] {
        records = Records.updatingPresentation(host: host, customName: "A-cam", borderColor: nil, icon: nil, in: records)
    }
    records = Records.updatingSetupName(host: "192.168.50.23", pathKind: .infrastructure, setupName: "Studio", in: records)
    records = Records.updatingStreamSettings(
        host: "192.168.1.1", pathKind: .cameraAccessPoint, streamPreset: .fast, qualityBias: .latency, in: records)
    records = Records.upserting(
        host: "172.20.10.3", displayName: "ZR_4005678", transport: "Wi-Fi", lastSeenAt: at(300), path: .phoneHotspot,
        into: records)
    records = Records.upserting(
        host: "ap:NIKON_Z8_5009999", displayName: "Z_8_5009999", transport: "Wi-Fi", lastSeenAt: at(-100),
        serialNumber: "5009999", path: .cameraAccessPoint(ssid: "NIKON_Z8_5009999"), into: records)
    return records
}

/// The app's encoder: what `NativeCameraConnectionStore.saveSavedCameras` writes.
private func appEncoded(_ records: [PTPIPSavedCameraRecord]) throws -> Data {
    try JSONEncoder().encode(PTPIPSavedCameraRecords.canonicalized(records))
}

/// In-memory defaults that log which keys were written.
final class NikonDefaults {
    var values: [String: Data]
    var writes: [String] = []

    init(_ values: [String: Data]) { self.values = values }
}

/// The shared `SavedCamerasStore`'s merge-on-load and patch-on-save over the Core merge (an
/// integration's tests do not depend on the app shell); its own tests cover the rest.
@MainActor
final class SavedCamerasStore {
    private let defaults: NikonDefaults
    private let codec = NikonSavedRecordsV0()
    private var document = SavedCamerasDocument()
    private(set) var cameras: [SavedCamera] = []

    init(_ defaults: NikonDefaults) { self.defaults = defaults }

    func load() {
        let stored = defaults.values["document"]
        document = stored.flatMap { try? JSONDecoder.milliseconds.decode(SavedCamerasDocument.self, from: $0) } ?? .init()
        if let records = defaults.values["legacy"].flatMap(codec.cameras(in:)) {
            document.merge(
                records, from: "records", heldExtras: codec.heldExtras,
                holdsRouteTitles: codec.holdsRouteTitles)
        }
        cameras = document.cameras
        write()
    }

    func save(_ cameras: [SavedCamera]) {
        document.cameras = cameras
        self.cameras = cameras
        if let patched = codec.patched(defaults.values["legacy"], to: cameras) {
            defaults.values["legacy"] = patched
            defaults.writes.append("legacy")
            document.recordMirror(codec.cameras(in: patched) ?? [], from: "records")
        }
        write()
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let encoded = try? encoder.encode(document), encoded != defaults.values["document"] else { return }
        defaults.values["document"] = encoded
        defaults.writes.append("document")
    }
}

@MainActor
@Suite struct NikonSavedRecords {
    let golden: Data

    init() throws {
        if ProcessInfo.processInfo.environment["OPENCINE_WRITE_FIXTURES"] == "1" {
            try appEncoded(appRecords()).write(to: fixture)
        }
        golden = try Data(contentsOf: fixture)
    }

    func store(_ defaults: NikonDefaults) -> SavedCamerasStore { SavedCamerasStore(defaults) }

    func upgraded() -> (NikonDefaults, SavedCamerasStore) {
        let defaults = NikonDefaults(["legacy": golden])
        let store = store(defaults)
        store.load()
        return (defaults, store)
    }

    @Test func theFixtureIsWhatTheAppWrites() throws {
        let written = try JSONSerialization.jsonObject(with: appEncoded(appRecords())) as? NSArray
        let stored = try JSONSerialization.jsonObject(with: golden) as? NSArray
        #expect(written != nil && written == stored)
    }

    @Test func upgradeImportsEverySetupAndLeavesLegacyAlone() throws {
        let (defaults, store) = upgraded()
        #expect(defaults.values["legacy"] == golden)
        #expect(defaults.writes == ["document"])
        #expect(store.cameras.map(\.id) == ["serial:3001234", "172.20.10.3|zr_4005678|phoneHotspot", "serial:5009999"])
        #expect(store.cameras.allSatisfy { $0.integration == NikonCameraSession.integration && $0.model.isEmpty })

        let a = store.cameras[0]
        #expect(a.device == .durable("3001234", integration: NikonCameraSession.integration))
        #expect(a.name == "A-cam" && a.advertisedName == "ZR_3001234")
        #expect(a.routes.map(\.key) == ["infrastructure|Studio", "usbC", "cameraAccessPoint"])
        #expect(a.routes.map(\.kind) == [.infrastructureNetwork, .usb, .cameraAccessPoint])
        #expect(a.routes.map(\.title) == ["Studio", nil, nil])
        #expect(a.routes.map(\.network) == ["Studio", nil, "NIKON_ZR_3001234"])
        #expect(a.routes.map { $0.extras[NikonSavedRecordsV0.Extra.host] } == ["192.168.50.23", "usb:0x1a2b3c", "192.168.1.1"])
        #expect(a.routes.allSatisfy { !$0.bluetooth })
        #expect(a.preferredRoute == a.routes[0].id && a.lastConnected == at(200))
        #expect(a.routes[2].lastConnected == at(0))
        #expect(a.routes[2].extras[NikonSavedRecordsV0.Extra.streamPreset] == "Fast")
        #expect(a.routes[2].extras[NikonSavedRecordsV0.Extra.qualityBias] == "Latency")
        #expect(a.routes[2].extras[NikonSavedRecordsV0.Extra.accessPointSSID] == "NIKON_ZR_3001234")
        #expect(a.routes[2].extras[NikonSavedRecordsV0.Extra.pairedViaCameraAccessPoint] == "true")
        #expect(a.routes[1].extras[NikonSavedRecordsV0.Extra.transport] == "USB-C")

        let b = store.cameras[1]
        #expect(b.device == nil && b.name == nil && b.routes.map(\.kind) == [.phoneHotspot])

        let stored = try #require(defaults.values["document"])
        let document = try JSONDecoder.milliseconds.decode(SavedCamerasDocument.self, from: stored)
        #expect(document.cameras == store.cameras && document.legacy["records"]?.count == 5)
    }

    @Test func migrationIsIdempotent() {
        let (defaults, first) = upgraded()
        let document = defaults.values["document"]
        for _ in 0..<2 {
            let again = store(defaults)
            again.load()
            #expect(again.cameras == first.cameras)
        }
        #expect(defaults.values["document"] == document && defaults.values["legacy"] == golden)
        #expect(defaults.writes == ["document"])
    }

    @Test func mirrorRoundTripDecodesWithTheAppDecoder() throws {
        var array = try #require(try JSONSerialization.jsonObject(with: golden) as? [[String: Any]])
        array[0]["futureField"] = ["kept": true]
        let defaults = NikonDefaults(["legacy": try JSONSerialization.data(withJSONObject: array)])
        let store = store(defaults)
        store.load()
        var cameras = store.cameras
        cameras[0].name = "Renamed"
        cameras[0].routes.removeAll { $0.kind == .usb }
        cameras[0].routes[0].title = "Stage"
        cameras[2].routes.append(
            SavedRoute(
                key: "phoneHotspot", kind: .phoneHotspot, lastConnected: at(400),
                extras: [NikonSavedRecordsV0.Extra.host: "172.20.10.9", NikonSavedRecordsV0.Extra.cameraName: "Z_8_5009999"]))
        cameras.remove(at: 1)
        store.save(cameras)

        let legacy = try #require(defaults.values["legacy"])
        let records = try JSONDecoder().decode([PTPIPSavedCameraRecord].self, from: legacy)
        #expect(records.map(\.host) == ["192.168.1.1", "192.168.50.23", "ap:nikon_z8_5009999", "172.20.10.9"])
        #expect(records[0].presentation?.customName == "Renamed" && records[1].presentation?.customName == "Renamed")
        #expect(records[0].streamPreset == .fast && records[0].presentation?.wifiSSID == "NIKON_ZR_3001234")
        #expect(records[1].setupName == "Stage" && records[1].path == .infrastructure(networkName: "Studio"))
        #expect(records[2].presentation == nil)
        #expect(records[3].path == .phoneHotspot && records[3].serialNumber == "5009999" && records[3].lastSeenAt == at(400))
        let raw = try #require(try JSONSerialization.jsonObject(with: legacy) as? [[String: Any]])
        #expect((raw[0]["futureField"] as? [String: Any])?["kept"] as? Bool == true)
        // The app's own read keeps them as they are (already canonical).
        #expect(PTPIPSavedCameraRecords.canonicalized(records) == records)

        let again = self.store(defaults)
        again.load()
        #expect(again.cameras == store.cameras && defaults.values["legacy"] == legacy)
    }

    @Test func downgradeCanClearASetupName() throws {
        try clearSetupName(oldStoreLoads: false)
    }

    @Test func legacyFingerprintDoesNotHideClearedSetupName() throws {
        try clearSetupName(oldStoreLoads: true)
    }

    private func clearSetupName(oldStoreLoads: Bool) throws {
        let defaults = NikonDefaults(["legacy": try Data(contentsOf: fixture)])
        let store = SavedCamerasStore(defaults)
        store.load()
        var cameras = store.cameras
        let index = try #require(cameras[0].routes.firstIndex { $0.kind == .infrastructureNetwork })
        cameras[0].routes[index].title = "Stage right"
        store.save(cameras)
        var old = try JSONDecoder().decode(
            [PTPIPSavedCameraRecord].self, from: #require(defaults.values["legacy"]))
        #expect(old.first { $0.pathKind == .infrastructure }?.setupName == "Stage right")
        old = PTPIPSavedCameraRecords.updatingSetupName(
            host: "192.168.50.23", pathKind: .infrastructure, setupName: nil, in: old)
        defaults.values["legacy"] = try appEncoded(old)
        if oldStoreLoads {
            var document = try JSONDecoder.milliseconds.decode(
                SavedCamerasDocument.self, from: #require(defaults.values["document"]))
            let legacyData = try #require(defaults.values["legacy"])
            let records = try #require(NikonSavedRecordsV0().cameras(in: legacyData))
            // The prior store records the new fingerprint but retains the cleared document title.
            document.merge(records, from: "records", heldExtras: [])
            #expect(document.cameras[0].routes[index].title == "Stage right")
            // With unchanged fingerprints, repairing the title must leave all other fields alone.
            document.cameras[0].name = "Document camera"
            cameras[0].name = "Document camera"
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            defaults.values["document"] = try encoder.encode(document)
        }
        store.load()
        cameras[0].routes[index].title = nil
        #expect(store.cameras == cameras)
        store.load()
        #expect(store.cameras == cameras)
    }

    @Test func downgradeEditsMergeBackOnUpgrade() throws {
        let (defaults, store) = upgraded()
        let a = store.cameras[0]
        let studio = try #require(a.routes.first { $0.key == "infrastructure|Studio" })

        // The older build edits through its own store functions and encoder: the Studio setup's
        // camera moved to a new address (DHCP), body A gained a hotspot path and a new name, and
        // body C was forgotten.
        typealias Records = PTPIPSavedCameraRecords
        let mirrored = try #require(defaults.values["legacy"])
        var old = try JSONDecoder().decode([PTPIPSavedCameraRecord].self, from: mirrored)
        old = Records.upserting(
            host: "192.168.50.40", displayName: "ZR_3001234", transport: "Wi-Fi", lastSeenAt: at(500),
            serialNumber: "3001234", path: .infrastructure(networkName: "Studio"), into: old)
        old = Records.upserting(
            host: "172.20.10.4", displayName: "ZR_3001234", transport: "Wi-Fi", lastSeenAt: at(450),
            serialNumber: "3001234", path: .phoneHotspot, into: old)
        for host in ["192.168.1.1", "192.168.50.40", "usb:0x1a2b3c", "172.20.10.4"] {
            old = Records.updatingPresentation(host: host, customName: "B-cam", borderColor: nil, icon: nil, in: old)
        }
        old = Records.removing("ap:nikon_z8_5009999", from: old)
        defaults.values["legacy"] = try appEncoded(old)

        let upgraded = self.store(defaults)
        upgraded.load()
        #expect(upgraded.cameras.map(\.id) == ["serial:3001234", "172.20.10.3|zr_4005678|phoneHotspot"])
        let merged = upgraded.cameras[0]
        #expect(merged.name == "B-cam" && merged.device == a.device)
        #expect(merged.routes.map(\.key) == ["infrastructure|Studio", "phoneHotspot", "usbC", "cameraAccessPoint"])
        #expect(merged.routes[0].id == studio.id && merged.routes[0].extras[NikonSavedRecordsV0.Extra.host] == "192.168.50.40")
        #expect(merged.routes[2].id == a.routes[1].id && merged.routes[3].id == a.routes[2].id)
        #expect(merged.preferredRoute == merged.routes[0].id)
    }

    /// One record per setup: the app (or an older build) drops one setup of a body whose other
    /// records stay byte for byte. The setup leaves the document, and a later save does not put
    /// it back into the records.
    @Test func aSetupRemovedFromTheRecordsLeavesTheDocument() throws {
        let (defaults, _) = upgraded()
        let mirrored = try #require(defaults.values["legacy"])
        let old = try JSONDecoder().decode([PTPIPSavedCameraRecord].self, from: mirrored)
        defaults.values["legacy"] = try appEncoded(PTPIPSavedCameraRecords.removing("usb:0x1a2b3c", from: old))

        let store = self.store(defaults)
        store.load()
        #expect(store.cameras[0].routes.map(\.key) == ["infrastructure|Studio", "cameraAccessPoint"])
        var renamed = store.cameras
        renamed[0].name = "C-cam"
        store.save(renamed)
        let records = try JSONDecoder().decode([PTPIPSavedCameraRecord].self, from: #require(defaults.values["legacy"]))
        #expect(!records.contains { $0.host == "usb:0x1a2b3c" })
        #expect(records.filter { $0.serialNumber == "3001234" }.count == 2)
    }

    @Test func aBadRecordIsKeptAndSkipped() throws {
        var array = try #require(try JSONSerialization.jsonObject(with: golden) as? [Any])
        array.insert("not a record", at: 1)
        array.append(["host": "192.168.9.9"])
        let legacy = try JSONSerialization.data(withJSONObject: array)
        let defaults = NikonDefaults(["legacy": legacy])
        let store = store(defaults)
        store.load()
        #expect(store.cameras.count == 3 && defaults.values["legacy"] == legacy)

        var cameras = store.cameras
        cameras[1].name = "Hotspot cam"
        store.save(cameras)
        let written = try #require(defaults.values["legacy"])
        let patched = try #require(try JSONSerialization.jsonObject(with: written) as? [Any])
        #expect(patched.count == 7)
        #expect(patched[1] as? String == "not a record")
        #expect((patched[6] as? [String: Any])?["host"] as? String == "192.168.9.9")
        let hotspot = try #require(patched.compactMap { $0 as? [String: Any] }.first { $0["host"] as? String == "172.20.10.3" })
        #expect((hotspot["presentation"] as? [String: Any])?["customName"] as? String == "Hotspot cam")
    }

    /// Design test 7: with and without a serial, one body over USB and over LAN, a pending
    /// access-point host key, and a record from before the declared path.
    @Test func setupsGroupByBodyAsTheListDoes() throws {
        let cameras = try #require(NikonSavedRecordsV0().cameras(in: golden))
        #expect(cameras.map { $0.records.count } == [3, 1, 1])
        #expect(cameras[0].camera.routes.map(\.kind).contains(.usb))
        #expect(cameras[0].camera.routes.map(\.kind).contains(.infrastructureNetwork))
        #expect(cameras[2].camera.routes[0].extras[NikonSavedRecordsV0.Extra.host] == "ap:nikon_z8_5009999")
        #expect(cameras[2].camera.routes[0].network == "NIKON_Z8_5009999")

        // An untyped record reads through the app's typing; no record is rewritten by the read.
        let untyped = PTPIPSavedCameraRecord(
            host: "172.20.10.7", displayName: "ZR_7000001", transport: "iPhone Hotspot", lastSeenAt: at(10))
        let legacy = try JSONEncoder().encode([untyped])
        let camera = try #require(NikonSavedRecordsV0().cameras(in: legacy)?.first?.camera)
        #expect(camera.id == "172.20.10.7|zr_7000001|phoneHotspot" && camera.routes.map(\.kind) == [.phoneHotspot])
        #expect(NikonSavedRecordsV0().patched(legacy, to: [camera]) == nil)

        // Two router setups without a network name are told apart by subnet, as the app's
        // chips did; a record rebuilt from such a route keeps no name.
        let routers = [
            PTPIPSavedCameraRecord(
                host: "10.99.0.20", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: at(20),
                serialNumber: "6002199", path: .infrastructure(networkName: nil)),
            PTPIPSavedCameraRecord(
                host: "192.168.129.66", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: at(10),
                serialNumber: "6002199", path: .infrastructure(networkName: " ")),
        ]
        let body = try #require(NikonSavedRecordsV0().cameras(in: JSONEncoder().encode(routers))?.first?.camera)
        #expect(body.routes.map(\.network) == ["10.99.0.x", "192.168.129.x"])
        var forgotten = body
        forgotten.routes = [body.routes[0]]
        let rebuilt = try #require(NikonSavedRecordsV0().patched(nil, to: [forgotten]))
        let record = try #require(JSONDecoder().decode([PTPIPSavedCameraRecord].self, from: rebuilt).first)
        #expect(record.path == .infrastructure(networkName: nil))

        // Two records the app never canonicalized share an id: two cameras, nothing dropped.
        let twice = try JSONEncoder().encode([untyped, untyped])
        let two = try #require(NikonSavedRecordsV0().cameras(in: twice)).map(\.camera)
        #expect(two.map(\.id) == [camera.id, camera.id + "#2"])
        #expect(NikonSavedRecordsV0().patched(twice, to: two) == nil)
    }
}

extension JSONDecoder {
    fileprivate static var milliseconds: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
