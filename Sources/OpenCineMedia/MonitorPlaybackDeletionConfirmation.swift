import Foundation

/// Frozen operator copy for one captured playback deletion, independent of camera protocol.
public struct MonitorPlaybackDeletionConfirmation: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String?
    public init(id: UUID = UUID(), title: String, message: String? = nil) {
        self.id = id; self.title = title; self.message = message
    }
}
