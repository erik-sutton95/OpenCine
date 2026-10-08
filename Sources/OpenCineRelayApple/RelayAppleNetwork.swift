#if canImport(Network)
    import Network
    import OpenCineRelay

    /// Socket facts are explicit deployment values. No application/manufacturer selects them.
    public enum RelayAppleNetwork {
        public static func parameters(_ policy: RelayNetworkPolicy) -> NWParameters {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = policy.includePeerToPeer
            if policy.prohibitsCellular { parameters.prohibitedInterfaceTypes = [.cellular] }
            parameters.serviceClass = .interactiveVideo
            if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
            {
                tcp.noDelay = true
                tcp.enableKeepalive = true
                tcp.keepaliveIdle = policy.keepaliveIdle
                tcp.keepaliveInterval = policy.keepaliveInterval
                tcp.keepaliveCount = policy.keepaliveCount
            }
            return parameters
        }
        public static func rediscoveryEndpoint(_ endpoint: NWEndpoint) -> NWEndpoint {
            if case .service(let name, let type, let domain, _) = endpoint {
                return .service(name: name, type: type, domain: domain, interface: nil)
            }
            return endpoint
        }
    }
#endif
