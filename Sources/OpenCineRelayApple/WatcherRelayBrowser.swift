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
        @ObservationIgnored private let browser: RelayAppleBrowser

        public init() {
            browser = RelayAppleBrowser(profile: .sharedMonitor, order: .name)
            browser.onResults = { [weak self] rows in
                self?.hosts = rows.filter(\.isWatchable).map {
                    WatcherRelayDiscovery(
                        id: $0.id, name: $0.name,
                        cameraName: $0.servedCameraHost ?? "", endpoint: $0.endpoint)
                }
            }
            browser.onError = { [weak self] error in
                self?.browseError =
                    error == nil
                    ? nil
                    : "Could not find shared feeds. Check Local Network permission and camera Wi-Fi, then tap Find shared feeds."
            }
        }

        public func start() {
            stop()
            browser.start()
        }

        public func stop() {
            browser.stop()
            hosts = []
            browseError = nil
        }
    }
#endif
