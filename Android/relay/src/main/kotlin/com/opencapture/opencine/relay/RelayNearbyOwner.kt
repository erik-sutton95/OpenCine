package com.opencapture.opencine.relay

import java.util.UUID

public data class RelayNearbyListingFacts(public val name: String, public val isWatchable: Boolean)
public data class RelayNearbyPresenceFacts(
    public val name: String, public val isWatchable: Boolean, public val relayPort: Int?,
)

/** Immutable deployed discovery facts. Milliseconds mirror the platform's supplied clock. */
public data class RelayNearbyLedgerPolicy(
    public val hiddenIdentity: HiddenIdentity,
    public val duplicateIdentity: DuplicateIdentity,
    public val removesPresenceOnListingRemoval: Boolean,
    public val filteringThresholdMillis: Long = 10_000,
    public val confirmation: Confirmation = Confirmation.WATCHABLE_ANSWERS,
) {
    public enum class HiddenIdentity { SOURCE_ADDRESS, NAME }
    public enum class DuplicateIdentity { ALL_LISTINGS, UNREFUTED_LISTINGS }
    public enum class Confirmation { ALL_ANSWERS, WATCHABLE_ANSWERS }
    init { require(filteringThresholdMillis > 0) }
}

public data class RelayNearbyPublication<Presence>(
    public val presences: Map<String, Presence>,
    public val refutedNames: Set<String>,
    public val networkFiltersDiscovery: Boolean,
)

/** Complete passive ledger. Payload and endpoint conversion are bounded values; sweeps,
 * explicit goodbye pruning, refutation and continuous hidden evidence are owned here. */
public class RelayNearbyOwner<Listing, Presence>(
    private val policy: RelayNearbyLedgerPolicy,
    private val listingFacts: (Listing) -> RelayNearbyListingFacts,
    private val presenceFacts: (Presence) -> RelayNearbyPresenceFacts,
    private val presenceListing: (String, Int, Presence) -> Listing?,
) {
    private var rows: List<Listing> = emptyList()
    private var hits: Map<String, Presence> = emptyMap()
    private var refuted: Set<String> = emptySet()
    private var filtering: Boolean = false
    private var hiddenSince: Map<String, Long> = emptyMap()
    private var lastListingNames: Set<String> = emptySet()
    private var sweepSource: UUID? = null
    public val listings: List<Listing> @Synchronized get() = rows.toList()
    public val presences: Map<String, Presence> @Synchronized get() = hits.toMap()
    public val refutedNames: Set<String> @Synchronized get() = refuted.toSet()
    public val networkFiltersDiscovery: Boolean @Synchronized get() = filtering

    @Synchronized public fun acceptListingEvent(listings: List<Listing>): Unit {
        val currentNames = listings.mapTo(mutableSetOf()) { listingFacts(it).name }
        if (policy.removesPresenceOnListingRemoval) {
            val removed = lastListingNames - currentNames
            hits = hits.filterValues { presenceFacts(it).name !in removed }
            hiddenSince = hiddenSince.filterKeys { key ->
                when (policy.hiddenIdentity) {
                    RelayNearbyLedgerPolicy.HiddenIdentity.SOURCE_ADDRESS -> key in hits
                    RelayNearbyLedgerPolicy.HiddenIdentity.NAME -> key !in removed
                }
            }
        }
        lastListingNames = currentNames
        rows = listings.toList()
    }

    /** Composition/retirement is not a native goodbye. The next sweep owns its verdict. */
    @Synchronized public fun replaceListings(listings: List<Listing>): Unit { rows = listings.toList() }

    /** Publication admission only; the SDK discovery owner still owns its sweep. */
    @Synchronized public fun beginSweep(): UUID = UUID.randomUUID().also { sweepSource = it }
    @Synchronized public fun retireSweep(source: UUID): Unit { if (sweepSource == source) sweepSource = null }

    @Synchronized public fun applySweep(
        presences: Map<String, Presence>, selfName: String, nowMillis: Long, source: UUID,
    ): Boolean {
        if (sweepSource != source) return false
        applySweep(presences, selfName, nowMillis)
        return true
    }

    @Synchronized public fun applySweep(presences: Map<String, Presence>, selfName: String, nowMillis: Long): Unit {
        hits = presences.toMap()
        val visibleNames = rows.mapTo(mutableSetOf()) { listingFacts(it).name }
        val confirmedNames = hits.values.map(presenceFacts).filter {
            when (policy.confirmation) {
                RelayNearbyLedgerPolicy.Confirmation.ALL_ANSWERS -> true
                RelayNearbyLedgerPolicy.Confirmation.WATCHABLE_ANSWERS -> it.isWatchable
            }
        }.mapTo(mutableSetOf()) { it.name }
        refuted = visibleNames - confirmedNames
        evaluateFiltering(selfName, nowMillis)
    }

    @Synchronized public fun evaluateFiltering(selfName: String, nowMillis: Long): Unit {
        val visibleNames = rows.mapTo(mutableSetOf()) { listingFacts(it).name }
        val updated = mutableMapOf<String, Long>()
        hits.forEach { (host, presence) ->
            val facts = presenceFacts(presence)
            if (facts.isWatchable && facts.name != selfName && facts.name !in visibleNames) {
                val key = when (policy.hiddenIdentity) {
                    RelayNearbyLedgerPolicy.HiddenIdentity.SOURCE_ADDRESS -> host
                    RelayNearbyLedgerPolicy.HiddenIdentity.NAME -> facts.name
                }
                updated[key] = hiddenSince[key] ?: nowMillis
            }
        }
        hiddenSince = updated
        filtering = updated.values.any { nowMillis - it >= policy.filteringThresholdMillis }
    }

    @Synchronized public fun evaluateFiltering(selfName: String, nowMillis: Long, source: UUID): Boolean {
        if (sweepSource != source) return false
        evaluateFiltering(selfName, nowMillis)
        return true
    }

    public val publication: RelayNearbyPublication<Presence> @Synchronized get() =
        RelayNearbyPublication(hits.toMap(), refuted.toSet(), filtering)

    /** Passive shields remain available to the discovery exclusion port. */
    @Synchronized public fun mergedListings(selfName: String): List<Listing> {
        return mergedListings(rows, selfName)
    }

    @Synchronized public fun mergedListings(listings: List<Listing>, selfName: String): List<Listing> {
        val visible = listings.filter { listingFacts(it).name !in refuted }
        val duplicateRows = when (policy.duplicateIdentity) {
            RelayNearbyLedgerPolicy.DuplicateIdentity.ALL_LISTINGS -> listings
            RelayNearbyLedgerPolicy.DuplicateIdentity.UNREFUTED_LISTINGS -> visible
        }
        val names = duplicateRows.mapTo(mutableSetOf()) { listingFacts(it).name }
        val appended = hits.mapNotNull { (host, presence) ->
            val facts = presenceFacts(presence)
            val port = facts.relayPort
            if (!facts.isWatchable || facts.name == selfName || facts.name in names || port == null) null
            else presenceListing(host, port, presence)
        }.sortedBy { listingFacts(it).name }
        return visible + appended
    }

    @Synchronized public fun watchableListings(selfName: String): List<Listing> =
        mergedListings(selfName).filter { listingFacts(it).isWatchable }

    @Synchronized public fun watchableListings(listings: List<Listing>, selfName: String): List<Listing> =
        mergedListings(listings, selfName).filter { listingFacts(it).isWatchable }
}
