#if os(iOS)
    import CoreLocation
    import NetworkExtension

    /// iOS names the current Wi-Fi to an app only with precise location permission (and the
    /// Access WiFi Information entitlement). Asked in context, from Add setup › Wi-Fi
    /// or Multiview, never at launch. Location itself is never read.
    @MainActor public final class StationWiFiNameAccess: NSObject, CLLocationManagerDelegate {
        public static let shared = StationWiFiNameAccess()
        private let manager = CLLocationManager()
        private var waiters: [CheckedContinuation<Void, Never>] = []

        override private init() {
            super.init()
            manager.delegate = self
        }

        public var undecided: Bool { manager.authorizationStatus == .notDetermined }
        public var denied: Bool {
            manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
        }
        /// Allowed, but Precise Location is off: iOS still withholds the Wi-Fi name.
        public var approximateOnly: Bool {
            !undecided && !denied && manager.accuracyAuthorization == .reducedAccuracy
        }

        /// Returns once the operator has answered, or at once if they already did.
        public func request() async {
            guard undecided else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }

        public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            Task { @MainActor in
                guard !self.undecided else { return }
                let waiting = self.waiters
                self.waiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }
        }
    }

    /// The Wi-Fi networks this app configured before. iOS keeps other saved networks private.
    public enum StationConfiguredNetworks {
        @MainActor public static func ssids() async -> [String] {
            await withCheckedContinuation { continuation in
                NEHotspotConfigurationManager.shared.getConfiguredSSIDs {
                    continuation.resume(returning: $0)
                }
            }
        }
    }
#endif
