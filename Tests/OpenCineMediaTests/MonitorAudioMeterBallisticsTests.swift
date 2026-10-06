import Testing

@testable import OpenCineMedia

@Suite("Audio meter dBFS conversion")
struct MonitorAudioMeterDecibelTests {
    /// Full scale reads 0 dB, half amplitude −6 dB; silence and overdrive clamp.
    @Test(
        arguments: [
            (1, 0), (0.5, -6.0206), (2, 0),
            (0, MonitorAudioMeterBallistics.floorDB), (-1, MonitorAudioMeterBallistics.floorDB),
            (0.000_01, MonitorAudioMeterBallistics.floorDB),
        ] as [(Double, Double)])
    func linearMapsToDecibels(linear: Double, decibels: Double) {
        #expect(abs(MonitorAudioMeterBallistics.decibels(fromLinear: linear) - decibels) < 0.01)
    }
}

@Suite("Audio meter ballistics")
struct MonitorAudioMeterBallisticsTests {
    @Test func attackIsInstant() {
        let next = MonitorAudioMeterBallistics.step(.silent, peakLinear: 1, dt: 0.04)
        #expect(next.levelDB == 0)
        #expect(next.peakDB == 0)
        #expect(next.peakAge == 0)
    }

    @Test func levelDecaysAtTheDocumentedRate() {
        let loud = MonitorAudioMeterBallistics.step(.silent, peakLinear: 1, dt: 0.04)
        let dt = 0.5
        let next = MonitorAudioMeterBallistics.step(loud, peakLinear: 0, dt: dt)
        #expect(abs(next.levelDB - (-MonitorAudioMeterBallistics.levelDecayPerSecond * dt)) < 1e-9)
    }

    @Test func peakHoldsThroughTheHoldWindowThenDecays() {
        var channel = MonitorAudioMeterBallistics.step(.silent, peakLinear: 1, dt: 0.04)
        channel = MonitorAudioMeterBallistics.step(channel, peakLinear: 0, dt: 1.0)
        #expect(channel.peakDB == 0)
        #expect(channel.levelDB < 0)
        channel = MonitorAudioMeterBallistics.step(channel, peakLinear: 0, dt: 1.0)
        #expect(channel.peakAge > MonitorAudioMeterBallistics.peakHoldSeconds)
        #expect(channel.peakDB < 0)
    }

    @Test func levelNeverFallsBelowTheFloor() {
        var channel = MonitorAudioMeterBallistics.step(.silent, peakLinear: 1, dt: 0.04)
        for _ in 0..<100 {
            channel = MonitorAudioMeterBallistics.step(channel, peakLinear: 0, dt: 0.5)
        }
        #expect(channel.levelDB == MonitorAudioMeterBallistics.floorDB)
        #expect(channel.peakDB == MonitorAudioMeterBallistics.floorDB)
    }

    @Test func newMaximaRestartTheHold() {
        var channel = MonitorAudioMeterBallistics.step(.silent, peakLinear: 0.5, dt: 0.04)
        channel = MonitorAudioMeterBallistics.step(channel, peakLinear: 0, dt: 1.0)
        #expect(channel.peakAge == 1.0)
        channel = MonitorAudioMeterBallistics.step(channel, peakLinear: 0.9, dt: 0.04)
        #expect(channel.peakAge == 0)
        #expect(abs(channel.peakDB - MonitorAudioMeterBallistics.decibels(fromLinear: 0.9)) < 1e-9)
    }

    @Test func peakMarkerNeverReadsBelowTheBar() {
        var channel = MonitorAudioMeterBallistics.step(.silent, peakLinear: 0.1, dt: 0.04)
        // Long quiet stretch lets the peak decay; a fresh transient lifts the bar above it.
        for _ in 0..<20 {
            channel = MonitorAudioMeterBallistics.step(channel, peakLinear: 0, dt: 0.5)
        }
        channel = MonitorAudioMeterBallistics.step(channel, peakLinear: 0.8, dt: 0.04)
        #expect(channel.peakDB >= channel.levelDB)
    }
}
