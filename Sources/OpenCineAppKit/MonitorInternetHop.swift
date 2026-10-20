import Foundation
import Network
import Observation
import OpenCineCore

/// The app's one approved departure from the camera network for the internet (A2-16): leave
/// the camera's Wi-Fi, wait for an internet route, come back. Only one hop runs at a time; a
/// second begin is refused rather than stealing the running one. The return is consumed once,
/// and only while the session that left is still current. The native leave and rejoin stay the
/// app's (its Wi-Fi joiner), through `Port`.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorInternetHop<Route> {
    /// Authority over the running hop. A transfer makes a new token and retires the old one.
    public struct Token: Hashable, Sendable {
        fileprivate let hop: UUID
        fileprivate let revision: UUID
    }

    /// The app's native leave and return.
    @MainActor public struct Port {
        public let onCameraNetwork: @MainActor () -> Bool
        /// Leaves the camera network; returns the route to come back to, or nil when the phone
        /// never left (the hop then ends with nothing to rejoin). `current` says whether the hop
        /// still holds; a leave that already started returns its route so the return is owed.
        public let leave: @MainActor (Route, _ current: @escaping @MainActor () -> Bool) async -> Route?
        /// Whether the route may still be rejoined: the session that left is the current one.
        public let admitsReturn: @MainActor (Route) -> Bool
        /// Rejoins once; `current` says whether no newer hop began since.
        public let rejoin: @MainActor (Route, _ current: @escaping @MainActor () -> Bool) async -> Void
        /// Whether the phone has an internet route once off the camera network.
        public let online: @MainActor () async -> Bool
        public init(
            onCameraNetwork: @escaping @MainActor () -> Bool,
            leave: @escaping @MainActor (Route, _ current: @escaping @MainActor () -> Bool) async -> Route?,
            admitsReturn: @escaping @MainActor (Route) -> Bool = { _ in true },
            rejoin: @escaping @MainActor (Route, _ current: @escaping @MainActor () -> Bool) async -> Void,
            online: (@MainActor () async -> Bool)? = nil
        ) {
            self.onCameraNetwork = onCameraNetwork
            self.leave = leave
            self.admitsReturn = admitsReturn
            self.rejoin = rejoin
            // Resolved here, not as a closure-literal default (swiftlang/swift#92017).
            self.online = online ?? { await MonitorInternetPath.satisfied() }
        }
    }

    public private(set) var token: Token?
    public var isActive: Bool { token != nil }
    @ObservationIgnored private let port: Port
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private var latestRevision: UUID?
    @ObservationIgnored private var latestHop: UUID?
    @ObservationIgnored private var leaving: Task<Void, Never>?
    /// The route the running hop left from, once it has left.
    @ObservationIgnored private var left: (hop: UUID, route: Route)?
    /// The one return a finished hop still owes.
    @ObservationIgnored private var owed: (hop: UUID, route: Route)?

    public init(
        port: Port,
        sleep: @escaping @MainActor (Duration) async -> Void = hostSleepUntilCancelled(for:)
    ) {
        self.port = port
        self.sleep = sleep
    }

    public var onCameraNetwork: Bool { port.onCameraNetwork() }

    /// Starts a hop from the captured route. Refused (nil) while a hop runs or when the
    /// admission fails; the leave runs only while the hop and its admission hold.
    @discardableResult public func begin(
        _ route: Route, admission: @escaping @MainActor () -> Bool = { true }
    ) -> Token? {
        guard token == nil, admission() else { return nil }
        let hop = UUID()
        let next = Token(hop: hop, revision: UUID())
        latestRevision = next.revision
        latestHop = hop
        token = next
        // A new departure supersedes an older hop's pending return: the phone is leaving again.
        owed = nil
        left = nil
        leaving = Task { [weak self] in
            guard let self else { return }
            guard self.token?.hop == hop, !Task.isCancelled, admission() else {
                if let current = self.token, current.hop == hop { self.end(current) }
                return
            }
            let route = await self.port.leave(route) { [weak self] in
                self?.token?.hop == hop && !Task.isCancelled && admission()
            }
            guard self.token?.hop == hop, !Task.isCancelled else {
                // The hop ended while leaving: the phone has left, so its return is still owed.
                if let route, self.token == nil, self.latestHop == hop {
                    self.owe(hop: hop, route: route)
                }
                return
            }
            guard let route else {
                if let current = self.token { self.end(current) }
                return
            }
            self.left = (hop, route)
            self.leaving = nil
        }
        return next
    }

    public func owns(_ candidate: Token) -> Bool { token == candidate }

    /// Hands the running hop to a new owner without another leave; the old token is retired.
    public func transfer(_ candidate: Token) -> Token? {
        guard owns(candidate) else { return nil }
        let next = Token(hop: candidate.hop, revision: UUID())
        latestRevision = next.revision
        token = next
        return next
    }

    /// Ends the hop once, for its current owner only, and starts the one return it owes. The
    /// returned task finishes when the rejoin has run (nil when nothing is rejoined).
    @discardableResult public func end(_ candidate: Token) -> Task<Void, Never>? {
        guard owns(candidate) else { return nil }
        token = nil
        leaving?.cancel()
        leaving = nil
        guard let left, left.hop == candidate.hop else { return nil }
        self.left = nil
        return owe(hop: left.hop, route: left.route)
    }

    /// The hop of `candidate` ended and nothing newer began since.
    public func ended(_ candidate: Token) -> Bool {
        token == nil && latestRevision == candidate.revision
    }

    /// Waits for an internet route off the camera network, while the token owns the hop.
    public func waitForInternet(_ candidate: Token, timeout: Duration = .seconds(30)) async -> Bool {
        let tick = Duration.milliseconds(500)
        var waited = Duration.zero
        while waited < timeout {
            guard !Task.isCancelled, owns(candidate) else { return false }
            if !port.onCameraNetwork() {
                let online = await port.online()
                guard !Task.isCancelled, owns(candidate) else { return false }
                if online { return true }
            }
            await sleep(tick)
            waited += tick
        }
        return false
    }

    /// The hop as a delivery's internet lease. `route` captures where to come back to at begin.
    public func deliveryService(
        route: @escaping @MainActor () -> Route?, admission: @escaping @MainActor () -> Bool = { true }
    ) -> MonitorDeliveryInternetService<Token> {
        .init(
            needsHop: { [weak self] in self?.port.onCameraNetwork() ?? false },
            begin: { [weak self] in
                guard let self, let route = route() else { return nil }
                return self.begin(route, admission: admission)
            },
            owns: { [weak self] in self?.owns($0) ?? false },
            wait: { [weak self] in await self?.waitForInternet($0) ?? false },
            restoreEntered: { [weak self] in await self?.end($0)?.value },
            restore: { [weak self] in _ = self?.end($0) })
    }

    @discardableResult private func owe(hop: UUID, route: Route) -> Task<Void, Never> {
        owed = (hop, route)
        return Task { [weak self] in
            guard let self, self.token == nil, let owed = self.owed, owed.hop == hop,
                self.port.admitsReturn(owed.route)
            else { return }
            self.owed = nil
            await self.port.rejoin(owed.route) { [weak self] in
                self?.token == nil && self?.latestHop == hop
            }
        }
    }
}

/// The one reachability probe every hop uses: the system reports a satisfied path.
public enum MonitorInternetPath {
    public static func satisfied() async -> Bool {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        return await withCheckedContinuation { continuation in
            let once = Once()
            monitor.pathUpdateHandler = { path in
                if once.claim() { continuation.resume(returning: path.status == .satisfied) }
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }

    /// The first path update answers; later ones are ignored.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}
