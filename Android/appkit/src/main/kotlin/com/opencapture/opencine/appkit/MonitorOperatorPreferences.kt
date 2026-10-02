package com.opencapture.opencine.appkit

import android.content.SharedPreferences

/** Common choices in one app-supplied preferences file, preserving legacy keys and defaults. */
public class MonitorOperatorPreferences(
    private val storage: SharedPreferences,
    private val keys: Keys,
    private val defaults: Defaults = Defaults(),
) {
    public data class Keys(
        public val keepScreenAwake: String,
        public val hdrDisplay: String,
        public val recordConfirmation: String,
        public val haptics: String,
        public val cacheOriginals: String,
        public val legacyKeepScreenAwake: String? = null,
    ) {
        init {
            val names = listOf(keepScreenAwake, hdrDisplay, recordConfirmation, haptics, cacheOriginals)
            require(names.all { it.isNotEmpty() } && names.toSet().size == names.size)
        }
    }

    public data class Defaults(
        public val keepScreenAwake: Boolean = true,
        public val hdrDisplay: Boolean = false,
        public val recordConfirmation: Boolean = true,
        public val haptics: Boolean = true,
        public val cacheOriginals: Boolean = true,
    )

    public var keepScreenAwake: Boolean
        get() {
            if (storage.contains(keys.keepScreenAwake)) {
                return storage.getBoolean(keys.keepScreenAwake, defaults.keepScreenAwake)
            }
            val legacy = keys.legacyKeepScreenAwake
            return if (legacy != null && storage.contains(legacy)) {
                storage.getBoolean(legacy, defaults.keepScreenAwake)
            } else defaults.keepScreenAwake
        }
        set(value) { write(keys.keepScreenAwake, value) }
    public var hdrDisplay: Boolean
        get() = storage.getBoolean(keys.hdrDisplay, defaults.hdrDisplay)
        set(value) { write(keys.hdrDisplay, value) }
    public var recordConfirmation: Boolean
        get() = storage.getBoolean(keys.recordConfirmation, defaults.recordConfirmation)
        set(value) { write(keys.recordConfirmation, value) }
    public var haptics: Boolean
        get() = storage.getBoolean(keys.haptics, defaults.haptics)
        set(value) { write(keys.haptics, value) }
    public var cacheOriginals: Boolean
        get() = storage.getBoolean(keys.cacheOriginals, defaults.cacheOriginals)
        set(value) { write(keys.cacheOriginals, value) }

    private fun write(key: String, value: Boolean) {
        storage.edit().putBoolean(key, value).apply()
    }
}
