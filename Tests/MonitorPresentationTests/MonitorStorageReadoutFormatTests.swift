import MonitorPresentation
import Testing

struct MonitorStorageReadoutFormatTests {
    @Test func unknownAndEmptyCapacityKeepDifferentMeaningsInBothUnits() {
        #expect(MonitorStorageReadoutFormat.capacity(gigabytes: nil) == "\u{2014}")
        #expect(MonitorStorageReadoutFormat.capacity(gigabytes: -1) == "\u{2014}")
        #expect(MonitorStorageReadoutFormat.capacity(gigabytes: 0) == "0 GB")
        #expect(MonitorStorageReadoutFormat.capacity(gigabytes: 2048) == "2048 GB")
        #expect(MonitorStorageReadoutFormat.remainingMinutes(nil) == "\u{2014} Min")
        #expect(MonitorStorageReadoutFormat.remainingMinutes(-1) == "\u{2014} Min")
        #expect(MonitorStorageReadoutFormat.remainingMinutes(0) == "0 Min")
        #expect(MonitorStorageReadoutFormat.remainingMinutes(180) == "180 Min")
    }

    @Test func portraitCapacityKeepsNearestWholeUnitAndCompactUppercaseUnit() {
        #expect(MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: nil) == "\u{2014}")
        #expect(MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: 0) == "0B")
        #expect(MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: 999) == "999B")
        #expect(MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: 1500) == "2KB")
        #expect(MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: 47_400_000_000) == "47GB")
        #expect(MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: 904_750_000_000) == "905GB")
        #expect(MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: 999_600_000) == "1GB")
        #expect(MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: 1_000_000_000_000) == "1TB")
    }
}
