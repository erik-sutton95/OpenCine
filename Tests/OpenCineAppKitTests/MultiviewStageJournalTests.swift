import Foundation
import OpenCineAppKit
import Testing

private typealias Journal = MultiviewStageJournal

private func camera(
    slot: Int = 0, id: UUID = UUID(), name: String = "Camera", address: String = ""
) -> Journal.Camera {
    Journal.Camera(
        slot: slot, id: id, name: name, modelId: nil, identity: nil, address: address,
        experimental: false, lutEnabled: false)
}

private func stage(
    ssid: String = "Test", focusedIndex: Int = 0, cameras: [Journal.Camera] = [],
    pendingReset: [Journal.Camera]? = nil
) -> Journal.Stage {
    Journal.Stage(
        ssid: ssid, hotspot: false, layout: "Grid", focusedIndex: focusedIndex,
        cameras: cameras, pendingReset: pendingReset)
}

private func decode(_ json: String) throws -> Journal.Stage {
    try JSONDecoder().decode(Journal.Stage.self, from: Data(json.utf8))
}

@Suite struct MultiviewStageJournalTests {
    @Test func aStageFromTheIOSEncoderDecodes() throws {
        // Golden captured from a stage the iOS encoder wrote.
        let json = """
            {"version":1,"ssid":"Test network","hotspot":true,"layout":"Grid","focusedIndex":2,\
            "cameras":[{"slot":1,"id":"0F8FAD5B-D9CB-469F-A165-70867728950E","name":"Camera-Test",\
            "modelId":32,"identity":[0,5,65],"address":"192.168.1.31","experimental":false,\
            "lutEnabled":true}],"pendingReset":[],"returnedToCameraWiFi":true,"fill":true}
            """
        let decoded = try decode(json)
        #expect(decoded.validated(tileCount: 4) == decoded)
        #expect(decoded.cameras[0].identity == [0, 5, 65])
        #expect(decoded.cameras[0].modelId == 32)
        #expect(decoded.cameras[0].deviceAddress == nil)
        #expect(decoded.cameras[0].id == UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E"))
        #expect(decoded.fill == true)
    }

    @Test func aStageFromTheAndroidEncoderDecodes() throws {
        // Golden captured from a stage the Android encoder wrote.
        // Android writes the device address under "bleAddress".
        let json = """
            {"version":1,"ssid":"Test","hotspot":false,"layout":"Center stage","focusedIndex":0,\
            "cameras":[{"slot":0,"id":"0F8FAD5B-D9CB-469F-A165-70867728950E","name":"Camera-A",\
            "bleAddress":"AA:BB:CC:DD:EE:00","address":"192.168.1.30","experimental":false,\
            "lutEnabled":false,"modelId":32}]}
            """
        let decoded = try decode(json)
        #expect(decoded.cameras[0].deviceAddress == "AA:BB:CC:DD:EE:00")
        let again = try JSONEncoder().encode(decoded)
        #expect(String(decoding: again, as: UTF8.self).contains("\"bleAddress\":\"AA:BB:CC:DD:EE:00\""))
    }

    @Test func encodeThenDecodeKeepsEveryField() throws {
        var full = camera(slot: 2, name: "Test", address: "192.168.1.20")
        full.modelId = 0x20
        full.identity = [0, 4, 84]
        full.deviceAddress = "AA:BB"
        full.experimental = true
        full.lutEnabled = true
        let original = Journal.Stage(
            ssid: "Test network", hotspot: true, layout: "Grid", focusedIndex: 2,
            cameras: [full], pendingReset: [full], returnedToCameraWiFi: false, fill: true)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Journal.Stage.self, from: data) == original)
        #expect(!String(decoding: data, as: UTF8.self).contains("password"))
    }

    @Test func aStageWithoutOptionalFieldsOmitsThem() throws {
        let data = try JSONEncoder().encode(stage())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("fill") && !text.contains("pendingReset"))
        #expect(!text.contains("bleAddress"))
        #expect(try JSONDecoder().decode(Journal.Stage.self, from: data).fill == nil)
    }

    @Test func moreCamerasThanTilesIsInvalid() {
        let cameras = (0..<3).map { camera(slot: $0) }
        #expect(stage(cameras: cameras).validated(tileCount: 3) != nil)
        #expect(stage(cameras: cameras).validated(tileCount: 2) == nil)
    }

    @Test func duplicateSlotsOrIdsAreInvalid() {
        let first = camera(slot: 0)
        #expect(stage(cameras: [first, camera(slot: 0)]).validated(tileCount: 4) == nil)
        #expect(stage(cameras: [first, camera(slot: 1, id: first.id)]).validated(tileCount: 4) == nil)
        #expect(stage(cameras: [camera(slot: 4)]).validated(tileCount: 4) == nil)
        #expect(stage(cameras: [camera(slot: -1)]).validated(tileCount: 4) == nil)
        let reset = camera()
        #expect(stage(pendingReset: [reset, reset]).validated(tileCount: 4) == nil)
    }

    @Test func emptyNamesAreInvalid() {
        #expect(stage(cameras: [camera(name: "")]).validated(tileCount: 4) == nil)
        #expect(stage(pendingReset: [camera(name: "")]).validated(tileCount: 4) == nil)
    }

    @Test func focusOutsideTheTilesIsInvalid() {
        #expect(stage(focusedIndex: 3).validated(tileCount: 4) != nil)
        #expect(stage(focusedIndex: 4).validated(tileCount: 4) == nil)
        #expect(stage(focusedIndex: -1).validated(tileCount: 4) == nil)
        #expect(stage(focusedIndex: 3).validated(tileCount: 3) == nil)
    }

    @Test func anUnknownVersionIsInvalid() {
        var future = stage()
        future.version = 99
        #expect(future.validated(tileCount: 4) == nil)
    }

    @Test func anEmptyNetworkIsValidOnlyForCleanupWithoutCameras() {
        let cleanup = (0..<6).map { camera(name: "Scan \($0)") }
        #expect(stage(ssid: "", pendingReset: cleanup).validated(tileCount: 4) != nil)
        #expect(stage(ssid: "", cameras: [camera()], pendingReset: cleanup).validated(tileCount: 4) == nil)
        #expect(stage(ssid: "", pendingReset: []).validated(tileCount: 4) == nil)
        #expect(stage(ssid: "").validated(tileCount: 4) == nil)
    }

    @Test func cleanupTargetsReplaceByIdAndAppendNewCameras() {
        let scanned = camera(name: "Scan")
        var assigned = scanned
        assigned.slot = 2
        assigned.address = "192.168.1.20"
        let other = camera(name: "Other")
        let fresh = camera(name: "Fresh")
        #expect(
            Journal.cleanupTargets([scanned, other], including: [assigned, fresh])
                == [assigned, other, fresh])
    }
}
