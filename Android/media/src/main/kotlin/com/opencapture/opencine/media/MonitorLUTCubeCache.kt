package com.opencapture.opencine.media

import java.util.LinkedHashMap

/**
 * One owner's bounded LRU of immutable Swift-baked cubes. Close retires cache admission;
 * returned plans retain their own payloads until their existing native owner retires them.
 */
class MonitorLUTCubeCache(private val maxEntries: Int = DEFAULT_ENTRIES) : AutoCloseable {
    init { require(maxEntries >= 0) }

    private val stateLock = Any()
    private val bakeLock = Any()
    private var closed = false
    private val cubes = LinkedHashMap<String, MonitorLUTCube>(maxEntries, 0.75f, true)

    fun value(key: String, bake: () -> MonitorLUTCube?): MonitorLUTCube? {
        synchronized(stateLock) {
            if (closed) return null
            cubes[key]?.let { return it }
        }
        return synchronized(bakeLock) admitted@ {
            synchronized(stateLock) {
                if (closed) return@admitted null
                cubes[key]?.let { return@admitted it }
            }
            // Serial misses bound this owner's temporary bake. Retirement never waits here.
            val built = bake() ?: return@admitted null
            synchronized(stateLock) {
                if (closed) return@admitted null
                if (maxEntries > 0) {
                    while (cubes.size >= maxEntries) {
                        val eldest = cubes.entries.iterator()
                        eldest.next()
                        eldest.remove()
                    }
                    cubes[key] = built
                }
                built
            }
        }
    }

    override fun close() {
        synchronized(stateLock) {
            closed = true
            cubes.clear()
        }
    }

    internal data class Snapshot(val entries: Int, val payloadBytes: Long, val closed: Boolean)
    internal fun snapshot(): Snapshot = synchronized(stateLock) {
        Snapshot(cubes.size, cubes.values.sumOf { it.rgba.size.toLong() }, closed)
    }

    companion object {
        const val DEFAULT_ENTRIES = 8
    }
}
