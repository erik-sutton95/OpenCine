import Foundation
import OpenCineCore

/// The one storage readout (A5-11): free space in decimal bytes through `ByteCountLabel`, with the free percentage as the
/// alternative. Live status, Multiview, multicam and the wrist all show this text, so one card
/// reads the same on every surface and platform (`Fixtures/media-value-labels.tsv`).
public struct StorageReadout: Equatable, Sendable {
    /// Shown where no volume reports.
    public static let unavailable = "\u{2014}"

    public let freeBytes: UInt64
    /// Capacity, or nil when the camera reports none.
    public let totalBytes: UInt64?

    public init(freeBytes: UInt64, totalBytes: UInt64?) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Whole decimal gigabytes free, rounded half up.
    public var gigabytesFree: Int {
        Int(freeBytes / 1_000_000_000 + (freeBytes % 1_000_000_000 >= 500_000_000 ? 1 : 0))
    }

    /// Percentage of the capacity free (0 to 100), rounded half up; nil without a capacity.
    public var percentFree: Int? {
        totalBytes.map { total in
            let free = min(freeBytes, total)
            // Compare half-percent thresholds without overflowing the byte count.
            var lower = 0
            var upper = 100
            while lower < upper {
                let middle = (lower + upper + 1) / 2
                let multiplier = UInt64(2 * middle - 1)
                let threshold = total / 200 * multiplier + (total % 200 * multiplier + 199) / 200
                if free >= threshold { lower = middle } else { upper = middle - 1 }
            }
            return lower
        }
    }

    /// `60 GB`.
    public var free: String { ByteCountLabel.label(freeBytes) }

    /// `47%`, or nil without a capacity.
    public var percent: String? { percentFree.map { "\($0)%" } }

    /// `60 GB · 47%`, or `60 GB` without a capacity.
    public var label: String { percent.map { "\(free) · \($0)" } ?? free }
}

extension ObservedValue where Value == [StorageVolume] {
    /// The active usable volume, otherwise the first usable volume in integration order.
    public var preferredStorageVolume: StorageVolume? {
        let volumes = value ?? []
        let ordered = volumes.filter { $0.id == "active" } + volumes.filter { $0.id != "active" }
        return ordered.first { volume in
            guard volume.media.value != .absent, volume.media.value != .error else { return false }
            let total = volume.totalBytes.value.flatMap { $0 > 0 ? $0 : nil }
            if let free = volume.freeBytes.value, total.map({ free > $0 }) ?? false { return false }
            return volume.freeBytes.value != nil || volume.remainingRecordingTime.value != nil
        }
    }

    public var storageReadout: StorageReadout? {
        guard let volume = preferredStorageVolume, let free = volume.freeBytes.value else { return nil }
        return StorageReadout(freeBytes: free, totalBytes: volume.totalBytes.value)
    }

    /// Whole minutes with the estimate explicitly marked; unknown time remains absent.
    public var recordingTimeLabel: String? {
        guard let observation = preferredStorageVolume?.remainingRecordingTime,
            let duration = observation.value, duration >= .zero else { return nil }
        let minutes = duration.components.seconds / 60
        return RecordingTimeLabel.label(minutes, origin: observation.origin)
    }

    public var wristMediaLabel: String {
        if let readout = storageReadout, readout.totalBytes != nil { return readout.label }
        return recordingTimeLabel ?? storageReadout?.free ?? StorageReadout.unavailable
    }
}
