#if canImport(Metal)
import Foundation

/// One native model's asynchronous publication. Restarting retires every earlier completion.
public struct MonitorAsyncFrameState: Sendable {
    public struct Ticket: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let id: UInt64
        public let slot: Int
    }
    public struct Admission: Sendable {
        public let ticket: Ticket?
        public let readyIndex: Int?
        public let failure: String?
    }
    private var generation: UInt64 = 0
    private var nextID: UInt64 = 0
    private var current: Ticket?
    public private(set) var readyIndex: Int?
    private var failure: String?
    public init() {}
    public mutating func reserve(slot: Int) -> Admission {
        let previousFailure = failure
        failure = nil
        var ticket: Ticket?
        if current == nil && previousFailure == nil {
            nextID &+= 1
            ticket = Ticket(generation: generation, id: nextID, slot: slot)
            current = ticket
        }
        return Admission(ticket: ticket, readyIndex: readyIndex, failure: previousFailure)
    }
    @discardableResult
    public mutating func complete(_ ticket: Ticket, failure: String? = nil) -> Bool {
        guard current == ticket, ticket.generation == generation else { return false }
        current = nil
        if let failure { self.failure = failure }
        else { readyIndex = ticket.slot }
        return true
    }
    public mutating func reset() {
        generation &+= 1
        current = nil; readyIndex = nil; failure = nil
    }
}

#endif
