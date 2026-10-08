#if canImport(Network)
    import Network
    import OpenCineRelay

    /// Shared-network transport only. Peer-to-peer radio scheduling interrupts the camera feed.
    /// All discovery, listeners, and watcher connections use this one configuration.
    public enum WatcherRelayNetwork {
        /// Do not retain a vanished interface when retrying a Bonjour service after a Wi-Fi change.
        public static func rediscoveryEndpoint(_ endpoint: NWEndpoint) -> NWEndpoint {
            RelayAppleNetwork.rediscoveryEndpoint(endpoint)
        }

        public static func parameters() -> NWParameters {
            RelayAppleNetwork.parameters(RelayNetworkPolicy())
        }
    }
#endif
