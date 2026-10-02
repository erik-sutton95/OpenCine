package com.opencapture.opencine.platform

import android.content.Context

/** Names belong to the app's installed data contract, never to this module. */
data class CameraWifiStorageConfiguration(
    val preferencesName: String,
    val keyAlias: String,
    val ssidKeySuffix: String,
    val passwordKeySuffix: String,
    val ssidIndexPrefix: String,
)

/** A camera's device-only Wi-Fi credentials; saved-camera metadata contains no password. */
class CameraWifiCredentialStore internal constructor(
    private val configuration: CameraWifiStorageConfiguration,
    private val preferences: CredentialPreferences,
    private val seal: (String) -> String?,
    private val open: (String) -> String?,
) {
    constructor(context: Context, configuration: CameraWifiStorageConfiguration) : this(
        configuration,
        AndroidCredentialPreferences(context, configuration.preferencesName),
        KeystoreSeal(configuration.keyAlias)::seal,
        KeystoreSeal(configuration.keyAlias)::open,
    )

    fun load(cameraId: String): Pair<String, String>? {
        val ssid = preferences.get(ssidKey(cameraId)) ?: return null
        val stored = preferences.get(passwordKey(cameraId)) ?: return null
        if (ssid.isEmpty() || stored.isEmpty()) return null
        val password = decryptOrMigrate(cameraId, stored) ?: return null
        if (password.isEmpty()) return null
        return ssid to password
    }

    fun passphrase(ssid: String): String? = preferences.get(ssidEntry(ssid))?.let(open)

    fun save(cameraId: String, ssid: String, password: String) {
        val sealed = seal(password) ?: return
        preferences.write(mapOf(ssidKey(cameraId) to ssid, passwordKey(cameraId) to sealed, ssidEntry(ssid) to sealed))
    }

    fun remove(cameraId: String) {
        val ssid = preferences.get(ssidKey(cameraId))
        val keys = mutableSetOf(ssidKey(cameraId), passwordKey(cameraId))
        if (!ssid.isNullOrEmpty()) keys += ssidEntry(ssid)
        preferences.write(emptyMap(), keys)
    }

    private fun decryptOrMigrate(cameraId: String, stored: String): String? {
        open(stored)?.let { return it }
        if (KeystoreSeal.SEPARATOR !in stored) {
            save(cameraId, preferences.get(ssidKey(cameraId), "") ?: return null, stored)
            return stored
        }
        return null
    }

    private fun ssidKey(cameraId: String): String = cameraId + configuration.ssidKeySuffix
    private fun passwordKey(cameraId: String): String = cameraId + configuration.passwordKeySuffix
    private fun ssidEntry(ssid: String): String = configuration.ssidIndexPrefix + ssid.trim()
}

/** Internal seam for the Android preference transaction and deterministic preservation tests. */
internal interface CredentialPreferences {
    fun get(key: String, default: String? = null): String?
    fun write(values: Map<String, String>, removing: Set<String> = emptySet())
}

private class AndroidCredentialPreferences(context: Context, name: String) : CredentialPreferences {
    private val preferences = context.applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)
    override fun get(key: String, default: String?): String? = preferences.getString(key, default)
    override fun write(values: Map<String, String>, removing: Set<String>) {
        val editor = preferences.edit()
        for (key in removing) editor.remove(key)
        for ((key, value) in values) editor.putString(key, value)
        editor.apply()
    }
}
