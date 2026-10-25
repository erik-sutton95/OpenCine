import Foundation
import OpenCineMedia

/// The FPS chip word and the signal bars every live monitor shows (A5-17): Swift twin of the
/// Kotlin `MonitorLinkMeter`. Both word the chip with `chipLabel` and filter bars through
/// `LinkSignalBars`; both suites read `Fixtures/link-readout-vectors.tsv`. Apple decoders report
/// each presented picture, so the rate is `FrameRateSampler`'s window over those pictures
/// (Kotlin samples a presented-picture counter once per readout period).
public struct MonitorLinkMeter: Sendable {
    public static let idle = "\u{2014}"

    public private(set) var label = MonitorLinkMeter.idle
    public private(set) var bars = 0
    private var sampler = FrameRateSampler()
    private var signalBars = LinkSignalBars()

    public init() {}

    /// The delivery rate the chip prints while pictures arrive; 0 before the first interval.
    public var measuredFPS: Double { sampler.displayFPS }
    /// Inter-picture intervals in the window (the feed warm-up gate reads it).
    public var rollingIntervals: Int { sampler.intervalCount }

    /// One presented picture. True when the measured rate changed.
    @discardableResult
    public mutating func notePresented(at timestamp: TimeInterval) -> Bool {
        let before = sampler.displayFPS
        sampler.recordFrame(at: timestamp)
        return sampler.displayFPS != before
    }

    /// The picture source was replaced: the rate measures from the next picture.
    public mutating func restart() {
        sampler = FrameRateSampler()
    }

    /// The readout timer: a feed silent for two seconds measures 0 again.
    public mutating func age(at timestamp: TimeInterval) {
        sampler.age(at: timestamp)
    }

    /// Words the chip and filters the bars for the link as observed now. `linkHealthScore` is the
    /// source's `CameraLinkHealthScorer` score (it alone sees its decoder and transport faults);
    /// `linkBars` replaces the filtered bars for a source that scores its bars itself.
    public mutating func update(
        connection: CameraConnectionPhase, feedRecovering: Bool, sessionRecovering: Bool,
        linkHealthScore: Int, linkBars: Int? = nil
    ) {
        label = Self.chipLabel(
            connection: connection, feedRecovering: feedRecovering,
            sessionRecovering: sessionRecovering, formattedFPS: sampler.formatted,
            measuredFPS: sampler.displayFPS)
        let scored = linkBars ?? signalBars.update(score: linkHealthScore)
        // A held frame is not a delivered one: no bars beside the held-frame badge.
        bars = sessionRecovering ? 0 : scored
    }

    /// The chip word: the held-frame badge while a dropped session holds the last frame, FAIL,
    /// RECOV while the stream restarts, the measured rate, a dash while idle, else LINK.
    public static func chipLabel(
        connection: CameraConnectionPhase, feedRecovering: Bool, sessionRecovering: Bool,
        formattedFPS: String, measuredFPS: Double
    ) -> String {
        if sessionRecovering { return SessionRecoveryCopy.heldFrameBadge }
        if case .failed = connection { return "FAIL" }
        if feedRecovering { return "RECOV" }
        if measuredFPS > 0 { return formattedFPS }
        if case .idle = connection { return idle }
        return "LINK"
    }
}
