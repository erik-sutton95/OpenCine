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
}
