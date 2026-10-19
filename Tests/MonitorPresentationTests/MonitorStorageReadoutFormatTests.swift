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

    /// A5-11: the free percentage is the storage readout's alternative; video adds the remaining
    /// recording time when the body reports one; photo never shows minutes (behavior audit
    /// II-130, PIA-252, PAA-248).
    @Test func oneTapStepsFromFreeSpaceToPercentThenRecordingTime() {
        #expect(MonitorStorageReadoutFormat.alternatives(percent: "47%", recordingTime: "~47 Min", photo: false)
            == ["47%", "~47 Min"])
        #expect(MonitorStorageReadoutFormat.alternatives(percent: "47%", recordingTime: nil, photo: false) == ["47%"])
        #expect(MonitorStorageReadoutFormat.alternatives(percent: "47%", recordingTime: "~47 Min", photo: true) == ["47%"])
        #expect(MonitorStorageReadoutFormat.alternatives(percent: nil, recordingTime: "~47 Min", photo: true).isEmpty)
        #expect(MonitorStorageReadoutFormat.alternatives(percent: nil, recordingTime: nil, photo: false).isEmpty)
    }

    /// A tap with nothing to step to leaves the readout on its free space, so a later
    /// alternative starts from free space too.
    @Test func aTapStepsOnlyWhenThereIsAnAlternative() {
        #expect(MonitorStorageReadoutFormat.nextForm(after: 0, count: 3) == 1)
        #expect(MonitorStorageReadoutFormat.nextForm(after: 2, count: 3) == 0)
        #expect(MonitorStorageReadoutFormat.nextForm(after: 0, count: 1) == 0)
        #expect(MonitorStorageReadoutFormat.nextForm(after: 5, count: 1) == 0)
        #expect(MonitorStorageReadoutFormat.nextForm(after: 5, count: 2) == 0)
    }
}
