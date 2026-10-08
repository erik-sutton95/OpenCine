package com.opencapture.opencine.relay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

public class RelayNearbyOwnerTest {
    private data class Presence(val name: String, val watchable: Boolean = true, val port: Int? = 5000, val bytes: List<Byte> = name.toByteArray().toList())
    private data class Row(val name: String, val endpoint: String, val watchable: Boolean = true)
    private fun owner(
        hidden: RelayNearbyLedgerPolicy.HiddenIdentity = RelayNearbyLedgerPolicy.HiddenIdentity.SOURCE_ADDRESS,
        duplicate: RelayNearbyLedgerPolicy.DuplicateIdentity = RelayNearbyLedgerPolicy.DuplicateIdentity.ALL_LISTINGS,
        removes: Boolean = true,
        confirmation: RelayNearbyLedgerPolicy.Confirmation = RelayNearbyLedgerPolicy.Confirmation.WATCHABLE_ANSWERS,
    ): RelayNearbyOwner<Row, Presence> = RelayNearbyOwner(
        policy = RelayNearbyLedgerPolicy(hidden, duplicate, removes, confirmation = confirmation),
        listingFacts = { RelayNearbyListingFacts(it.name, it.watchable) },
        presenceFacts = { RelayNearbyPresenceFacts(it.name, it.watchable, it.port) },
        presenceListing = { host, port, presence -> if (port > 0) Row(presence.name, "$host:$port") else null },
    )

    @Test public fun authoritativeSweepRetainsShieldButAddsOnlyJoinableEndpoint(): Unit {
        val ledger = owner()
        ledger.acceptListingEvent(listOf(Row("Held in-use", "shield", false), Row("Live", "bonjour")))
        val hits = mapOf("h1" to Presence("Held", false, null), "h2" to Presence("Live", true, 5021),
            "h3" to Presence("Only direct", true, 5030), "h4" to Presence("Self"),
            "h5" to Presence("Portless", true, null), "h6" to Presence("Invalid", true, 0))
        ledger.applySweep(hits, "Self", 0)
        assertEquals(hits, ledger.presences)
        assertEquals(2, ledger.listings.size)
        assertFalse(ledger.listings[0].watchable)
        assertEquals(listOf("bonjour", "h3:5030"), ledger.watchableListings("Self").map { it.endpoint })
        ledger.applySweep(mapOf("h1" to hits.getValue("h1")), "Self", 1000)
        assertTrue(ledger.watchableListings("Self").isEmpty())
        assertTrue("Live" in ledger.refutedNames)
        ledger.applySweep(mapOf("h2" to hits.getValue("h2")), "Self", 2000)
        assertEquals(listOf("bonjour"), ledger.watchableListings("Self").map { it.endpoint })
        assertEquals(1, ledger.presences.size)
    }

    @Test public fun filteringIsContinuousTenSecondsAndNeverCountsCameraInUseShield(): Unit {
        val ledger = owner()
        val hits = mapOf("h" to Presence("Live"))
        ledger.applySweep(hits, "Self", 1000)
        ledger.applySweep(hits, "Self", 10_999)
        assertFalse(ledger.networkFiltersDiscovery)
        ledger.applySweep(hits, "Self", 11_000)
        assertTrue(ledger.networkFiltersDiscovery)
        ledger.acceptListingEvent(listOf(Row("Live", "visible")))
        ledger.applySweep(hits, "Self", 11_001)
        assertFalse(ledger.networkFiltersDiscovery)
        ledger.acceptListingEvent(emptyList())
        ledger.applySweep(hits, "Self", 12_000)
        assertFalse(ledger.networkFiltersDiscovery)
        ledger.applySweep(emptyMap(), "Self", 30_000)
        assertTrue(ledger.presences.isEmpty())
        assertFalse(ledger.networkFiltersDiscovery)
        ledger.applySweep(mapOf("h" to Presence("Held", false)), "Self", 31_000)
        ledger.applySweep(mapOf("h" to Presence("Held", false)), "Self", 99_000)
        assertFalse(ledger.networkFiltersDiscovery)
    }

    @Test public fun actualListingRemovalPrunesKnownPresenceButKeepsFilteredOnlySource(): Unit {
        val ledger = owner()
        ledger.acceptListingEvent(listOf(Row("Known", "visible")))
        ledger.applySweep(mapOf("h1" to Presence("Known"), "h2" to Presence("Hidden")), "Self", 0)
        ledger.acceptListingEvent(emptyList())
        assertEquals(setOf("h2"), ledger.presences.keys)
        assertEquals(listOf("Hidden"), ledger.watchableListings("Self").map { it.name })
        ledger.replaceListings(listOf(Row("Known", "visible")))
        ledger.applySweep(mapOf("h1" to Presence("Known"), "h2" to Presence("Hidden")), "Self", 1000)
        ledger.replaceListings(emptyList())
        assertEquals(2, ledger.presences.size)
    }

    @Test public fun continuityAndDuplicateRecipesPreserveDeployedDifferences(): Unit {
        val address = owner()
        val name = owner(RelayNearbyLedgerPolicy.HiddenIdentity.NAME, RelayNearbyLedgerPolicy.DuplicateIdentity.UNREFUTED_LISTINGS, false)
        listOf(0L, 9000L).forEach { instant ->
            address.applySweep(mapOf("a" to Presence("Same")), "Self", instant)
            name.applySweep(mapOf("a" to Presence("Same")), "Self", instant)
        }
        address.applySweep(mapOf("b" to Presence("Same")), "Self", 10_000)
        name.applySweep(mapOf("b" to Presence("Same")), "Self", 10_000)
        assertFalse(address.networkFiltersDiscovery)
        assertTrue(name.networkFiltersDiscovery)
        address.replaceListings(listOf(Row("Same", "old listing")))
        name.replaceListings(listOf(Row("Same", "old listing")))
        address.applySweep(emptyMap(), "Self", 11_000)
        name.applySweep(emptyMap(), "Self", 11_000)
        assertTrue(address.watchableListings("Self").isEmpty())
        assertTrue(name.watchableListings("Self").isEmpty())
        address.applySweep(mapOf("b" to Presence("Same")), "Self", 12_000)
        name.applySweep(mapOf("b" to Presence("Same")), "Self", 12_000)
        assertEquals(listOf("old listing"), address.watchableListings("Self").map { it.endpoint })
        assertEquals(listOf("old listing"), name.watchableListings("Self").map { it.endpoint })
    }

    @Test public fun oldSweepResultAndFinallyCannotPublishOrRetireSuccessor(): Unit {
        val ledger = owner()
        val old = ledger.beginSweep()
        val next = ledger.beginSweep()
        assertFalse(ledger.applySweep(mapOf("old" to Presence("Same")), "Self", 0, old))
        assertTrue(ledger.presences.isEmpty())
        ledger.retireSweep(old)
        assertTrue(ledger.applySweep(mapOf("next" to Presence("Same")), "Self", 1000, next))
        assertEquals(setOf("next"), ledger.presences.keys)
        ledger.retireSweep(next)
        assertFalse(ledger.applySweep(emptyMap(), "Self", 99_000, next))
        assertEquals(setOf("next"), ledger.presences.keys)
        assertTrue(ledger.applySweep(emptyMap(), "Self", 100_000, ledger.beginSweep()))
        assertTrue(ledger.presences.isEmpty())
        assertFalse(ledger.networkFiltersDiscovery)
    }

    @Test public fun limitedSweepClockEvaluationDoesNotInventNewRefutations(): Unit {
        val ledger = owner()
        val source = ledger.beginSweep()
        ledger.replaceListings(listOf(Row("New", "new native")))
        assertTrue(ledger.evaluateFiltering("Self", 0, source))
        assertTrue(ledger.refutedNames.isEmpty())
        assertTrue(ledger.applySweep(mapOf("h" to Presence("Hidden")), "Self", 1000, source))
        assertFalse(ledger.networkFiltersDiscovery)
        assertTrue("New" in ledger.refutedNames)
        assertTrue(ledger.evaluateFiltering("Self", 11_000, source))
        assertTrue(ledger.networkFiltersDiscovery)
        ledger.replaceListings(listOf(Row("Hidden", "now visible")))
        assertTrue(ledger.evaluateFiltering("Self", 12_000, source))
        assertFalse(ledger.networkFiltersDiscovery)
        assertEquals(setOf("New"), ledger.refutedNames)
        ledger.retireSweep(source)
        assertFalse(ledger.evaluateFiltering("Self", 99_000, source))
        assertFalse(ledger.networkFiltersDiscovery)
    }

    @Test public fun answerConfirmationRecipeKeepsOriginalShieldRefutationDifference(): Unit {
        val watchable = owner()
        val anyAnswer = owner(confirmation = RelayNearbyLedgerPolicy.Confirmation.ALL_ANSWERS)
        val listing = Row("Same", "old broadcast")
        val shield = mapOf("h" to Presence("Same", false, null))
        watchable.replaceListings(listOf(listing))
        anyAnswer.replaceListings(listOf(listing))
        watchable.applySweep(shield, "Self", 0)
        anyAnswer.applySweep(shield, "Self", 0)
        assertTrue(watchable.watchableListings("Self").isEmpty())
        assertEquals(listOf("old broadcast"), anyAnswer.watchableListings("Self").map { it.endpoint })
        assertFalse(watchable.networkFiltersDiscovery)
        assertFalse(anyAnswer.networkFiltersDiscovery)
    }
}
