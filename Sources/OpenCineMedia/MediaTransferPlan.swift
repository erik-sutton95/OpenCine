import Foundation

/// Ordered real source attempts. Routing and refusal classification belong to the integration;
/// the consuming library owns task lifetime, fresh writers, progress and canonical commit.
@MainActor public struct MediaTransferPlan {
    public typealias Attempt = @MainActor (any MediaByteSink) async throws -> MediaTransferReceipt
    public let expectedByteCount: UInt64?
    public let attempts: [Attempt]
    public let retry: @MainActor (any Error) -> Bool
    public let accepted: (@MainActor (Int, MediaTransferReceipt) -> Void)?
    public init(expectedByteCount: UInt64? = nil, attempts: [Attempt],
        retry: @escaping @MainActor (any Error) -> Bool,
        accepted: (@MainActor (Int, MediaTransferReceipt) -> Void)? = nil) {
        self.expectedByteCount = expectedByteCount.flatMap { $0 > 0 ? $0 : nil }
        self.attempts = attempts; self.retry = retry; self.accepted = accepted
    }
}
