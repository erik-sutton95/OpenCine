import OpenCineCore
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

    /// Hardware pass 3.4, 7.5 and 8.4: one storage cycle and one precision on every app and
    /// platform. Video steps free space, percentage, then the recording time; photo steps free
    /// space and percentage; free space is the nearest whole unit in both orientations.
    @Test func oneCycleAndOnePrecisionForEveryApp() {
        func forms(_ free: UInt64?, _ percent: String?, _ time: String?, photo: Bool) -> [String] {
            MonitorStorageReadoutFormat.forms(freeBytes: free, percent: percent, recordingTime: time, photo: photo)
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
        #expect(MonitorStorageReadoutFormat.forms(storage.storageReadout, recordingTime: storage.recordingTimeLabel, photo: false) == ["596GB", "58%", "~51 Min"])
        #expect(MonitorStorageReadoutFormat.forms(storage.storageReadout, recordingTime: storage.recordingTimeLabel, photo: true) == ["596GB", "58%"])
        #expect(MonitorStorageReadoutFormat.forms(nil, recordingTime: nil, photo: false) == ["\u{2014}"])
    }
}

