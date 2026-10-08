import Foundation
import Insta360Protocol

/// Published identity of one actual Apple Luna session. This owns no queue or transport.
public final class LunaCommandOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var window = UUID()
    private var active = true
    public init() {}
    public var source: UUID {
        lock.lock()
        defer { lock.unlock() }
        return window
    }
    public func replaceSource() {
        lock.lock()
        window = UUID()
        lock.unlock()
    }
    public func retire() {
        lock.lock()
        active = false
        lock.unlock()
    }
    fileprivate func admits(_ source: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && window == source
    }
}

public enum LunaCommandAdmissionError: Error, Equatable, Sendable { case expired }

/// Authority for one supplied operation. Only thread-safe published facts belong in the predicate.
public struct LunaCommandAdmission: Sendable {
    public let owner: LunaCommandOwner
    public let source: UUID
    private let current: @Sendable () -> Bool
    public init(owner: LunaCommandOwner, isCurrent: @escaping @Sendable () -> Bool) {
        self.owner = owner
        source = owner.source
        current = isCurrent
    }
    fileprivate var ownsCapturedSource: Bool { owner.admits(source) }
    public var isCurrent: Bool {
        guard ownsCapturedSource else { return false }
        let accepted = current()
        return ownsCapturedSource && accepted
    }
    public func admits(_ owner: LunaCommandOwner?) -> Bool { owner === self.owner && isCurrent }
    public func require(owner: LunaCommandOwner?) throws {
        guard admits(owner) else { throw LunaCommandAdmissionError.expired }
    }
    public func requireCurrent() throws {
        guard isCurrent else { throw LunaCommandAdmissionError.expired }
    }
}

/// These are Apple-native integration ports; protocol bytes and Core commands are unchanged.
public typealias LunaCommandRequestBuilder = @MainActor () throws -> LunaRequest
public typealias LunaCommandDidDispatch = @MainActor () -> Void
public typealias LunaAdmittedCommandSend =
    @MainActor (
        @escaping LunaCommandRequestBuilder, LunaCommandAdmission, @escaping LunaCommandDidDispatch
    ) async throws -> Data
public typealias LunaAdmittedCommandSendWithin =
    @MainActor (
        @escaping LunaCommandRequestBuilder, LunaCommandAdmission, Duration,
        @escaping LunaCommandDidDispatch
    ) async throws -> Data

/// Captures the actual native transport object, endpoint and its existing replacement counter.
/// A repeated endpoint object cannot revive an older generation's unsent write.
struct LunaNativeCommandSource: Equatable, Sendable {
    let transport: ObjectIdentifier
    let epoch: Int
    let endpoint: ObjectIdentifier?
    let member: ObjectIdentifier?
    init(transport: AnyObject, epoch: Int, endpoint: AnyObject?, member: AnyObject? = nil) {
        self.transport = ObjectIdentifier(transport)
        self.epoch = epoch
        self.endpoint = endpoint.map(ObjectIdentifier.init)
        self.member = member.map(ObjectIdentifier.init)
    }
    func admits(_ current: Self) -> Bool { endpoint != nil && self == current }
}

/// One frame's native entry, shared by the actual TCP and BLE leaves. After its first chunk
/// enters, receipt expiry does not interrupt that frame's existing completion/chunk path.
@MainActor
struct LunaCommandFirstDispatch {
    let admission: LunaCommandAdmission
    let source: LunaNativeCommandSource
    private(set) var entered = false
    init(admission: LunaCommandAdmission, source: LunaNativeCommandSource) {
        self.admission = admission
        self.source = source
    }
    mutating func perform(
        current: LunaNativeCommandSource, native: () -> Void,
        didDispatch: LunaCommandDidDispatch
    ) throws {
        try perform(current: { current }, native: native, didDispatch: didDispatch)
    }
    mutating func perform(
        current readCurrent: () -> LunaNativeCommandSource, native: () -> Void,
        didDispatch: LunaCommandDidDispatch
    ) throws {
        if !entered {
            try admission.requireCurrent()
            guard admission.ownsCapturedSource else { throw LunaCommandAdmissionError.expired }
            let current = readCurrent()
            guard admission.ownsCapturedSource, source.admits(current) else {
                throw LunaCommandAdmissionError.expired
            }
        }
        native()
        if !entered {
            entered = true
            didDispatch()
        }
    }
}
