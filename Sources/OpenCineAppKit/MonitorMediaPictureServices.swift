import Foundation
import OpenCineMedia

/// An actual alternate image of the same shot. Wire/file format facts stay in the source.
public struct MonitorMediaPictureVariant<Payload: Sendable>: Sendable, Identifiable {
    public let label: String
    public let record: MonitorMediaRecord<Payload>
    public var id: MediaAssetID { record.asset.id }
    public init(label: String, record: MonitorMediaRecord<Payload>) {
        self.label = label; self.record = record
    }
}

public enum MonitorMediaPictureRatingResult: Equatable, Sendable {
    case confirmed(Int), refused(String?), unavailable
}

/// The source confirms a rating, including paired-file writes and its own refusal text.
@MainActor public struct MonitorMediaPictureRatingService<Payload: Sendable> {
    public let levels: [Int]
    public let read: @MainActor (MonitorMediaPictureRequest<Payload>) async -> Int?
    public let commit: @MainActor (Int, MonitorMediaPictureRequest<Payload>) async -> MonitorMediaPictureRatingResult
    public init(levels: [Int], read: @escaping @MainActor (MonitorMediaPictureRequest<Payload>) async -> Int?,
        commit: @escaping @MainActor (Int, MonitorMediaPictureRequest<Payload>) async -> MonitorMediaPictureRatingResult) {
        self.levels = levels; self.read = read; self.commit = commit
    }
}

public enum MonitorMediaPictureShareReadiness: Equatable, Sendable {
    case ready, waiting, unavailable
}

/// The existing transfer/cache reports readiness; the picture owner schedules waiting and cancel.
@MainActor public struct MonitorMediaPictureSharing<Payload: Sendable> {
    public let readiness: @MainActor (MonitorMediaPictureRequest<Payload>) -> MonitorMediaPictureShareReadiness
    public let perform: (@MainActor (MonitorMediaPictureRequest<Payload>) async throws -> Void)?
    public init(readiness: @escaping @MainActor (MonitorMediaPictureRequest<Payload>) -> MonitorMediaPictureShareReadiness,
        perform: (@MainActor (MonitorMediaPictureRequest<Payload>) async throws -> Void)? = nil) {
        self.readiness = readiness; self.perform = perform
    }
}

/// Native decoder/transfer observations, without a source or cache lifetime of their own.
public struct MonitorMediaPictureStatus: Equatable, Sendable {
    public let message: String?
    public let progress: Double?
    public let showsRating: Bool
    public init(message: String? = nil, progress: Double? = nil, showsRating: Bool = true) {
        self.message = message; self.progress = progress; self.showsRating = showsRating
    }
}

/// A bounded native decoder can publish progressive pictures only to its captured load.
@MainActor public struct MonitorMediaPicturePublication<Payload: Sendable, Picture> {
    public let request: MonitorMediaPictureRequest<Payload>
    private let picture: @MainActor (Picture) -> Void
    private let status: @MainActor (MonitorMediaPictureStatus) -> Void
    init(request: MonitorMediaPictureRequest<Payload>, picture: @escaping @MainActor (Picture) -> Void,
        status: @escaping @MainActor (MonitorMediaPictureStatus) -> Void) {
        self.request = request; self.picture = picture; self.status = status
    }
    public var isCurrent: Bool { request.isCurrent() }
    public func publish(_ value: Picture) { if isCurrent { picture(value) } }
    public func publish(status value: MonitorMediaPictureStatus) { if isCurrent { status(value) } }
}
