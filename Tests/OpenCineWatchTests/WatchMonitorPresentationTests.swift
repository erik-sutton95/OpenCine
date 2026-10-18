import Testing
import OpenCineCore
@testable import OpenCineWatch

@Suite("Common watch presentation and preview inspection")
struct WatchMonitorPresentationTests {
    @Test func measuredGaugeAndPercentageKeepTheirReportedMeanings() {
        #expect(WatchMonitorBattery.percentage(nil) == nil)
        #expect(WatchMonitorBattery.percentage(-1) == nil)
        #expect(WatchMonitorBattery.percentage(0)?.filledBars == 0)
        #expect(WatchMonitorBattery.percentage(1)?.filledBars == 1)
        #expect(WatchMonitorBattery.percentage(20)?.urgency == .depleted)
        #expect(WatchMonitorBattery.percentage(21)?.filledBars == 2)
        #expect(WatchMonitorBattery.percentage(40)?.urgency == .low)
        #expect(WatchMonitorBattery.percentage(41)?.filledBars == 3)
        #expect(WatchMonitorBattery.percentage(100)?.filledBars == 5)
        #expect(WatchMonitorBattery.percentage(100)?.accessibilityLabel == "Camera battery 100 percent")
        let measured = WatchMonitorBattery(filledBars: 1, barCount: 5, urgency: .depleted,
            accessibilityLabel: "Camera battery 1 of 5 bars")
        let value = presentation(photography: true, header: "367", battery: measured, aspect: 1.5)
        #expect(value.header == "367")
        #expect(value.battery == measured)
        #expect(value.aspectRatio == 1.5)
        #expect(value.admits(WatchMonitorAction(sourceRevision: 7, intent: .capture)))
    }

    @Test func actionsRetireOnSourceLossReplacementAndReturn() {
        let start = WatchMonitorAction(sourceRevision: 7, intent: .record(true))
        #expect(presentation().admits(start))
        #expect(!presentation(source: nil).admits(WatchMonitorAction(sourceRevision: nil, intent: .record(true))))
        #expect(!presentation(source: 8).admits(start))
        #expect(!presentation(source: 9).admits(start))
        #expect(presentation(source: 9).admits(WatchMonitorAction(sourceRevision: 9, intent: .record(true))))
        #expect(!presentation(canCapture: false).admits(start))
        #expect(!presentation(recording: nil).admits(start))
        #expect(!presentation(photography: nil).admits(start))
    }

    @Test func explicitRecordIntentRefusesChangedReportAndPhotography() {
        let start = WatchMonitorAction(sourceRevision: 7, intent: .record(true))
        let stop = WatchMonitorAction(sourceRevision: 7, intent: .record(false))
        #expect(presentation().admits(start))
        #expect(!presentation(recording: true).admits(start))
        #expect(presentation(recording: true).admits(stop))
        #expect(!presentation().admits(stop))
        #expect(!presentation(photography: true).admits(start))
        #expect(!presentation().admits(WatchMonitorAction(sourceRevision: 7, intent: .capture)))
    }

    @Test func crownClampsAndBackingOutRecentres() {
        var preview = WatchPreviewInspection()
        preview.synchronize(sourceRevision: 7)
        preview.setZoom(50)
        #expect(preview.zoom == 4)
        preview.updatePan(x: 20, y: 10)
        preview.endPan(width: 100, height: 50)
        preview.setZoom(.nan)
        #expect(preview.zoom == 4)
        preview.setZoom(0.5)
        #expect(preview.zoom == 1 && preview.panX == 0 && preview.panY == 0)
        preview.setZoom(2)
        preview.updatePan(x: 8, y: -6)
        preview.endPan(width: 100, height: 50)
        #expect(preview.panX == 8 && preview.panY == -6)
        #expect(presentation(aspect: .infinity).aspectRatio == 16.0 / 9.0)
        #expect(presentation(aspect: -1).aspectRatio == 16.0 / 9.0)
    }

    @Test func eachPanStartsAtTheLastBoundedOrigin() {
        var preview = WatchPreviewInspection()
        preview.setZoom(2)
        preview.updatePan(x: 80, y: -80)
        preview.endPan(width: 100, height: 60)
        #expect(preview.panX == 50 && preview.panY == -30)
        preview.updatePan(x: -10, y: 5)
        preview.updatePan(x: -20, y: 10)
        #expect(preview.panX == 30 && preview.panY == -20)
        preview.endPan(width: 100, height: 60)
        #expect(preview.panX == 30 && preview.panY == -20)
        preview.updatePan(x: .nan, y: 10)
        preview.endPan(width: 100, height: 60)
        #expect(preview.panX == 30 && preview.panY == -20)
        let invalid = preview.clampedPan(width: 0, height: .infinity)
        #expect(invalid.x == 0 && invalid.y == 0)
    }

    @Test func interruptionAndSourceRetirementRejectLatePointerEnd() {
        var preview = WatchPreviewInspection()
        preview.synchronize(sourceRevision: 7)
        preview.setZoom(2)
        preview.updatePan(x: 12, y: 8)
        preview.endPan(width: 100, height: 60)
        preview.updatePan(x: 20, y: 15)
        preview.interruptPan(pointerActive: true)
        preview.updatePan(x: 90, y: 90)
        preview.endPan(width: 100, height: 60)
        #expect(preview.panX == 12 && preview.panY == 8)
        preview.updatePan(x: 4, y: -3)
        preview.synchronize(sourceRevision: nil)
        preview.synchronize(sourceRevision: 8)
        preview.setZoom(2)
        preview.updatePan(x: 90, y: 90)
        preview.endPan(width: 100, height: 60)
        #expect(preview.panX == 0 && preview.panY == 0)
        preview.updatePan(x: 3, y: 4)
        preview.endPan(width: 100, height: 60)
        #expect(preview.panX == 3 && preview.panY == 4)
    }

    private func presentation(source: UInt64? = 7, recording: Bool? = false,
        photography: Bool? = false, canCapture: Bool = true, header: String = "00:00:00:00",
        battery: WatchMonitorBattery? = nil, aspect: Double? = nil) -> WatchMonitorPresentation {
        WatchMonitorPresentation(sourceRevision: source, header: header, media: "3.2 TB",
            battery: battery, recording: recording, photography: photography, feedAspectRatio: aspect,
            canCapture: canCapture, placeholder: nil, commandMessage: nil)
    }
    @Test func commonReadingPreservesDeclaredPrecisionAndIndependentExhaustion() throws {
        let fraction = try #require(WatchMonitorBattery.measured(.fraction(0.68)))
        #expect(fraction.reading == .fraction(0.68))
        #expect(fraction.barCount == 0)
        #expect(fraction.accessibilityLabel == "Camera battery 68 percent")
        #expect(fraction.exhausted == nil)
        for exhausted in [false, true] {
            let gauge = try #require(WatchMonitorBattery.measured(.steps(filled: 1, of: 4), exhausted: exhausted))
            #expect(gauge.filledBars == 1)
            #expect(gauge.barCount == 4)
            #expect(gauge.exhausted == exhausted)
            #expect(gauge.accessibilityLabel == "Camera battery 1 of 4 bars")
        }
        for count in [11, 1_000_000] {
            let dense = try #require(WatchMonitorBattery.measured(.steps(filled: 1, of: count)))
            #expect(dense.reading == .steps(filled: 1, of: count))
            #expect(dense.barCount == count)
            #expect(dense.accessibilityLabel == "Camera battery 1 of \(count) bars")
        }
        #expect(WatchMonitorBattery.measured(.fraction(0))?.reading == .fraction(0))
        #expect(WatchMonitorBattery.measured(nil) == nil)
        #expect(WatchMonitorBattery.measured(.fraction(.nan)) == nil)
        #expect(WatchMonitorBattery.measured(.steps(filled: 1, of: 0)) == nil)
    }

}
