package com.opencapture.opencine.relay

/** Immutable recipe. The caller retains address normalization and discovery resources. */
public data class RelayProbeShieldPolicy(
    public val linger: Double,
    public val shieldsSavedHostsForUnnamedBroadcast: Boolean,
)

/** Instance-scoped alias retention; no socket, command, scheduler or process-wide state. */
public class RelayProbeShield(public val policy: RelayProbeShieldPolicy) {
    private val observed: MutableMap<String, Double> = mutableMapOf()

    public val hosts: Set<String> get() = observed.keys.toSet()

    /**
     * Null/empty broadcast attribution may shield saved aliases. Unattributed presence does
     * not imply that fallback. Time is unchanged, including rollback; retention is age < linger.
     */
    public fun update(
        broadcastHostAliases: List<Set<String>?>,
        presenceHostAliases: Set<String>,
        savedHostAliases: Set<String>,
        now: Double,
    ): Set<String> {
        val seen = presenceHostAliases.toMutableSet()
        for (aliases in broadcastHostAliases) {
            if (!aliases.isNullOrEmpty()) seen += aliases
            else if (policy.shieldsSavedHostsForUnnamedBroadcast) seen += savedHostAliases
        }
        for (host in seen) observed[host] = now
        observed.entries.removeAll { !(now - it.value < policy.linger) }
        return hosts
    }
}
