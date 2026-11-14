package com.opencapture.opencine.core

/**
 * The phone's side of a shared station network: its IPv4 address and netmask there, and joining
 * it. A platform adapter implements it (Android `SharedWiFiPath` in `:platform`, iOS
 * `SharedWiFiPath` in `OpenCineApple`); the Multiview coordinator and the integrations' station
 * setups use it so neither reads network interfaces itself. Swift twin: `StationHostPath`.
 */
public interface StationHostPath {
    /** This phone's IPv4 address on Wi-Fi ([hotspot] false) or on the hotspot it hosts; null when it is not on that network. */
    public fun address(hotspot: Boolean): String?

    /** The netmask of the same interface; null when it is not on that network. */
    public fun netmask(hotspot: Boolean): String?

    /**
     * A router's Wi-Fi: joins it and returns this phone's address there, null when the phone did
     * not join. A hotspot is this phone's own: nothing is joined, and its current hotspot address
     * is returned (null until a client associates).
     */
    public suspend fun join(network: StationNetwork): String?
}
