package com.opencapture.opencine.media

import java.util.LinkedHashMap

/**
 * Bounded, least recently used cubes baked by an app's Swift core, keyed by everything the bake
 * read (source, exposure, colour mode, ISO). Baking is slow and the payloads are large, so a
 * process keeps one cache per renderer family. A bake that fails is not remembered.
 */
class MonitorLUTCubeCache(private val maxEntries: Int = DEFAULT_ENTRIES) {
    private val cubes =
        object : LinkedHashMap<String, MonitorLUTCube>(maxEntries, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, MonitorLUTCube>?): Boolean =
                size > maxEntries
        }

    fun value(key: String, bake: () -> MonitorLUTCube?): MonitorLUTCube? =
        synchronized(cubes) {
            cubes[key] ?: bake()?.also { cubes[key] = it }
        }

    companion object {
        const val DEFAULT_ENTRIES = 8
    }
}
