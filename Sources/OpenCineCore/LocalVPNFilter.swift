import Foundation

/// Local VPN / ad-blocker filters (AdGuard, Blokada, RethinkDNS) capture the
/// camera UDP datalink. `bindProcessToNetwork` cannot bypass a `VpnService`
/// that did not call `allowBypass()`. Official camera apps have the same limit
/// (#239). Shells detect the tunnel; this type owns copy and when to hint.
public enum LocalVPNFilter: Sendable {
    /// First picture can take a few seconds (enable at +3 s; a body's format
    /// poke can come later). Hint only after the well has sat black this long.
    public static let liveHintDelaySeconds: TimeInterval = 8

    /// Connection-setup banner when a local VPN is already on.
    public static let wizardBanner =
        "Pause VPNs and ad blockers, or exclude this app. They can block the camera live feed."

    /// WAITING FOR LIVE VIEW subtitle after [liveHintDelaySeconds] with no picture.
    public static let liveHint =
        "A VPN or ad blocker may be blocking the live feed. Pause it, or exclude this app, then try again."

    /// Join-Wi-Fi phone instruction. Same voice as the other wizard bullets.
    public static let joinWifiPhoneStep =
        "Pause VPNs and ad blockers, or exclude this app"

    public static func shouldHintOnLiveWait(
        vpnActive: Bool,
        hadVideo: Bool,
        secondsWithoutVideo: TimeInterval
    ) -> Bool {
        vpnActive && !hadVideo && secondsWithoutVideo >= liveHintDelaySeconds
    }

    /// CFNetwork `__SCOPED__` / ifaddrs names that mean a tunnel. `utun` is
    /// also used by iCloud Private Relay, so shells should not warn on name
    /// alone before the live well has stalled.
    public static func isTunnelInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("tap") || lower.contains("tun") || lower.contains("ppp")
            || lower.contains("ipsec")
    }
}

#if os(iOS) || os(macOS)
    /// Best-effort local-VPN probe for the Apple shells. Android uses `TRANSPORT_VPN`, which is
    /// authoritative. CFNetwork `__SCOPED__` tunnel names also fire for iCloud Private Relay
    /// (`utun`), so the wizard only shows ``LocalVPNFilter/wizardBanner`` when a tunnel is present,
    /// and the live-well hint still waits ``LocalVPNFilter/liveHintDelaySeconds``.
    public enum LocalVPNProbe {
        public static func isActive() -> Bool {
            scopedInterfaceNames().contains { LocalVPNFilter.isTunnelInterface($0) }
        }

        public static func scopedInterfaceNames() -> [String] {
            guard
                let cf = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
                let scoped = cf["__SCOPED__"] as? [String: Any]
            else { return [] }
            return Array(scoped.keys)
        }
    }

    /// Notes an active local VPN once per instance (each app holds one): the line goes to the
    /// app's diagnostics through `note`.
    public final class LocalVPNNotice: @unchecked Sendable {
        public static let message = "vpn: local VPN or ad blocker active \u{2014} can drop UDP live view"

        private let isActive: @Sendable () -> Bool
        private let note: @Sendable (String) -> Void
        private let lock = NSLock()
        private var logged = false

        public init(
            isActive: @escaping @Sendable () -> Bool = { LocalVPNProbe.isActive() },
            note: @escaping @Sendable (String) -> Void
        ) {
            self.isActive = isActive
            self.note = note
        }

        public func noteIfActive() {
            guard isActive() else { return }
            let first = lock.withLock {
                defer { logged = true }
                return !logged
            }
            if first { note(Self.message) }
        }
    }
#endif
