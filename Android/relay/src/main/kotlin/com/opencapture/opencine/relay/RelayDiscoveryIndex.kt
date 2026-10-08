package com.opencapture.opencine.relay

import java.text.Collator
import java.util.UUID

/** Passive facts; the SDK endpoint stays a supplied value, never an active probe. */
public data class RelayDiscoveryRow<Endpoint>(
    public val id: String,
    public val name: String,
    public val endpoint: Endpoint,
    public val servedCameraHost: String? = null,
    public val isWatchable: Boolean = true,
)

/** Listing/TXT source retirement and deterministic duplicate-interface enrichment. */
public class RelayDiscoveryIndex<Endpoint>(private val order: Order = Order.LOCALIZED_CASE_INSENSITIVE) {
    public enum class Order { NAME, LOCALIZED_CASE_INSENSITIVE }
    public var results: List<RelayDiscoveryRow<Endpoint>> = emptyList()
        private set
    private val lifetime = RelayConnectionLifetime()
    private val origins = mutableMapOf<String, Map<String, RelayDiscoveryRow<Endpoint>>>()

    public fun start(): UUID { origins.clear(); results = emptyList(); return lifetime.begin() }
    public fun stop(): Unit { lifetime.retire(); origins.clear(); results = emptyList() }
    public fun admits(token: UUID): Boolean = lifetime.admits(token)
    public fun replace(rows: List<RelayDiscoveryRow<Endpoint>>, origin: String, token: UUID): Boolean {
        if (!lifetime.admits(token)) return false
        val sourceRows = mutableMapOf<String, RelayDiscoveryRow<Endpoint>>()
        for (row in rows) sourceRows[row.id] = sourceRows[row.id]?.let { preferred(it, row) } ?: row
        origins[origin] = sourceRows.toMap()
        val merged = mutableMapOf<String, RelayDiscoveryRow<Endpoint>>()
        for (key in origins.keys.sorted()) for ((id, row) in origins[key].orEmpty()) {
            merged[id] = merged[id]?.let { preferred(it, row) } ?: row
        }
        results = when (order) {
            Order.NAME -> merged.values.sortedBy { it.name }
            Order.LOCALIZED_CASE_INSENSITIVE -> {
                val collator = Collator.getInstance().apply { strength = Collator.SECONDARY }
                merged.values.sortedWith { left, right -> collator.compare(left.name, right.name) }
            }
        }
        return true
    }
    private fun preferred(first: RelayDiscoveryRow<Endpoint>, second: RelayDiscoveryRow<Endpoint>): RelayDiscoveryRow<Endpoint> {
        fun rank(row: RelayDiscoveryRow<Endpoint>): Int =
            (if (row.servedCameraHost == null) 0 else 2) + (if (row.isWatchable) 0 else 1)
        return if (rank(second) > rank(first)) second else first
    }
}
