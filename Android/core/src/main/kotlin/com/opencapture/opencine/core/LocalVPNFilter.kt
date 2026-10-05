package com.opencapture.opencine.core

/**
 * Local VPN / ad-blocker filters (AdGuard, Blokada, RethinkDNS) capture the
 * camera UDP datalink. `bindProcessToNetwork` cannot bypass a VpnService
 * that did not call `allowBypass()`. Swift `LocalVPNFilter` twin: copy and
 * live-wait policy (#239). The platform module's `LocalVPNProbe` detects the tunnel.
 */
public object LocalVPNFilter {
    public const val LIVE_HINT_DELAY_SECONDS: Double = 8.0
    public const val LIVE_HINT_DELAY_MS: Long = 8_000L

    public const val WIZARD_BANNER: String =
        "Pause VPNs and ad blockers, or exclude this app. They can block the camera live feed."

    public const val LIVE_HINT: String =
        "A VPN or ad blocker may be blocking the live feed. Pause it, or exclude this app, then try again."

    public const val JOIN_WIFI_PHONE_STEP: String = "Pause VPNs and ad blockers, or exclude this app"

    public fun shouldHintOnLiveWait(
        vpnActive: Boolean,
        hadVideo: Boolean,
        secondsWithoutVideo: Double,
    ): Boolean = vpnActive && !hadVideo && secondsWithoutVideo >= LIVE_HINT_DELAY_SECONDS
}
