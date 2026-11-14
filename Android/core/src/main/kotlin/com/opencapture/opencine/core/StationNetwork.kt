package com.opencapture.opencine.core

/**
 * A shared network cameras and this phone meet on: a router or venue Wi-Fi, or this phone's
 * hotspot. The station-network wizard offers, prefills and joins it; the Multiview seams
 * ([StationCommissioner], [StationHostPath]) carry it. Swift twin: `StationNetwork` in
 * `OpenCineCore`.
 */
public data class StationNetwork(public val ssid: String, public val password: String, public val hotspot: Boolean)
