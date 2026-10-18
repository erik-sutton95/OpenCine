package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import androidx.core.content.edit

/**
 * The operator's feed-sharing choices under the app's existing keys: whether this monitor shares its
 * feed, whether watchers may request control, and the watcher relay priority ceiling (0 is the
 * highest quality). Reads never write; priority clamps on read and on write.
 */
public class MonitorSharingPreferences(
    private val storage: SharedPreferences,
    private val keys: Keys,
    private val priorityRange: IntRange,
    private val defaults: Defaults = Defaults(),
) {
    public data class Keys(
        public val shareThisFeed: String,
        public val controlRequests: String,
        public val broadcastPriority: String,
    ) {
        init {
            val names = listOf(shareThisFeed, controlRequests, broadcastPriority)
            require(names.all { it.isNotEmpty() } && names.toSet().size == names.size)
        }

        public companion object {
            /** The keys camera apps already use: `<prefix>ShareThisFeed` and so on. */
            public fun prefixed(prefix: String): Keys =
                Keys("${prefix}ShareThisFeed", "${prefix}ControlRequests", "${prefix}BroadcastPriority")
        }
    }

    public data class Defaults(
        public val shareThisFeed: Boolean = false,
        public val controlRequests: Boolean = true,
        public val broadcastPriority: Int = 0,
    )

    init { require(!priorityRange.isEmpty()) }

    public var shareThisFeed: Boolean
        get() = storage.getBoolean(keys.shareThisFeed, defaults.shareThisFeed)
        set(value) = storage.edit { putBoolean(keys.shareThisFeed, value) }
    public var controlRequests: Boolean
        get() = storage.getBoolean(keys.controlRequests, defaults.controlRequests)
        set(value) = storage.edit { putBoolean(keys.controlRequests, value) }
    public var broadcastPriority: Int
        get() = storage.getInt(keys.broadcastPriority, defaults.broadcastPriority).coerceIn(priorityRange)
        set(value) = storage.edit { putInt(keys.broadcastPriority, value.coerceIn(priorityRange)) }
}
