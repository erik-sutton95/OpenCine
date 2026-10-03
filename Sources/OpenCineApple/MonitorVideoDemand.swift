#if canImport(UIKit) && canImport(VideoToolbox)
import CoreGraphics
import Foundation
import OpenCineCore
import OpenCineMedia
import VideoToolbox

/// Actual decoded-pixel consumers share the assist decoder; they never create a second one.
public struct MonitorVideoDemand: Equatable, Sendable {
    public var assists: MonitorAssistPolicy
    public var decodedSource: Bool
    public var externalPreview: Bool
    public init(assists: MonitorAssistPolicy = .init(), decodedSource: Bool = false,
        externalPreview: Bool = false) {
        self.assists = assists; self.decodedSource = decodedSource
        self.externalPreview = externalPreview
    }
    public var needsDecodedSample: Bool {
        assists.needsGPUFeed || assists.needsScopes || decodedSource || externalPreview
    }
}

public enum MonitorDecodeEvent: Sendable { case submitted, decoded, presented }

/// Source calibration and instrumentation, independent of the native picture owner.
public struct MonitorVideoConfiguration: Sendable {
    public var assists: MonitorAssistConfiguration
    public var shouldRebuildSession: @Sendable (OSStatus) -> Bool
    public var policyChanged: @MainActor @Sendable (Bool) -> Void
    public var decodeEvent: @Sendable (MonitorDecodeEvent) -> Void
    /// Optional diagnostic output admission, used by developer stress scenarios.
    public var discardOutput: @Sendable () -> Bool
    public init(assists: MonitorAssistConfiguration = .init(),
        shouldRebuildSession: @escaping @Sendable (OSStatus) -> Bool = { $0 == kVTInvalidSessionErr },
        policyChanged: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
        decodeEvent: @escaping @Sendable (MonitorDecodeEvent) -> Void = { _ in },
        discardOutput: @escaping @Sendable () -> Bool = { false }) {
        self.assists = assists; self.shouldRebuildSession = shouldRebuildSession
        self.policyChanged = policyChanged; self.decodeEvent = decodeEvent
        self.discardOutput = discardOutput
    }
}

/// Capture before queuing encoded or decoded source input. Retirement rejects this token forever.
public struct MonitorVideoSourceToken: Equatable, Sendable {
    public let stream: StreamID
    public let generation: StreamGeneration
}

struct MonitorVideoSourceLifetime: Sendable {
    let stream = StreamID()
    private var generation = StreamGeneration()
    private var active = true
    var token: MonitorVideoSourceToken? {
        active ? MonitorVideoSourceToken(stream: stream, generation: generation) : nil
    }
    mutating func advance() { generation = generation.next() }
    mutating func close() { active = false; advance() }
}

public struct MonitorVideoFailure: Equatable, Sendable {
    public let at: Date
    public let status: Int32
    public let origin: String
    public let flags: UInt32
}

/// One source's recovery facts. Repainting a held image never advances source freshness.
public struct MonitorVideoHealth: Equatable, Sendable {
    public let source: MonitorVideoSourceToken?
    public let pipelineGeneration: StreamGeneration
    public let codec: LiveVideoCodec?
    public let pictureSize: CGSize?
    public let lastSourceFrameAt: Date?
    public let lastPresentedAt: Date?
    /// Native display completion can include cached repaints; it is not source freshness.
    public let lastDisplayPresentedAt: Date?
    public let lastRandomAccessAt: Date?
    public let hasAcceptedRandomAccess: Bool
    public let referenceRecoveryNeeded: Bool
    public let awaitingRandomAccess: Bool
    public let nativeOutputExpected: Bool
    public let outputAge: TimeInterval?
    public let displayReady: Bool
    public let displayedImageRemoved: Bool
    public let decoderFailed: Bool
    public let failure: MonitorVideoFailure?
    public let pipeline: MonitorDecodeMetrics.Snapshot
}
#endif
