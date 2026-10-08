import Foundation
import OpenCineMedia

/// One immutable rated record and the actual player item that displayed it.
public struct MonitorMediaPlaybackRatingRequest<Payload: Sendable>: Sendable {
    public let record: MonitorMediaRecord<Payload>
    public let item: MonitorPlaybackItemToken
    public let admission: MonitorPlaybackAdmission
    @MainActor public var isCurrent: Bool { admission.isCurrent() }
    init(record: MonitorMediaRecord<Payload>, item: MonitorPlaybackItemToken,
        admission: MonitorPlaybackAdmission) {
        self.record = record; self.item = item; self.admission = admission
    }
}

/// Readback and refusal belong to the source. The existing player owns the jobs and notice.
@MainActor public struct MonitorMediaPlaybackRatingService<Payload: Sendable> {
    public let levels: [Int]
    public let noticeDuration: Duration
    public let unavailableMessage: String?
    public let read: @MainActor (MonitorMediaPlaybackRatingRequest<Payload>) async -> Int?
    public let commit: @MainActor (Int, MonitorMediaPlaybackRatingRequest<Payload>) async -> MonitorMediaPictureRatingResult
    public init(levels: [Int], noticeDuration: Duration = .seconds(4), unavailableMessage: String? = nil,
        read: @escaping @MainActor (MonitorMediaPlaybackRatingRequest<Payload>) async -> Int?,
        commit: @escaping @MainActor (Int, MonitorMediaPlaybackRatingRequest<Payload>) async -> MonitorMediaPictureRatingResult) {
        self.levels = levels; self.noticeDuration = noticeDuration; self.unavailableMessage = unavailableMessage
        self.read = read; self.commit = commit
    }
}
