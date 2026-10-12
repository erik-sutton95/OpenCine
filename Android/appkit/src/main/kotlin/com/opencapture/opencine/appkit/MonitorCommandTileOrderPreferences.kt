package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import com.opencapture.monitorui.monitorCommandTileOrder

/**
 * The command dashboard tile order, stored as comma-joined enum names under the app's [key] in
 * its own [storage]. Reads and writes are normalized over [all]: unknown names drop out and
 * tiles added later join at the end.
 */
public class MonitorCommandTileOrderPreferences<K : Enum<K>>(
    private val storage: SharedPreferences,
    private val key: String,
    private val all: List<K>,
) {
    init { require(key.isNotEmpty()) }

    public fun load(): List<K> =
        monitorCommandTileOrder(
            storage.getString(key, null)?.split(',')?.mapNotNull { name -> all.firstOrNull { it.name == name } }.orEmpty(),
            all,
        )

    public fun save(order: List<K>) {
        storage.edit().putString(key, monitorCommandTileOrder(order, all).joinToString(",") { it.name }).apply()
    }
}
