import Foundation

/// The phone's current camera facts. Native admission remains with the app's command path.
public struct WatchCommandFacts: Equatable, Sendable {
    public var isRecording: Bool
    public var isBusy: Bool
    public var isLive: Bool
    public var isPhotography: Bool

    public init(isRecording: Bool, isBusy: Bool, isLive: Bool, isPhotography: Bool) {
        self.isRecording = isRecording
        self.isBusy = isBusy
        self.isLive = isLive
        self.isPhotography = isPhotography
    }
}

/// The result of handing a Watch shutter request to the app's existing command path.
public enum WatchCommandDispatch: Equatable, Sendable {
    /// A command was submitted. Camera acknowledgement and recording observations arrive later.
    case sent
    /// The command path refused the request or could not construct a command.
    case notSent
    /// The camera or source shown on the Watch no longer owns the command.
    case targetChanged
}

/// Shared Watch preflight and result copy. Apps retain native command and source admission.
public enum WatchCommandPolicy {
    public static let unavailable = WatchCommandResult(
        accepted: false, isRecording: false, error: "unavailable")

    public static func refusal(_ action: RelayWatchAction, facts: WatchCommandFacts)
        -> WatchCommandResult?
    {
        if facts.isBusy { return refused(WatchRelayCopy.busy, facts.isRecording) }
        guard facts.isLive else { return refused(WatchRelayCopy.connectFirst, false) }
        switch action {
        case .capture where !facts.isPhotography:
            return refused(WatchRelayCopy.switchToPhoto, facts.isRecording)
        case .toggleRecord where facts.isPhotography:
            return refused(WatchRelayCopy.switchToVideo, facts.isRecording)
        case .capture, .toggleRecord: return nil
        // Resume is answered by the relay owner and never dispatches a camera command.
        case .resume: return unavailable
        }
    }

    public static func result(_ dispatch: WatchCommandDispatch, isRecording: Bool)
        -> WatchCommandResult
    {
        switch dispatch {
        case .sent: WatchCommandResult(accepted: true, isRecording: isRecording, error: nil)
        case .notSent: refused(WatchRelayCopy.busy, isRecording)
        case .targetChanged: refused(WatchRelayCopy.cameraChanged, isRecording)
        }
    }

    /// Reads the reported recording state again after native submission, without inventing an ACK.
    public static func answer(
        _ action: RelayWatchAction, facts: () -> WatchCommandFacts,
        shutter: () -> WatchCommandDispatch
    ) -> WatchCommandResult {
        if let refusal = refusal(action, facts: facts()) { return refusal }
        let dispatch = shutter()
        return result(dispatch, isRecording: facts().isRecording)
    }

    private static func refused(_ copy: String, _ isRecording: Bool) -> WatchCommandResult {
        WatchCommandResult(accepted: false, isRecording: isRecording, error: copy)
    }
}
