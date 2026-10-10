#if os(iOS)
import Foundation
import OpenCineCameraVocabulary
import OpenCineCore

public enum CaptureAudioControl: String, Hashable, Sendable {
    case channel, wind, direction, vocal
}

/// Values belong to the optional audio domain, outside the common capture command entry.
public enum CaptureAudioValue: Hashable, Sendable {
    case channel(AudioChannel)
    case wind(WindNoiseReduction)
    case direction(DirectionalAudio)
    case vocal(VocalBoost)

    public var label: String {
        switch self {
        case .channel(let value): value.label
        case .wind(let value): value.label
        case .direction(let value): value.label
        case .vocal(let value): value.label
        }
    }
}

public struct CaptureAudioField: Hashable, Sendable, Identifiable {
    public var id: CaptureAudioControl
    public var title: String
    public var choices: [CaptureAudioValue]
    public var observed: CaptureAudioValue?
    public var isEditable: Bool

    public init(id: CaptureAudioControl, title: String, choices: [CaptureAudioValue],
        observed: CaptureAudioValue? = nil, isEditable: Bool = true) {
        self.id = id
        self.title = title
        self.choices = choices
        self.observed = observed
        self.isEditable = isEditable
    }
}

public enum CaptureAudioCommitResult: Equatable, Sendable {
    case submitted, unavailable, refused
}

/// A control lifetime, including reconnects to the same saved camera.
public struct CaptureAudioSourceID: Hashable, Sendable {
    public var session: CameraSessionID
    public var epoch: ControlEpoch

    public init(session: CameraSessionID, epoch: ControlEpoch) {
        self.session = session
        self.epoch = epoch
    }
}

/// One session's optional service. A missing service supplies no controls or discarded setters.
@MainActor public struct CaptureAudioService {
    public var sourceID: CaptureAudioSourceID
    public var fields: [CaptureAudioField]
    public var commit: (CaptureAudioValue) -> CaptureAudioCommitResult
    public var refresh: () async -> Void

    public init(sourceID: CaptureAudioSourceID, fields: [CaptureAudioField],
        commit: @escaping (CaptureAudioValue) -> CaptureAudioCommitResult,
        refresh: @escaping () async -> Void) {
        self.sourceID = sourceID
        self.fields = fields
        self.commit = commit
        self.refresh = refresh
    }
}
#endif
