package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import org.json.JSONObject

/** The legacy clip path to shot color map, with storage and key supplied by the app. */
public class MonitorClipShotColorPreferences(
    private val storage: SharedPreferences,
    private val key: String,
) {
    init { require(key.isNotEmpty()) }

    public fun color(path: String): Int {
        val raw = storage.getString(key, null) ?: return -1
        return try {
            JSONObject(raw).optInt(path, -1)
        } catch (_: Exception) {
            -1
        }
    }

    public fun setColor(path: String, value: Int) {
        if (value < 0) return
        val json =
            try {
                JSONObject(storage.getString(key, null) ?: "{}")
            } catch (_: Exception) {
                JSONObject()
            }
        json.put(path, value)
        storage.edit().putString(key, json.toString()).apply()
    }

    public val legacyJson: JSONObject?
        get() {
            val raw = storage.getString(key, null) ?: return null
            return try {
                JSONObject(raw)
            } catch (_: Exception) {
                null
            }
        }

    public fun clear() {
        storage.edit().remove(key).apply()
    }
}
