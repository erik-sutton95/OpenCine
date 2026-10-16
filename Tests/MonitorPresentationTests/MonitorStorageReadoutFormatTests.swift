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
}
