import Foundation
import OpenCineCore
import Testing
@testable import OpenCineMedia

@Suite struct StorageObservationTests {
    @Test func recordingTimeRetainsOriginAndKnownZero() {
        func status(_ duration: Duration?, _ origin: ObservationOrigin) -> StorageStatus {
            ObservedValue([StorageVolume(id: "active", remainingRecordingTime:
                duration.map { ObservedValue($0, origin: origin, at: nil) } ?? .unknown)], origin: .cameraReported, at: nil)
        }
        #expect(status(.seconds(40 * 60), .estimated).recordingTimeLabel == "~40 Min")
        #expect(status(.seconds(40 * 60), .cameraReported).recordingTimeLabel == "40 Min")
        #expect(status(.zero, .estimated).recordingTimeLabel == "~0 Min")
        #expect(status(nil, .estimated).recordingTimeLabel == nil)
        #expect(status(.seconds(-1), .cameraReported).recordingTimeLabel == nil)
    }

    @Test func bytePrecisionAndVolumeSelectionDoNotDependOnLegacyMegabytes() {
        func volume(_ id: String, _ bytes: UInt64, _ media: MediaState = .ready) -> StorageVolume {
            StorageVolume(id: id, media: ObservedValue(media, origin: .cameraReported, at: nil),
                freeBytes: ObservedValue(bytes, origin: .cameraReported, at: nil))
        }
        let stores = ObservedValue([volume("sd", 999), volume("active", 1001)], origin: .cameraReported, at: nil)
        #expect(stores.storageReadout?.free == "1 KB")
        let fallback = ObservedValue([volume("sd", 999), volume("active", 1001, .error)], origin: .cameraReported, at: nil)
        #expect(fallback.storageReadout?.free == "999 B")
        #expect(ObservedValue<[StorageVolume]>.unknown.storageReadout == nil)
        #expect(ObservedValue([volume("active", 0)], origin: .cameraReported, at: nil).storageReadout?.free == "0 B")
    }
    @Test func percentRoundingDoesNotOverflowTheLargestCapacity() {
        #expect(StorageReadout(freeBytes: UInt64.max, totalBytes: UInt64.max).percentFree == 100)
        #expect(StorageReadout(freeBytes: UInt64.max / 2, totalBytes: UInt64.max).percentFree == 50)
        #expect(StorageReadout(freeBytes: 1, totalBytes: 200).percentFree == 1)
        #expect(StorageReadout(freeBytes: 0, totalBytes: UInt64.max).percentFree == 0)
    }
    @Test func olderStoragePayloadDecodesWithUnknownCapacity() throws {
        let original = StorageVolume(id: "active", freeBytes: ObservedValue(UInt64(1001), origin: .cameraReported, at: nil))
        let data = try JSONEncoder().encode(original)
        var payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "totalBytes")
        let restored = try JSONDecoder().decode(StorageVolume.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(restored.freeBytes == original.freeBytes)
        #expect(restored.totalBytes == .unknown)
        #expect(try JSONDecoder().decode(StorageVolume.self, from: data) == original)
    }
}
