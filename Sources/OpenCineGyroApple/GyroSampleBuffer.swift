#if os(iOS)
import Foundation
import OpenCineGyro

/// The bounded handoff between Core Motion's serial callback queue and the log writer.
// SAFETY: every access to mutable callback state is guarded by lock.
public final class GyroSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [GyroSample] = []
    private var failure: GyroLogTermination?

    /// Creates an empty handoff.
    public init() {}

    /// Appends one sample, or records an overflow once the bound is full.
    public func append(_ sample: GyroSample) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        guard samples.count < GyroTakeSession.maximumBufferedSamples else {
            failure = .bufferOverflow
            return
        }
        samples.append(sample)
    }

    /// Records that the sensor stalled; later samples are ignored until drained.
    public func fail() {
        lock.lock()
        defer { lock.unlock() }
        failure = .sensorStalled
    }

    /// Takes the queued samples and the recorded failure, leaving the buffer empty.
    public func drain() -> (samples: [GyroSample], failure: GyroLogTermination?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (samples, failure)
        samples.removeAll(keepingCapacity: true)
        failure = nil
        return result
    }
}
#endif
