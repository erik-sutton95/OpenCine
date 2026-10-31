import Foundation
import OpenCineCore
import OpenCineMedia
import Testing

// Mirrored by Android `MediaTransferRateTest`. Every instant is explicit: no wall clock.

private func at(_ milliseconds: Int) -> MonotonicInstant { .init(.milliseconds(milliseconds)) }

/// A steady stream: `bytesPerSecond` arriving in chunks every `stepMilliseconds`.
private func stream(
    _ estimator: inout MediaTransferRateEstimator, from start: Int, to end: Int,
    bytesPerSecond: UInt64, startingAt total: UInt64 = 0, stepMilliseconds: Int = 50
) -> UInt64 {
    var total = total
    var time = start
    while time < end {
        time += stepMilliseconds
        total += bytesPerSecond * UInt64(stepMilliseconds) / 1000
        estimator.record(totalBytes: total, at: at(time))
    }
    return total
}

@Test func transferRateReadsASteadyDownload() {
    var estimator = MediaTransferRateEstimator(startedAt: at(0))
    _ = stream(&estimator, from: 0, to: 3000, bytesPerSecond: 42_000_000)
    #expect(estimator.rate(at: at(3000)).label == "42 MB/s")
}

@Test func transferRateShowsNothingUntilThereIsEnoughData() {
    var estimator = MediaTransferRateEstimator(startedAt: at(0))
    #expect(estimator.rate(at: at(0)).label == nil)
    // 0.4 s and 40 KB: too little of either.
    _ = stream(&estimator, from: 0, to: 400, bytesPerSecond: 100_000)
    #expect(estimator.rate(at: at(400)) == .measuring)
    // Half a second in, the slow download reads.
    _ = stream(&estimator, from: 400, to: 500, bytesPerSecond: 100_000, startingAt: 40_000)
    #expect(estimator.rate(at: at(500)).label == "100 KB/s")
}

@Test func transferRateReadsEarlyOnceAQuarterMegabyteArrived() {
    var estimator = MediaTransferRateEstimator(startedAt: at(0))
    _ = stream(&estimator, from: 0, to: 300, bytesPerSecond: 2_000_000)
    #expect(estimator.rate(at: at(300)).label == "2.0 MB/s")
}

@Test func transferRateFollowsASpeedChangeWithinTheWindow() {
    var estimator = MediaTransferRateEstimator(startedAt: at(0))
    var total = stream(&estimator, from: 0, to: 4000, bytesPerSecond: 30_000_000)
    #expect(estimator.rate(at: at(4000)).label == "30 MB/s")
    total = stream(&estimator, from: 4000, to: 5000, bytesPerSecond: 5_000_000, startingAt: total)
    // Half way through the window: the average of the two speeds.
    #expect(estimator.rate(at: at(5000)).label == "18 MB/s")
    _ = stream(&estimator, from: 5000, to: 6500, bytesPerSecond: 5_000_000, startingAt: total)
    #expect(estimator.rate(at: at(6500)).label == "5.0 MB/s")
}

@Test func transferRateSaysStalledAfterThreeSecondsWithoutBytesAndRecovers() {
    var estimator = MediaTransferRateEstimator(startedAt: at(0))
    var total = stream(&estimator, from: 0, to: 2000, bytesPerSecond: 20_000_000)
    // Bytes stop: the rate falls while the window drains, then reads Stalled at 3 s.
    #expect(estimator.rate(at: at(3000)).label == "10 MB/s")
    #expect(estimator.rate(at: at(4999)) != .stalled)
    #expect(estimator.rate(at: at(5000)) == .stalled)
    #expect(estimator.rate(at: at(5000)).label == "Stalled")
    total = stream(&estimator, from: 9000, to: 11_000, bytesPerSecond: 20_000_000, startingAt: total)
    #expect(estimator.rate(at: at(11_000)).label == "20 MB/s")
}

@Test func transferRateSaysStalledWhenTheFirstByteNeverArrives() {
    let estimator = MediaTransferRateEstimator(startedAt: at(0))
    #expect(estimator.rate(at: at(2999)) == .measuring)
    #expect(estimator.rate(at: at(3000)) == .stalled)
}

@Test func transferRateLabelsUseDecimalUnits() {
    let cases: [(UInt64, String)] = [
        (0, "0 KB/s"), (999, "1 KB/s"), (512_000, "512 KB/s"), (999_499, "999 KB/s"),
        (999_500, "1.0 MB/s"), (4_249_999, "4.2 MB/s"), (4_250_000, "4.3 MB/s"),
        (9_949_999, "9.9 MB/s"), (9_950_000, "10 MB/s"), (42_400_000, "42 MB/s"),
        (118_600_000, "119 MB/s"),
    ]
    for (bytes, label) in cases {
        #expect(MediaTransferRate.label(bytesPerSecond: bytes) == label, "\(bytes) B/s")
    }
}

@Test func transferProgressCaptionJoinsPercentAndRate() {
    #expect(MediaTransferRate.caption(fraction: 0.186, rate: "42 MB/s") == "18% · 42 MB/s")
    #expect(MediaTransferRate.caption(fraction: 0.186, rate: nil) == "18%")
    #expect(MediaTransferRate.caption(fraction: 1.4, rate: "Stalled") == "100% · Stalled")
    #expect(MediaTransferRate.caption(fraction: nil, rate: "42 MB/s") == nil)
}

@Test func playerCacheTagReadsTheDownloadSpeed() {
    var values = MonitorPlaybackSourceValues(availability: .camera, progress: 0.42)
    #expect(values.sourceLabel == "ON CAMERA · CACHING ORIGINAL 42%")
    values.transferRate = "8.4 MB/s"
    #expect(values.sourceLabel == "ON CAMERA · CACHING ORIGINAL 42% · 8.4 MB/s")
    values.availability = .original
    #expect(values.sourceLabel == "ORIGINAL · ON PHONE")
}
