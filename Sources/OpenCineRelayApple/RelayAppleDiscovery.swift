#if canImport(Network)
    import Foundation
    import Network
    import OpenCineRelay

    public struct RelayAppleDiscovery: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint
        public let servedCameraHost: String?
        public let isWatchable: Bool
        public init(
            id: String, name: String, endpoint: NWEndpoint,
            servedCameraHost: String? = nil, isWatchable: Bool = true
        ) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.servedCameraHost = servedCameraHost
            self.isWatchable = isWatchable
        }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.servedCameraHost == rhs.servedCameraHost
                && lhs.isWatchable == rhs.isWatchable
        }
    }

    /// Both deployed browse recipes share one source/window owner. A plain listing is an
    /// explicit exercised network recipe; TXT enriches its rows with passive probe exclusions.
    @MainActor public final class RelayAppleBrowser {
        public private(set) var results: [RelayAppleDiscovery] = []
        public var onResults: (@MainActor ([RelayAppleDiscovery]) -> Void)?
        public var onError: (@MainActor (String?) -> Void)?
        private let profile: RelayWireProfile
        private let network: RelayNetworkPolicy
        private let usesPlainListing: Bool
        private let journal: @Sendable (String) -> Void
        private var index: RelayDiscoveryIndex<NWEndpoint>
        private var browsers: [String: NWBrowser] = [:]
        private let queue = DispatchQueue(label: "opc.relay.browser")
        public init(
            profile: RelayWireProfile, network: RelayNetworkPolicy = .init(),
            usesPlainListing: Bool = false,
            order: RelayDiscoveryIndex<NWEndpoint>.Order = .localizedCaseInsensitive,
            journal: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.profile = profile
            self.network = network
            self.usesPlainListing = usesPlainListing
            self.journal = journal
            index = RelayDiscoveryIndex(order: order)
        }
        public func start(includePeerToPeer: Bool = false) {
            stop()
            let token = index.start()
            if usesPlainListing {
                startBrowser(
                    label: "list", descriptor: .bonjour(type: profile.serviceType, domain: nil),
                    parameters: .tcp, token: token)
            }
            let facts = RelayNetworkPolicy(
                includePeerToPeer: includePeerToPeer,
                prohibitsCellular: network.prohibitsCellular, keepaliveIdle: network.keepaliveIdle,
                keepaliveInterval: network.keepaliveInterval, keepaliveCount: network.keepaliveCount
            )
            startBrowser(
                label: "txt",
                descriptor: .bonjourWithTXTRecord(type: profile.serviceType, domain: nil),
                parameters: RelayAppleNetwork.parameters(facts), token: token)
        }
        private func startBrowser(
            label: String, descriptor: NWBrowser.Descriptor,
            parameters: NWParameters, token: UUID
        ) {
            journal("relay browse[\(label)] starting")
            let browser = NWBrowser(for: descriptor, using: parameters)
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                Task { @MainActor in
                    guard let self, let browser, self.index.admits(token),
                        self.browsers[label] === browser
                    else { return }
                    switch state {
                    case .failed(let error), .waiting(let error):
                        self.journal("relay browse[\(label)] state=\(state) error=\(error)")
                        if case .failed = state {
                            self.merge([], label: label, token: token)
                            if self.index.admits(token) {
                                self.onError?(error.localizedDescription)
                            }
                        }
                    default: break
                    }
                }
            }
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                Task { @MainActor in
                    guard let self, let browser, self.index.admits(token),
                        self.browsers[label] === browser
                    else { return }
                    let values = results.compactMap { result -> RelayAppleDiscovery? in
                        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                        var servedHost: String?
                        var watchable = true
                        if case .bonjour(let txt) = result.metadata {
                            servedHost = txt[self.profile.servedCameraTXTKey]
                            watchable = txt[self.profile.watchableTXTKey] != "0"
                        }
                        return RelayAppleDiscovery(
                            id: name, name: name, endpoint: result.endpoint,
                            servedCameraHost: servedHost, isWatchable: watchable)
                    }
                    let listing = values.map {
                        "\($0.name)(ch=\($0.servedCameraHost ?? "nil")\($0.isWatchable ? "" : " beacon"))"
                    }.joined(separator: " ")
                    self.journal("relay browse[\(label)] results=\(values.count) [\(listing)]")
                    self.onError?(nil)
                    self.merge(values, label: label, token: token)
                }
            }
            browsers[label] = browser
            browser.start(queue: queue)
        }
        private func merge(_ values: [RelayAppleDiscovery], label: String, token: UUID) {
            guard
                index.replace(
                    values.map {
                        RelayDiscoveryRow(
                            id: $0.id, name: $0.name, endpoint: $0.endpoint,
                            servedCameraHost: $0.servedCameraHost, isWatchable: $0.isWatchable)
                    }, origin: label, token: token)
            else { return }
            results = index.results.map {
                RelayAppleDiscovery(
                    id: $0.id, name: $0.name, endpoint: $0.endpoint,
                    servedCameraHost: $0.servedCameraHost, isWatchable: $0.isWatchable)
            }
            onResults?(results)
        }
        public func stop() {
            index.stop()
            for browser in browsers.values { browser.cancel() }
            browsers.removeAll()
            results = []
        }
    }
#endif
