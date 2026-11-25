#if os(iOS)
    import CoreLocation
    import Foundation
    import NetworkExtension
    import os

    /// iOS (and a Mac Catalyst app) names the current Wi-Fi only with precise location permission
    /// (and the Access WiFi Information entitlement). Asked in context, from Add setup › Wi-Fi
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

    /// A Mac's own Wi-Fi, read through CoreWLAN. A Mac Catalyst app cannot hold the Wi-Fi info
    /// entitlement, so `NEHotspotNetwork` never names its network; CoreWLAN does, with Location
    /// allowed. The framework is loaded at run time and every selector is checked before it is
    /// called, so a missing class or method gives nil, never a crash. Every call runs off the main
    /// thread (a scan takes seconds) and gives up after its timeout. Nil and empty everywhere
    /// but Mac Catalyst.
    public enum ComputerWiFi {
        /// The Wi-Fi this Mac is on; nil off Wi-Fi, without Location, or after `timeout`. Asks for
        /// Location first, as `StationWiFiNameAccess` does everywhere else.
        @MainActor public static func currentNetwork(timeout: Duration = .seconds(3)) async -> String? {
            #if targetEnvironment(macCatalyst)
                await StationWiFiNameAccess.shared.request()
                return await offMain(timeout: timeout, fallback: nil) { CoreWLAN.currentSSID() }
            #else
                return nil
            #endif
        }

        /// The names of the networks this Mac sees, as CoreWLAN reports them (unsorted, possibly
        /// repeated or blank; `StationNetworkRows` cleans them). Empty without Location or after
        /// `timeout`.
        @MainActor public static func nearbyNetworks(timeout: Duration = .seconds(12)) async -> [String] {
            #if targetEnvironment(macCatalyst)
                await StationWiFiNameAccess.shared.request()
                return await offMain(timeout: timeout, fallback: []) { CoreWLAN.nearbySSIDs() }
            #else
                return []
            #endif
        }

        #if targetEnvironment(macCatalyst)
            /// Runs `read` on a background queue and returns its answer, or `fallback` once
            /// `timeout` passes or the caller is cancelled. A late answer is dropped.
            private static func offMain<Value: Sendable>(
                timeout: Duration, fallback: Value, _ read: @escaping @Sendable () -> Value
            ) async -> Value {
                let once = OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>(initialState: nil)
                let finish: @Sendable (Value) -> Void = { value in
                    once.withLock { pending -> CheckedContinuation<Value, Never>? in
                        defer { pending = nil }
                        return pending
                    }?.resume(returning: value)
                }
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                        once.withLock { $0 = continuation }
                        guard !Task.isCancelled else { return finish(fallback) }
                        DispatchQueue.global(qos: .userInitiated).async { finish(read()) }
                        let nanoseconds = timeout.components.seconds * 1_000_000_000
                            + timeout.components.attoseconds / 1_000_000_000
                        DispatchQueue.global().asyncAfter(
                            deadline: .now() + .nanoseconds(Int(nanoseconds))
                        ) { finish(fallback) }
                    }
                } onCancel: {
                    finish(fallback)
                }
            }

            /// CoreWLAN by name: `CWWiFiClient.sharedWiFiClient.interface`, its `ssid` and
            /// `scanForNetworksWithName:error:`.
            private enum CoreWLAN {
                static func currentSSID() -> String? {
                    guard let interface = interface() else { return nil }
                    return string(interface, "ssid")
                }

                static func nearbySSIDs() -> [String] {
                    let scan = NSSelectorFromString("scanForNetworksWithName:error:")
                    guard let interface = interface(), interface.responds(to: scan),
                        let networks = interface.perform(scan, with: nil, with: nil)?
                            .takeUnretainedValue() as? NSSet
                    else { return [] }
                    return networks.allObjects.compactMap { ($0 as? NSObject).flatMap { string($0, "ssid") } }
                }

                private static func interface() -> NSObject? {
                    guard Bundle(path: "/System/Library/Frameworks/CoreWLAN.framework")?.load() == true,
                        let client = NSClassFromString("CWWiFiClient") as? NSObject.Type
                    else { return nil }
                    let sharedClient = NSSelectorFromString("sharedWiFiClient")
                    guard client.responds(to: sharedClient),
                        let shared = client.perform(sharedClient)?.takeUnretainedValue() as? NSObject
                    else { return nil }
                    return object(shared, "interface")
                }

                private static func object(_ target: NSObject, _ name: String) -> NSObject? {
                    let selector = NSSelectorFromString(name)
                    guard target.responds(to: selector) else { return nil }
                    return target.perform(selector)?.takeUnretainedValue() as? NSObject
                }

                private static func string(_ target: NSObject, _ name: String) -> String? {
                    (object(target, name) as? NSString).map { $0 as String }
                }
            }
        #endif
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

    /// What iOS says about a Wi-Fi network's security. Only this phone's current network is known.
    public enum StationNetworkSecurity {
        /// Whether `ssid` is secured, when it is this phone's current Wi-Fi; nil otherwise or when
        /// iOS withholds the network (no location permission, the simulator).
        @MainActor
        public static func currentNetwork(named ssid: String) async -> Bool? {
            #if targetEnvironment(simulator)
                return nil
            #else
                guard let network = await NEHotspotNetwork.fetchCurrent(), network.ssid == ssid
                else { return nil }
                return network.isSecure
            #endif
        }
    }
#endif
