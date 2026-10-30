package com.opencapture.opencine.dji

import android.content.Context
import com.opencapture.opencine.platform.SharedNetworkStore

/**
 * Saved shared networks. iOS `MultiviewNetworkStore`: the generic [SharedNetworkStore] under
 * OpenPocketCine's preferences and key alias (unchanged, so saved networks keep working).
 */
class MultiviewNetworkStore(context: Context) {
    data class Network(val ssid: String, val password: String, val hotspot: Boolean)

    private val store = SharedNetworkStore(context, PREFS, ALIAS)

    fun savedNetworks(): List<Network> = store.savedNetworks().map { Network(it.ssid, it.password, it.hotspot) }

    fun load(ssid: String, hotspot: Boolean): Network? =
        store.load(ssid, hotspot)?.let { Network(it.ssid, it.password, it.hotspot) }

    fun save(ssid: String, password: String, hotspot: Boolean) = store.save(ssid, password, hotspot)

    private companion object {
        const val PREFS = "openpocketcine.multiview-network"
        const val ALIAS = "openpocketcine.multiview-network"
    }
}
