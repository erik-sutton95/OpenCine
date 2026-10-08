import Foundation

/// Independent bounded native stages, with one-use completion tickets. Replacing a producer,
/// encoder profile or host retires outstanding tickets before a successor can borrow capacity.
public struct RelayBroadcastStages: Sendable {
    public enum Lane: Hashable, Sendable { case encoding, jpeg }
    public struct Ticket: Hashable, Sendable {
        public let stage: UUID
        public let lane: Lane
        public let id: UUID
    }
    public let encodingDepth: Int
    public let jpegDepth: Int
    private var lifetime = RelayConnectionLifetime()
    private var tickets: [Lane: Set<UUID>] = [:]
    public var token: UUID { lifetime.token }
    public var isActive: Bool { lifetime.active }
    public init(encodingDepth: Int = 2, jpegDepth: Int = 2) {
        precondition(encodingDepth > 0 && jpegDepth > 0)
        self.encodingDepth = encodingDepth
        self.jpegDepth = jpegDepth
        lifetime.begin()
    }
    public func inFlight(_ lane: Lane) -> Int { tickets[lane]?.count ?? 0 }
    public func admits(_ stage: UUID) -> Bool { lifetime.admits(stage) }
    public mutating func replace() {
        lifetime.begin()
        tickets.removeAll()
    }
    public mutating func close() {
        lifetime.retire()
        tickets.removeAll()
    }
    public mutating func admit(_ lane: Lane) -> Ticket? {
        let depth = lane == .encoding ? encodingDepth : jpegDepth
        guard lifetime.active, inFlight(lane) < depth else { return nil }
        let id = UUID()
        tickets[lane, default: []].insert(id)
        return Ticket(stage: token, lane: lane, id: id)
    }
    @discardableResult public mutating func complete(_ ticket: Ticket) -> Bool {
        guard lifetime.admits(ticket.stage), tickets[ticket.lane]?.remove(ticket.id) != nil else {
            return false
        }
        return true
    }
}
