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

    /// Hardware pass 3.4, 7.5 and 8.4: one storage cycle and one precision on every app and
    /// platform. Video steps free space, percentage, then the recording time; photo steps free
    /// space and percentage; free space is the nearest whole unit in both orientations.
    @Test func oneCycleAndOnePrecisionForEveryApp() {
        func forms(_ free: UInt64?, _ percent: String?, _ time: String?, photo: Bool) -> [String] {
            StorageReadoutCycle.forms(freeBytes: free, percent: percent, recordingTime: time, photo: photo)
        }
        #expect(forms(87_940_000_000, "70%", "~51 Min", photo: false) == ["88GB", "70%", "~51 Min"])
        #expect(forms(87_940_000_000, "70%", "~51 Min", photo: true) == ["88GB", "70%"])
        #expect(forms(87_940_000_000, nil, "51 Min", photo: false) == ["88GB", "51 Min"])
        #expect(forms(nil, nil, nil, photo: false) == ["\u{2014}"])
        let volume = StorageVolume(
            id: "active", freeBytes: .init(595_840_000_000, origin: .cameraReported, at: nil),
            totalBytes: .init(1_024_000_000_000, origin: .cameraReported, at: nil),
            remainingRecordingTime: .init(.seconds(51 * 60), origin: .estimated, at: nil))
        let storage = StorageStatus([volume], origin: .cameraReported, at: nil)
        #expect(StorageReadoutCycle.forms(storage, photo: false) == ["596GB", "58%", "~51 Min"])
        #expect(StorageReadoutCycle.forms(storage, photo: true) == ["596GB", "58%"])
        #expect(StorageReadoutCycle.forms(nil, photo: false) == ["\u{2014}"])
        #expect(StorageReadoutCycle.freeSpace(bytes: 904_750_000_000) == "905GB")
        #expect(StorageReadoutCycle.freeSpace(bytes: 999_600_000) == "1GB")
    }
}

