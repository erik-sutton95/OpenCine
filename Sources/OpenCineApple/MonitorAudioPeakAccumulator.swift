#if os(iOS)
    import Foundation
    import os
    import OpenCineMedia

    public struct MonitorAudioPeakSample: Sendable {
        public let sourceGeneration: UInt64
        public let preparationGeneration: UInt64
        public let left: Float
        public let right: Float
    }

    /// One polling consumer's history. A source or preparation change cannot inherit held peaks.
    @MainActor public final class MonitorAudioMeterSampler {
        private let owner: MonitorAudioPeakAccumulator
        private var sourceGeneration: UInt64?
        private var preparationGeneration: UInt64?
        private var levels = MonitorAudioMeterLevels.silent
        public init(owner: MonitorAudioPeakAccumulator) { self.owner = owner }
        public func reset() {
            sourceGeneration = nil
            preparationGeneration = nil
            levels = .silent
        }
        public func step(dt: Double, outputMuted: Bool = false) -> MonitorAudioMeterLevels? {
            guard let sample = owner.sampleAndReset() else {
                reset()
                return nil
            }
            if sourceGeneration != sample.sourceGeneration
                || preparationGeneration != sample.preparationGeneration
            {
                levels = .silent
                sourceGeneration = sample.sourceGeneration
                preparationGeneration = sample.preparationGeneration
            }
            levels = MonitorAudioMeterLevels(
                left: MonitorAudioMeterBallistics.step(
                    levels.left, peakLinear: outputMuted ? 0 : Double(sample.left), dt: dt),
                right: MonitorAudioMeterBallistics.step(
                    levels.right, peakLinear: outputMuted ? 0 : Double(sample.right), dt: dt))
            return levels
        }
    }

    /// One native audio owner's prepared source. Absence stays distinct from measured silence.
    public final class MonitorAudioPeakAccumulator: @unchecked Sendable {
        private struct State {
            var closed = false
            var next: UInt64 = 0
            var active: UInt64?
            var revision: UInt64 = 0
            var measured = false
            var left: Float = 0
            var right: Float = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        public init() {}

        public func beginSource() -> MonitorAudioPeakLease? {
            let generation = state.withLock { current -> UInt64? in
                guard !current.closed else { return nil }
                current.next &+= 1
                current.active = current.next
                current.revision = 0
                current.measured = false
                current.left = 0
                current.right = 0
                return current.next
            }
            return generation.map { MonitorAudioPeakLease(owner: self, generation: $0) }
        }

        public func sampleAndReset() -> MonitorAudioPeakSample? {
            state.withLock { current in
                guard !current.closed, let generation = current.active, current.measured else {
                    return nil
                }
                let peaks = MonitorAudioPeakSample(
                    sourceGeneration: generation, preparationGeneration: current.revision,
                    left: current.left, right: current.right)
                current.left = 0
                current.right = 0
                return peaks
            }
        }

        public func close() {
            state.withLock { current in
                current.closed = true
                current.active = nil
                current.measured = false
                current.left = 0
                current.right = 0
            }
        }

        fileprivate func accepts(_ generation: UInt64) -> Bool {
            state.withLock { !$0.closed && $0.active == generation }
        }
        fileprivate func prepare(_ generation: UInt64) -> UInt64? {
            state.withLock { current in
                guard !current.closed, current.active == generation else { return nil }
                current.revision &+= 1
                current.measured = false
                current.left = 0
                current.right = 0
                return current.revision
            }
        }
        fileprivate func accepts(_ generation: UInt64, revision: UInt64) -> Bool {
            state.withLock { !$0.closed && $0.active == generation && $0.revision == revision }
        }
        fileprivate func ingest(_ generation: UInt64, revision: UInt64, left: Float, right: Float)
            -> Bool
        {
            state.withLock { current in
                guard !current.closed, current.active == generation else { return false }
                guard current.revision == revision else { return false }
                current.left = max(current.left, left)
                current.right = max(current.right, right)
                current.measured = true
                return true
            }
        }
        fileprivate func retire(_ generation: UInt64) -> Bool {
            state.withLock { current in
                guard !current.closed, current.active == generation else { return false }
                current.active = nil
                current.measured = false
                current.left = 0
                current.right = 0
                return true
            }
        }
    }

    public final class MonitorAudioPeakLease: Sendable {
        private let owner: MonitorAudioPeakAccumulator
        private let generation: UInt64
        fileprivate init(owner: MonitorAudioPeakAccumulator, generation: UInt64) {
            self.owner = owner
            self.generation = generation
        }
        public var isActive: Bool { owner.accepts(generation) }
        @discardableResult public func ingest(left: Float, right: Float) -> Bool {
            owner.ingest(generation, revision: 0, left: left, right: right)
        }
        public func prepare() -> MonitorAudioPeakWriter? {
            owner.prepare(generation).map {
                MonitorAudioPeakWriter(owner: owner, generation: generation, revision: $0)
            }
        }
        @discardableResult public func close() -> Bool { owner.retire(generation) }
    }
    /// Captured format/sample generation; it cannot prepare or retire another source.
    public final class MonitorAudioPeakWriter: Sendable {
        private let owner: MonitorAudioPeakAccumulator
        private let generation: UInt64
        private let revision: UInt64
        fileprivate init(owner: MonitorAudioPeakAccumulator, generation: UInt64, revision: UInt64) {
            self.owner = owner
            self.generation = generation
            self.revision = revision
        }
        public var isActive: Bool { owner.accepts(generation, revision: revision) }
        @discardableResult public func ingest(left: Float, right: Float) -> Bool {
            owner.ingest(generation, revision: revision, left: left, right: right)
        }
    }

#endif
