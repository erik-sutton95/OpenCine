#if canImport(Network)
    import Foundation
    import Network
    import Observation
    import OpenCineRelay

    public struct WatcherRelayDiscovery: Identifiable, Equatable {
        public var id: String
        public var name: String
        public var cameraName: String
        public var endpoint: NWEndpoint

        public init(id: String, name: String, cameraName: String, endpoint: NWEndpoint) {
            self.id = id
            self.name = name
            self.cameraName = cameraName
            self.endpoint = endpoint
        }
    }

    /// Finds sharing hosts on the same Wi-Fi. Never browses over peer-to-peer.
    @available(macOS 14, *)
    @MainActor
    @Observable
    public final class WatcherRelayBrowser {
        public var hosts: [WatcherRelayDiscovery] = []
        public var browseError: String?
        private var browser: NWBrowser?

        public init() {}

        public func start() {
            stop()
            let params = WatcherRelayNetwork.parameters()
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: WatcherRelayProtocol.serviceType, domain: nil),
                using: params)
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                Task { @MainActor in
                    guard let self, let browser, self.browser === browser else { return }
                    self.browseError = nil
                    self.hosts = results.compactMap { result in
                        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                        var camera = ""
                        if case .bonjour(let txt) = result.metadata {
                            camera = txt[WatcherRelayProtocol.txtCamera] ?? ""
                            if txt[WatcherRelayProtocol.txtWatchable] == "0" { return nil }
                        }
                        return WatcherRelayDiscovery(
                            id: name, name: name, cameraName: camera, endpoint: result.endpoint)
                    }
                    .sorted { $0.name < $1.name }
                }
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                Task { @MainActor in
                    guard let self, let browser, self.browser === browser else { return }
                    if case .failed = state {
                        self.hosts = []
                        self.browseError =
                            "Could not find shared feeds. Check Local Network permission and camera Wi-Fi, then tap Find shared feeds."
                    }
                }
            }
            self.browser = browser
            browser.start(queue: .main)
        }

        public func stop() {
            browser?.cancel()
            browser = nil
            hosts = []
            browseError = nil
        }
    }
#endif
