#if canImport(Network)
import Foundation
import OpenCineCore

/// One host-owned Local Network privacy observer (TN3179). iOS has no API to read or request
/// this permission: the first local-network operation shows the system prompt, and only an
/// explicit policy signal proves denial. Unanswered or ordinary waiting stays `.requested`,
/// never `.denied`. Each app keeps its existing probe shape as a `Probe` value; this owner
/// supplies the lifetime: a replacement stops its predecessor, and retired callbacks are inert.
@MainActor public final class LocalNetworkPrivacy {
    /// The existing probe of one app. No product knowledge lives here.
    public struct Probe: Sendable {
        /// A self-published service that only this app browses, so a result proves multicast.
        public struct Beacon: Sendable {
            public var name: String
            public var port: Int32
            public init(name: String, port: Int32) { self.name = name; self.port = port }
        }
        /// Bonjour type observed for policy denial (and, with `resultsGrant`, for approval).
        public var browseType: String
        public var includePeerToPeer: Bool
        /// A nonempty browse result counts as approval only for a dedicated self-beacon type.
        public var resultsGrant: Bool
        public var beacon: Beacon?
        /// A legacy browse that some OS versions need before the prompt appears.
        public var promptTrigger: String?
        /// Nil keeps observing until approval or `stop()`; a denial alone never ends the probe,
        /// because Network.framework retries a waiting browse after a Settings change.
        public var lifetime: Duration?
        public init(browseType: String, includePeerToPeer: Bool = true, resultsGrant: Bool = false,
            beacon: Beacon? = nil, promptTrigger: String? = nil, lifetime: Duration? = nil) {
            self.browseType = browseType
            self.includePeerToPeer = includePeerToPeer
            self.resultsGrant = resultsGrant
            self.beacon = beacon
            self.promptTrigger = promptTrigger
            self.lifetime = lifetime
        }
    }

    enum Signal: Equatable { case policyDenied, results }
    struct Native: Sendable {
        /// Starts the native probe and returns its explicit teardown.
        var start: @MainActor (Probe, @escaping @MainActor (Signal) -> Void) -> @MainActor () -> Void
        var sleep: @MainActor (Duration) async throws -> Void
    }
    private final class Running {
        let probe: Probe
        var stop: (@MainActor () -> Void)?
        var lifetime: Task<Void, Never>?
        init(_ probe: Probe) { self.probe = probe }
    }

    public private(set) var state: CameraNetworkPermissionState = .unknown
    private let native: Native
    private let onChange: @MainActor (CameraNetworkPermissionState, String) -> Void
    private var running: Running?

    init(native: Native, onChange: @escaping @MainActor (CameraNetworkPermissionState, String) -> Void) {
        self.native = native
        self.onChange = onChange
    }

    public var isProbing: Bool { running != nil }

    /// Starts (or restarts) the app's existing probe. A known approval is kept and not re-probed;
    /// a remembered denial is re-learned because Settings may have changed.
    public func start(_ probe: Probe) {
        guard state != .allowed else { return }
        stop()
        let run = Running(probe)
        running = run
        publish(.requested, source: "probe started")
        run.stop = native.start(probe) { [weak self, weak run] signal in
            guard let self, let run, self.running === run else { return }
            self.receive(signal, from: run)
        }
        if let lifetime = probe.lifetime {
            run.lifetime = Task { [weak self, weak run, native] in
                do { try await native.sleep(lifetime) } catch { return }
                guard let self, let run, self.running === run else { return }
                self.stop()
            }
        }
    }

    /// Raises the system prompt before the first camera join, so the operator answers it while
    /// approving on the camera instead of while the camera link is already timing out (hardware
    /// pass 5.1 and 8.0). `serviceType` is the app's own Bonjour type, listed in Info.plist
    /// `NSBonjourServices`. The legacy browse raises the prompt on device; an `NWBrowser` alone
    /// did not. The prompt outlives the 30 s probe, and the camera link re-detects the answer. A
    /// running probe is not restarted and a known approval is not probed again.
    public func requestBeforeCameraJoin(serviceType: String) {
        guard !isProbing else { return }
        start(.init(browseType: serviceType, includePeerToPeer: false,
            promptTrigger: serviceType + ".", lifetime: .seconds(30)))
    }

    /// Ends the current probe and its native browse/beacon. Keeps the last evidence.
    public func stop() {
        guard let run = running else { return }
        running = nil
        run.lifetime?.cancel()
        let teardown = run.stop
        run.stop = nil
        teardown?()
    }

    /// Evidence from an actual camera operation whose own source guard already rejected
    /// retired attempts. Waiting is neither approval nor denial.
    public func note(_ evidence: CameraNetworkPermissionEvidence, source: String) {
        switch evidence {
        case .waiting: return
        case .operationSucceeded: publish(.allowed, source: source)
        case .policyDenied: publish(.denied, source: source)
        }
    }

    private func receive(_ signal: Signal, from run: Running) {
        switch signal {
        case .policyDenied:
            publish(.denied, source: "probe policy denied")
        case .results:
            guard run.probe.resultsGrant else { return }
            publish(.allowed, source: "probe found its beacon")
            stop()
        }
    }

    private func publish(_ next: CameraNetworkPermissionState, source: String) {
        guard next != state else { return }
        state = next
        onChange(next, source)
    }
}

#if os(iOS)
import Network

extension LocalNetworkPrivacy {
    /// Construct once per app host and keep it for that host's lifetime.
    public convenience init(
        onChange: @escaping @MainActor (CameraNetworkPermissionState, String) -> Void = { _, _ in }
    ) {
        self.init(native: .init(start: { probe, signal in
            let prompt = probe.promptTrigger.map { type in
                let browser = NetServiceBrowser()
                browser.searchForServices(ofType: type, inDomain: "local.")
                return browser
            }
            let beacon = probe.beacon.map { value in
                let service = NetService(domain: "local.", type: probe.browseType + ".",
                    name: value.name, port: value.port)
                service.publish()
                return service
            }
            let parameters = NWParameters()
            parameters.includePeerToPeer = probe.includePeerToPeer
            let detector = NWBrowser(for: .bonjour(type: probe.browseType, domain: nil), using: parameters)
            detector.stateUpdateHandler = { state in
                guard case .waiting(let error) = state else { return }
                let dnsCode: Int32?
                if case .dns(let code) = error { dnsCode = code } else { dnsCode = nil }
                guard CameraNetworkPermissionPolicy.isLocalNetworkDenied(dnsErrorCode: dnsCode, pathDenied: false)
                else { return }
                MainActor.assumeIsolated { signal(.policyDenied) }
            }
            detector.browseResultsChangedHandler = { results, _ in
                guard !results.isEmpty else { return }
                MainActor.assumeIsolated { signal(.results) }
            }
            detector.start(queue: .main)
            return {
                detector.stateUpdateHandler = nil
                detector.browseResultsChangedHandler = nil
                detector.cancel()
                beacon?.stop()
                prompt?.stop()
            }
        }, sleep: { try await Task.sleep(for: $0) }), onChange: onChange)
    }
}
#endif
#endif
