package com.opencapture.opencine.relay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** SIMULATED supplied aliases/caller time, mirroring Swift; no discovery or wall clock. */
public class RelayProbeShieldTest {
    private fun owner(fallback: Boolean = true): RelayProbeShield =
        RelayProbeShield(RelayProbeShieldPolicy(180.0, fallback))

    @Test public fun knownBroadcastRetainsOnlySuppliedAliases(): Unit {
        val shield = owner()
        val aliases = setOf("camera.local", "192.0.2.10")
        val held = shield.update(listOf(aliases), emptySet(), setOf("192.0.2.99"), 0.0)
        assertEquals(aliases, held)
    }

    @Test public fun missingAndEmptyBroadcastAttributionUseSuppliedFallback(): Unit {
        val saved = setOf("camera.local", "192.0.2.10")
        val held = owner().update(listOf(null, emptySet()), emptySet(), saved, 0.0)
        val other = owner(false).update(listOf(null, emptySet()), emptySet(), saved, 0.0)
        assertEquals(saved, held)
        assertTrue(other.isEmpty())
    }

    @Test public fun unicastPresenceDoesNotInventAllSavedFallback(): Unit {
        val shield = owner()
        val empty = shield.update(emptyList(), emptySet(), setOf("saved"), 0.0)
        assertTrue(empty.isEmpty())
        val aliases = setOf("served.local", "192.0.2.20")
        val held = shield.update(emptyList(), aliases, setOf("saved"), 1.0)
        assertEquals(aliases, held)
    }

    @Test public fun blinkReentryRenewsExactAliasAndKeepsOtherSourceIndependent(): Unit {
        val shield = owner()
        val a = setOf("a.local", "192.0.2.10")
        shield.update(listOf(a), emptySet(), emptySet(), 0.0)
        val blink = shield.update(emptyList(), emptySet(), emptySet(), 80.0)
        assertEquals(a, blink)
        val both = shield.update(listOf(setOf("b")), emptySet(), emptySet(), 100.0)
        assertEquals(a + "b", both)
        val aExpired = shield.update(emptyList(), emptySet(), emptySet(), 180.0)
        assertEquals(setOf("b"), aExpired)
        val reentered = shield.update(listOf(a), emptySet(), emptySet(), 181.0)
        assertEquals(a + "b", reentered)
        val bExpired = shield.update(emptyList(), emptySet(), emptySet(), 280.0)
        assertEquals(a, bExpired)
    }

    @Test public fun expiryIsStrictAtLingerBoundary(): Unit {
        val shield = owner()
        shield.update(listOf(setOf("a")), emptySet(), emptySet(), 0.0)
        val before = shield.update(emptyList(), emptySet(), emptySet(), 179.999)
        val exact = shield.update(emptyList(), emptySet(), emptySet(), 180.0)
        assertEquals(setOf("a"), before)
        assertTrue(exact.isEmpty())
    }

    @Test public fun callerClockRollbackRetainsPastObservation(): Unit {
        val shield = owner()
        shield.update(listOf(setOf("a")), emptySet(), emptySet(), 100.0)
        val rollback = shield.update(emptyList(), emptySet(), emptySet(), 90.0)
        val before = shield.update(emptyList(), emptySet(), emptySet(), 279.999)
        val exact = shield.update(emptyList(), emptySet(), emptySet(), 280.0)
        assertEquals(setOf("a"), rollback)
        assertEquals(setOf("a"), before)
        assertTrue(exact.isEmpty())
    }

    @Test public fun instancesAndReturnedHostValuesDoNotShareState(): Unit {
        val first = owner()
        val second = owner()
        val supplied = mutableSetOf("a")
        val retained = first.update(listOf(supplied), emptySet(), emptySet(), 0.0)
        supplied += "unpublished"
        assertEquals(setOf("a"), first.hosts)
        val independent = second.update(emptyList(), emptySet(), emptySet(), 0.0)
        assertTrue(independent.isEmpty())
        val next = first.update(listOf(setOf("b")), emptySet(), emptySet(), 10.0)
        assertEquals(setOf("a", "b"), next)
        assertEquals(setOf("a"), retained)
    }
}
