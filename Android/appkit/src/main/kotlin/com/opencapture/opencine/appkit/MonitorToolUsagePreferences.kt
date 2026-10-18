package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import com.opencapture.monitorui.MonitorToolUsageState
import org.json.JSONObject

/** The existing assist-usage JSON schema, with storage and key supplied by the app. */
public class MonitorToolUsagePreferences(
    private val storage: SharedPreferences,
    private val key: String,
) {
    init { require(key.isNotEmpty()) }

    public var value: MonitorToolUsageState
        get() {
            val raw = storage.getString(key, null) ?: return MonitorToolUsageState()
            return try {
                decodeMonitorToolUsage(JSONObject(raw))
            } catch (_: Exception) {
                MonitorToolUsageState()
            }
        }
        set(value) {
            val obj = encodeMonitorToolUsage(value)
            storage.edit().putString(key, obj.toString()).apply()
        }
}

internal fun decodeMonitorToolUsage(obj: JSONObject): MonitorToolUsageState {
    fun doubles(name: String): Map<String, Double> {
        if (!obj.has(name)) return emptyMap()
        val child = obj.getJSONObject(name)
        return child.keys().asSequence().associateWith { child.getDouble(it) }
    }
    fun ints(name: String): Map<String, Int> {
        if (!obj.has(name)) return emptyMap()
        val child = obj.getJSONObject(name)
        return child.keys().asSequence().associateWith { child.getInt(it) }
    }
    return MonitorToolUsageState(
        doubles("scores"), ints("counts"), doubles("lastUsed"), obj.optDouble("clock", 0.0),
    )
}

internal fun encodeMonitorToolUsage(value: MonitorToolUsageState): JSONObject {
    val scores = JSONObject()
    value.scores.forEach { scores.put(it.key, it.value) }
    val counts = JSONObject()
    value.counts.forEach { counts.put(it.key, it.value) }
    val lastUsed = JSONObject()
    value.lastUsed.forEach { lastUsed.put(it.key, it.value) }
    return JSONObject()
        .put("scores", scores)
        .put("counts", counts)
        .put("lastUsed", lastUsed)
        .put("clock", value.clock)
}
