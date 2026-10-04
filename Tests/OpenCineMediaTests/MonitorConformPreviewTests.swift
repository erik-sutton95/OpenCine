import OpenCineMedia
import Testing

// Existing donor preview goldens; export and native file probing are separate.
@Suite struct MonitorConformPreviewTests {
    @Test func speedLabelAndDurationFollowTheTargetRate() {
        #expect(MonitorConformPreview.speed(captureRate: 60, targetRate: 24) == 0.4)
        #expect(MonitorConformPreview.label(captureRate: 60, targetRate: 24) == "60 → 24 fps · 40%")
        #expect(MonitorConformPreview.speed(captureRate: 120, targetRate: 24) == 0.2)
        let availability = MonitorConformPreview.availability(for: MonitorConformPreview.Source(captureRate: 120))
        #expect(availability.targets == MonitorConformPreview.targetRates)
        let speed = MonitorConformPreview.speed(captureRate: 60, targetRate: 24)
        #expect(MonitorConformPreview.conformedDuration(sourceSeconds: 6, speed: speed) == 15)
    }

    @Test func onlySlowerTargets() {
        let thirty = MonitorConformPreview.availability(for: MonitorConformPreview.Source(captureRate: 30))
        #expect(thirty.targets == [23.976, 24, 25])
        let twentyFour = MonitorConformPreview.availability(for: MonitorConformPreview.Source(captureRate: 24))
        #expect(twentyFour == .notHighFrameRate)
        #expect(!twentyFour.isAvailable)
    }

    @Test func refusalsExplainWhy() {
        #expect(MonitorConformPreview.availability(for: MonitorConformPreview.Source()) == .unknownRate)
        #expect(
            MonitorConformPreview.availability(
                for: MonitorConformPreview.Source(captureRate: 120, isVariableFrameRate: true))
                == .variableRate)
        #expect(
            MonitorConformPreview.availability(
                for: MonitorConformPreview.Source(captureRate: 120, isAlreadyConformed: true))
                == .alreadyConformed)
        for source in [
            MonitorConformPreview.Source(),
            MonitorConformPreview.Source(captureRate: 120, isVariableFrameRate: true),
            MonitorConformPreview.Source(captureRate: 120, isAlreadyConformed: true),
            MonitorConformPreview.Source(captureRate: 24),
        ] {
            #expect(MonitorConformPreview.availability(for: source).unavailableReason != nil)
        }
    }

    @Test func probeUsesMinDurationWhenNominalIsZero() {
        let source = MonitorConformPreview.probe(
            nominalFrameRate: 0, minFrameDurationSeconds: 1 / 50)
        #expect(source.captureRate == 50)
        #expect(!source.isVariableFrameRate)
    }

    @Test func timescaleArtifactIsNotVariableRate() {
        let source = MonitorConformPreview.probe(
            nominalFrameRate: 50, minFrameDurationSeconds: 1 / 1000)
        #expect(source.captureRate == 50)
        #expect(!source.isVariableFrameRate)
    }

    @Test func sourceFrameIndexPreservesTheDonorTimeline() {
        let speed = MonitorConformPreview.speed(captureRate: 60, targetRate: 24)
        #expect(
            MonitorConformPreview.sourceFrameIndex(
                conformedSeconds: 15, captureRate: 60, speed: speed) == 360)
        #expect(
            MonitorConformPreview.sourceFrameIndex(
                conformedSeconds: 7.5, captureRate: 60, speed: speed) == 180)
        #expect(
            MonitorConformPreview.sourceFrameIndex(
                conformedSeconds: 0, captureRate: 60, speed: speed) == 0)
    }

    @Test func refusalOrderPreservesTheDonorContract() {
        #expect(
            MonitorConformPreview.availability(
                for: .init(captureRate: 0, isVariableFrameRate: true, isAlreadyConformed: true))
                == .unknownRate)
        #expect(MonitorConformPreview.availability(for: .init(captureRate: .nan)) == .unknownRate)
        #expect(
            MonitorConformPreview.availability(
                for: .init(captureRate: 120, isVariableFrameRate: true, isAlreadyConformed: true))
                == .variableRate)
    }

    @Test func labelsAndInvalidDurationPreserveTheDonorGoldens() {
        #expect(MonitorConformPreview.rateLabel(23.976) == "23.98")
        #expect(MonitorConformPreview.rateLabel(29.97) == "29.97")
        #expect(MonitorConformPreview.rateLabel(0) == "\u{2014}")
        #expect(
            MonitorConformPreview.label(captureRate: 59.94, targetRate: 23.976)
                == "59.94 → 23.98 fps · 40%")
        #expect(MonitorConformPreview.label(captureRate: 120, targetRate: 25) == "120 → 25 fps · 20.8%")
        #expect(MonitorConformPreview.targetLabel(captureRate: 50, targetRate: 29.97) == "29.97 fps · 59.9%")
        #expect(MonitorConformPreview.menuHeader(captureRate: 50) == "Conform 50 fps to")
        #expect(MonitorConformPreview.conformedDuration(sourceSeconds: 6, speed: 0) == 0)
        #expect(MonitorConformPreview.conformedDuration(sourceSeconds: .infinity, speed: 0.4) == 0)
    }
}
