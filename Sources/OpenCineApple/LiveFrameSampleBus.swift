#if os(iOS)
import CoreVideo
import Foundation
import Observation
import OpenCineMedia

/// One monitor's source publications. A source lease fences replacement and retirement.
@MainActor @Observable
public final class LiveFrameSampleBus {
    public enum Role: Sendable { case live, playback }
    public final class Source: @unchecked Sendable {
        fileprivate let role: Role
        public let exposureCeiling: ScopeExposureCeiling
        fileprivate init(_ role: Role, profile: ScopeClipProfile) {
            self.role = role; exposureCeiling = ScopeExposureCeiling(profile: profile)
        }
    }
    @ObservationIgnored private var liveSource: Source?
    @ObservationIgnored private var playbackSource: Source?
    public private(set) var bundle = ScopeAssistBundle.empty
    public private(set) var playbackBundle: ScopeAssistBundle?
    @ObservationIgnored public private(set) var sourcePixelBuffer: CVPixelBuffer?
    @ObservationIgnored public private(set) var playbackSourcePixelBuffer: CVPixelBuffer?
    @ObservationIgnored public private(set) var playbackSourceTransfer: MonitorTransfer = .rec709
    public var usesPlaybackSource: Bool { playbackSource != nil }
    public private(set) var inspectorSourceEpoch: UInt64 = 0
    public private(set) var transfer: MonitorTransfer = .rec709
    public private(set) var reportedTransfer: MonitorTransfer?
    @ObservationIgnored private let profile: ScopeClipProfile
    @ObservationIgnored private let idleCeiling: ScopeExposureCeiling
    public var exposureCeiling: ScopeExposureCeiling {
        playbackSource?.exposureCeiling ?? liveSource?.exposureCeiling ?? idleCeiling
    }
    public private(set) var generation = 0
    @ObservationIgnored public private(set) var decodedFrames = 0
    public private(set) var publishedScopes = 0

    public init(profile: ScopeClipProfile = .init()) {
        self.profile = profile; idleCeiling = ScopeExposureCeiling(profile: profile)
    }

    public func openSource(_ role: Role) -> Source {
        let source = Source(role, profile: profile)
        switch role {
        case .live: clearLive(); liveSource = source
        case .playback: clearPlayback(); playbackSource = source
        }
        return source
    }
    public func isCurrent(_ source: Source?) -> Bool {
        guard let source else { return false }
        switch source.role {
        case .live: return liveSource === source
        case .playback: return playbackSource === source
        }
    }
    public func closeSource(_ source: Source?) {
        guard let source, isCurrent(source) else { return }
        switch source.role {
        case .live: liveSource = nil; clearLive()
        case .playback: playbackSource = nil; clearPlayback()
        }
    }
    public func clearPlaybackSource(_ source: Source?) {
        guard let source, source.role == .playback, isCurrent(source) else { return }
        clearPlayback()
    }
    public func noteDecodedFrame(_ source: Source?) {
        guard let source, source.role == .live, isCurrent(source) else { return }
        decodedFrames += 1
    }
    /// Raw picture retention does not tick scope observation. One bundle advances one revision.
    @discardableResult public func publish(
        _ owner: Source?, source: CVPixelBuffer?, transfer: MonitorTransfer,
        reportedTransfer: MonitorTransfer? = nil, bundle: ScopeAssistBundle?
    ) -> Bool {
        guard let owner, isCurrent(owner) else { return false }
        switch owner.role {
        case .live:
            if let source { sourcePixelBuffer = source }
            self.transfer = transfer
            self.reportedTransfer = reportedTransfer
            if let bundle { self.bundle = bundle; publishedScopes += 1; generation += 1 }
        case .playback:
            if let source { playbackSourcePixelBuffer = source; playbackSourceTransfer = transfer }
            if let bundle { playbackBundle = bundle }
        }
        return true
    }
    public var displayBundle: ScopeAssistBundle { usesPlaybackSource ? (playbackBundle ?? .empty) : bundle }
    public var inspectorSource: (buffer: CVPixelBuffer, transfer: MonitorTransfer)? {
        if usesPlaybackSource { return playbackSourcePixelBuffer.map { ($0, playbackSourceTransfer) } }
        return sourcePixelBuffer.map { ($0, transfer) }
    }
    private func clearPlayback() {
        playbackBundle = nil; playbackSourcePixelBuffer = nil; playbackSourceTransfer = .rec709
        inspectorSourceEpoch &+= 1
    }
    private func clearLive() {
        bundle = .empty; sourcePixelBuffer = nil; transfer = .rec709; reportedTransfer = nil
        generation = 0; decodedFrames = 0; publishedScopes = 0
        if playbackSource == nil { inspectorSourceEpoch &+= 1 }
    }
}
#endif
