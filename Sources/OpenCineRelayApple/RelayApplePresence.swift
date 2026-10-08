#if canImport(Network)
    import Foundation
    import Network
    import OpenCineRelay

    /// Advertise-only passive exclusion. A distinct service name preserves saved broadcast
    /// identity while cancellation and a new real listener overlap in the platform SDK.
    @MainActor public final class RelayAppleInUseBeacon {
        private let profile: RelayWireProfile
        private let network: RelayNetworkPolicy
        private let journal: @Sendable (String) -> Void
        private var lifetime = RelayConnectionLifetime()
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "opc.relay.in-use")
        public init(
            profile: RelayWireProfile, network: RelayNetworkPolicy = .init(),
            journal: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.profile = profile
            self.network = network
            self.journal = journal
        }
        public func start(hostName: String, servedCameraHost: String) {
            stop()
            guard !servedCameraHost.isEmpty,
                let listener = try? NWListener(using: RelayAppleNetwork.parameters(network))
            else { return }
            let token = lifetime.begin()
            var txt = NWTXTRecord()
            txt[profile.servedCameraTXTKey] = servedCameraHost
            txt[profile.watchableTXTKey] = "0"
            listener.service = NWListener.Service(
                name: "\(hostName) in-use", type: profile.serviceType, txtRecord: txt)
            listener.newConnectionHandler = { connection in connection.cancel() }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.lifetime.admits(token),
                        self.listener === listener
                    else { return }
                    if case .failed(let error) = state {
                        self.journal("in-use beacon failed: \(error)")
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
            journal("in-use beacon up ch=\(servedCameraHost)")
        }
        public func stop() {
            lifetime.retire()
            listener?.cancel()
            listener = nil
        }
    }

    /// One passive TCP line responder. The app supplies its exact typed wire projection as
    /// immutable bytes; SDK admission, listener lifetime and close belong here.
    @MainActor public final class RelayApplePresenceServer {
        private let port: UInt16
        private let journal: @Sendable (String) -> Void
        private var lifetime = RelayConnectionLifetime()
        private var listener: NWListener?
        private var line: Data?
        private let queue = DispatchQueue(label: "opc.relay.presence")
        public init(port: UInt16, journal: @escaping @Sendable (String) -> Void = { _ in }) {
            self.port = port
            self.journal = journal
        }
        public func update(encodedLine: Data?) {
            line = encodedLine
            guard encodedLine != nil else {
                if listener != nil { journal("presence responder off") }
                stop()
                return
            }
            guard listener == nil else { return }
            guard let port = NWEndpoint.Port(rawValue: port),
                let listener = try? NWListener(using: .tcp, on: port)
            else {
                journal("presence server bind failed")
                return
            }
            let token = lifetime.begin()
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, let listener, self.lifetime.admits(token),
                        self.listener === listener,
                        let line = self.line
                    else {
                        connection.cancel()
                        return
                    }
                    connection.start(queue: self.queue)
                    connection.send(
                        content: line, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.lifetime.admits(token),
                        self.listener === listener
                    else { return }
                    if case .failed(let error) = state {
                        self.journal("presence server failed: \(error)")
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
        public func stop() {
            lifetime.retire()
            line = nil
            listener?.cancel()
            listener = nil
        }
    }
#endif
