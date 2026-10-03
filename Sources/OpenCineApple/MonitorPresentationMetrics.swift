#if canImport(Metal)
import Foundation
import OpenCineMedia

/// Measurement boundary for journal windows; renderer scheduling is independent.
public struct MonitorPresentationMetrics {
    public struct Window: Sendable {
        public let gpuFramesPerSecond: Double
        public let maximumGapMilliseconds: Double
        public let maximumAcquireMilliseconds: Double
        public let maximumGPUCompletionMilliseconds: Double
    }

    private var cadence: DeliveryCadence
    private var maximumAcquireMilliseconds = 0.0
    private var maximumGPUCompletionMilliseconds = 0.0

    public init(startedAt: TimeInterval) { cadence = DeliveryCadence(startedAt: startedAt) }

    public mutating func notePresented(at now: TimeInterval) { cadence.note(at: now) }

    public mutating func noteAcquire(milliseconds: Double) {
        maximumAcquireMilliseconds = max(maximumAcquireMilliseconds, milliseconds)
    }

    public mutating func noteGPUCompletion(milliseconds: Double) {
        maximumGPUCompletionMilliseconds = max(maximumGPUCompletionMilliseconds, milliseconds)
    }

    public mutating func drain(at now: TimeInterval) -> Window? {
        guard let timing = cadence.takeWindow(at: now) else { return nil }
        let window = Window(
            gpuFramesPerSecond: timing.hertz,
            maximumGapMilliseconds: timing.maximumGapMilliseconds,
            maximumAcquireMilliseconds: maximumAcquireMilliseconds,
            maximumGPUCompletionMilliseconds: maximumGPUCompletionMilliseconds)
        maximumAcquireMilliseconds = 0
        maximumGPUCompletionMilliseconds = 0
        return window
    }
}

#endif
