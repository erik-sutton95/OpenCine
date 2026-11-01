package com.opencapture.opencine.platform

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Saved shared networks (a router's Wi-Fi or this phone's hotspot) for the station-network setup:
 * names in the caller's private preferences, passwords sealed with a device-only Keystore key under
 * the caller's alias. Never logs a password. The preferences name and alias are app values.
 */
class SharedNetworkStore(context: Context, preferences: String, alias: String) {
    data class Network(val ssid: String, val password: String, val hotspot: Boolean) {
        override fun toString(): String = "Network($ssid, hotspot: $hotspot, password: <redacted>)"
    }

    private val prefs = context.applicationContext.getSharedPreferences(preferences, Context.MODE_PRIVATE)
    private val seal = KeystoreSeal(alias)

    /** Oldest first. */
    fun savedNetworks(): List<Network> {
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        val list = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        return (0 until list.length()).mapNotNull { index ->
            val item = list.optJSONObject(index) ?: return@mapNotNull null
            val ssid = item.optString("ssid")
            val password = item.optString("password").takeIf { it.isNotEmpty() }?.let(seal::open) ?: ""
            if (ssid.isEmpty()) null else Network(ssid, password, item.optBoolean("hotspot"))
        }
    }

    fun load(ssid: String, hotspot: Boolean): Network? =
        savedNetworks().firstOrNull { it.ssid == ssid && it.hotspot == hotspot }

    fun save(ssid: String, password: String, hotspot: Boolean) {
        val sealed = if (password.isEmpty()) "" else seal.seal(password) ?: return
        val others = savedNetworks().filterNot { it.ssid == ssid && it.hotspot == hotspot }
        val list = JSONArray()
        for (network in others) {
            list.put(entry(network.ssid, network.password.let { if (it.isEmpty()) "" else seal.seal(it) ?: "" }, network.hotspot))
        }
        list.put(entry(ssid, sealed, hotspot))
        prefs.edit().putString(KEY, list.toString()).apply()
    }

    private fun entry(ssid: String, sealed: String, hotspot: Boolean) =
        JSONObject().put("ssid", ssid).put("password", sealed).put("hotspot", hotspot)

    private companion object {
        const val KEY = "saved-networks"
    }
}
