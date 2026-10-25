package com.opencapture.opencine.gyro

import android.content.SharedPreferences

/**
 * In-memory [SharedPreferences] for JVM tests of the gyro preferences and coordinator. Edits
 * apply immediately; one instance shared by two coordinators models data surviving a process
 * restart.
 */
class MemorySharedPreferences : SharedPreferences {
    private val values = mutableMapOf<String, Any?>()

    /** Keys whose edits throw, to model a preferences write that fails. */
    var failingKeys: Set<String> = emptySet()

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()

    override fun getString(key: String, defValue: String?): String? =
        values[key] as? String ?: defValue

    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        values[key] as? MutableSet<String> ?: defValues

    override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue

    override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue

    override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue

    override fun getBoolean(key: String, defValue: Boolean): Boolean =
        values[key] as? Boolean ?: defValue

    override fun contains(key: String): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = Editor()

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit

    private inner class Editor : SharedPreferences.Editor {
        private val changes = mutableMapOf<String, Any?>()
        private val removals = mutableSetOf<String>()
        private var clearing = false

        override fun putString(key: String, value: String?) = apply { changes[key] = value }

        override fun putStringSet(key: String, values: MutableSet<String>?) =
            apply { changes[key] = values?.toMutableSet() }

        override fun putInt(key: String, value: Int) = apply { changes[key] = value }

        override fun putLong(key: String, value: Long) = apply { changes[key] = value }

        override fun putFloat(key: String, value: Float) = apply { changes[key] = value }

        override fun putBoolean(key: String, value: Boolean) = apply { changes[key] = value }

        override fun remove(key: String) = apply { removals += key }

        override fun clear() = apply { clearing = true }

        override fun commit(): Boolean {
            val failing = (changes.keys + removals).intersect(failingKeys)
            check(failing.isEmpty()) { "Preferences write failed: $failing" }
            if (clearing) values.clear()
            removals.forEach { values.remove(it) }
            changes.forEach { (key, value) ->
                if (value == null) values.remove(key) else values[key] = value
            }
            return true
        }

        override fun apply() {
            commit()
        }
    }
}
