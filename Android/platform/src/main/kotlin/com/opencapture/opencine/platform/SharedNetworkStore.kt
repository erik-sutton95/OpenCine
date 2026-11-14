package com.opencapture.opencine.platform

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Saved shared networks (a router's Wi-Fi or this phone's hotspot) for the station-network setup:
 * names in the caller's private preferences, passwords sealed with a device-only Keystore key under
 * the caller's alias. Never logs a password. The preferences name and alias are app values.
 */
class SharedNetworkStore internal constructor(private val storage: Storage, private val seal: KeystoreSeal) {
    constructor(context: Context, preferences: String, alias: String) : this(
        PreferencesStorage(context.applicationContext.getSharedPreferences(preferences, Context.MODE_PRIVATE)),
        KeystoreSeal(alias),
    )

    /** A saved network. Swift twin: `SharedNetworkStore.Network`. */
    data class Network(val ssid: String, val password: String, val hotspot: Boolean) {
        override fun toString(): String = "Network($ssid, hotspot: $hotspot, password: <redacted>)"
    }

    /** Where the list lives: one JSON array of entries with sealed passwords. */
    internal interface Storage {
        fun read(): String?
        fun write(value: String)
    }

    private class PreferencesStorage(private val prefs: android.content.SharedPreferences) : Storage {
        override fun read(): String? = prefs.getString(KEY, null)
        override fun write(value: String) {
            prefs.edit().putString(KEY, value).apply()
        }
    }

    /** Oldest first. */
    fun savedNetworks(): List<Network> {
        val raw = storage.read() ?: return emptyList()
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
        storage.write(list.toString())
    }

    private fun entry(ssid: String, sealed: String, hotspot: Boolean) =
        JSONObject().put("ssid", ssid).put("password", sealed).put("hotspot", hotspot)

    private companion object {
        const val KEY = "saved-networks"
    }
}
