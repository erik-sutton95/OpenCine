import Foundation
import OpenCineCameraVocabulary

/// Storage observations resolved by the integration, rather than the gallery UI.
public struct DJIMediaSourcePolicy: Equatable, Sendable {
    public let sourceOwnsFavorites: Bool?
    public let singleSDStorage: Bool?

    public init(model: CameraModel?, inPlayback: Bool, internalTotalMB: Int) {
        sourceOwnsFavorites = model.map { $0.family == .nano }
        // Playback can report one zeroed storage block while both stores remain reachable.
        if model?.name.localizedCaseInsensitiveContains("Pocket 3") == true {
            singleSDStorage = true
        } else if !inPlayback, internalTotalMB >= 0 {
            singleSDStorage = internalTotalMB == 0
        } else {
            singleSDStorage = nil
        }
    }
}
