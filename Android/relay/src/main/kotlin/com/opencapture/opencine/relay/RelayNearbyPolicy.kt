package com.opencapture.opencine.relay

/** Passive endpoint and presence facts; exact JSON/TXT keys remain in the deployed codec. */
public data class RelayBroadcast(
    public val name: String,
    public val host: String,
    public val port: Int,
    public val servedCameraHost: String?,
    public val isWatchable: Boolean = true,
)

public data class RelayPresence(
    public val name: String,
    public val watchable: Boolean,
    public val servedCameraHost: String?,
    public val relayPort: Int?,
)

/** Common authoritative-sweep merge, refutation and continuous filtering evidence. */
public object RelayNearbyPolicy {
    public fun merge(
        nsdRows: List<RelayBroadcast>, presences: Map<String, RelayPresence>, selfName: String,
        refutedNames: Set<String> = emptySet(),
    ): List<RelayBroadcast> {
        val visibleNsd = nsdRows.filterNot { it.name in refutedNames }
        val nsdNames = visibleNsd.mapTo(mutableSetOf(), RelayBroadcast::name)
        val presenceRows = presences.mapNotNull { (host, presence) ->
            val port = presence.relayPort ?: return@mapNotNull null
            if (!presence.watchable || presence.name == selfName || presence.name in nsdNames) {
                return@mapNotNull null
            }
            RelayBroadcast(presence.name, host, port, presence.servedCameraHost)
        }.sortedBy(RelayBroadcast::name)
        return visibleNsd + presenceRows
    }

    public fun hiddenSince(
        presences: Map<String, RelayPresence>, nsdNames: Set<String>, selfName: String,
        previous: Map<String, Long>, nowMillis: Long,
    ): Map<String, Long> = presences.values.asSequence()
        // A non-watchable shield has a deliberately distinct NSD name, so it proves no filtering.
        .filter(RelayPresence::watchable).map(RelayPresence::name)
        .filter { it != selfName && it !in nsdNames }
        .associateWith { previous[it] ?: nowMillis }

    public fun provesFiltering(
        hiddenSince: Map<String, Long>, nowMillis: Long, thresholdMillis: Long = 10_000,
    ): Boolean = hiddenSince.values.any { nowMillis - it >= thresholdMillis }
}
