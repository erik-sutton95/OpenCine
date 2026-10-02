package com.opencapture.opencine.dji

import android.content.Context
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject

/**
 * Saved shared networks. iOS `MultiviewNetworkStore`: names in private prefs,
 * passwords sealed with a device-only Keystore key. Never log a password.
 */
class MultiviewNetworkStore(context: Context) {
    data class Network(val ssid: String, val password: String, val hotspot: Boolean)

    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val seal = KeystoreSeal(ALIAS)

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
        prefs.edit { putString(KEY, list.toString()) }
    }

    private fun entry(ssid: String, sealed: String, hotspot: Boolean) =
        JSONObject().put("ssid", ssid).put("password", sealed).put("hotspot", hotspot)

    private companion object {
        const val PREFS = "openpocketcine.multiview-network"
        const val ALIAS = "openpocketcine.multiview-network"
        const val KEY = "saved-networks"
    }
}
