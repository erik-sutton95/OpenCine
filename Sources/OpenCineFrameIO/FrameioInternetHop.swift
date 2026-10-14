import Foundation

/// Serialized ownership of one operator-approved internet handoff. The app supplies its native
/// leave/rejoin actions; this value only admits the current popup or delivery's completion.
/// Keep it in the host that owns the route and mutate it on that host's executor.
@available(*, deprecated, message: "Migrate app-owned routing to MonitorInternetHop before the later removal release")
public struct FrameioInternetHop: Sendable {
    public struct Token: Equatable, Sendable {
        fileprivate let owner: UUID
        fileprivate let revision: UUID
    }

    private let owner = UUID()
    private var latestRevision: UUID?
    public private(set) var token: Token?

    public init() {}

    /// A new handoff supersedes any previous completion authority.
    @discardableResult public mutating func begin() -> Token {
        let next = Token(owner: owner, revision: UUID())
        latestRevision = next.revision
        token = next
        return next
    }

    public func owns(_ candidate: Token) -> Bool { token == candidate }

    /// Transfer an existing handoff without performing another network operation. The popup's
    /// old token becomes stale before its close/disappear callback can run.
    public mutating func transfer(_ candidate: Token) -> Token? {
        guard owns(candidate) else { return nil }
        return begin()
    }

    /// Returns true once, only to the current owner that may perform the native rejoin.
    @discardableResult public mutating func end(_ candidate: Token) -> Bool {
        guard owns(candidate) else { return false }
        token = nil
        return true
    }

    /// Publication after end may finish only this revision. A begin/end ABA remains retired.
    /// This observation never grants another end or another native cleanup operation.
    public func ended(_ candidate: Token) -> Bool {
        token == nil && candidate.owner == owner && latestRevision == candidate.revision
    }
}
