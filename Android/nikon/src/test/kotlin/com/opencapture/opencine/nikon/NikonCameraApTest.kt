package com.opencapture.opencine.nikon

import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The Nikon join schedule over the shared joiner (moved from OpenZCine's `joinWithFallback`). */
class NikonCameraApTest {
    @Test
    fun `a Nikon access point gets three exact attempts and then its model prefix`() {
        val attempts = NikonCameraAp.attempts("NIKON_ZR_01234", 45_000)
        assertEquals(
            listOf("NIKON_ZR_01234", "NIKON_ZR_01234", "NIKON_ZR_01234", "NIKON_ZR_"),
            attempts.map { it.ssid },
        )
        assertEquals(listOf(18_000, 28_000, 45_000, 45_000), attempts.map { it.timeoutMillis })
        assertEquals(listOf(12_000L, 5_000L, 5_000L, 5_000L), attempts.map { it.preScanMillis })
        assertEquals(listOf(true, false, false, false), attempts.map { it.requireVisible })
        assertEquals(listOf(false, false, false, true), attempts.map { it.matchPrefix })
        assertEquals("NIKON_Z", NikonCameraAp.attempts("NIKON_Z9_AP", 10_000).last().ssid)
    }

    @Test
    fun `any other network never falls back to a prefix and short budgets still end on a full one`() {
        val attempts = NikonCameraAp.attempts("HomeWifi", 10_000)
        assertEquals(listOf(10_000, 10_000, 30_000), attempts.map { it.timeoutMillis })
        assertTrue(attempts.none { it.matchPrefix })
    }

    @Test
    fun `attempts stop at the first join and pause only between exact attempts`() = runTest {
        val tried = mutableListOf<String>()
        val joined = NikonCameraAp.runAttempts(NikonCameraAp.attempts("NIKON_ZR_01234", 45_000), { true }) {
            tried += it.ssid
            it.matchPrefix
        }
        assertTrue(joined)
        assertEquals(4, tried.size)
        assertEquals(2_400L, currentTime)

        tried.clear()
        assertTrue(NikonCameraAp.runAttempts(NikonCameraAp.attempts("NIKON_ZR_01234", 45_000), { true }) { tried += it.ssid; true })
        assertEquals(1, tried.size)
    }

    @Test
    fun `Wi-Fi switched off ends the join before the next attempt`() = runTest {
        var wifi = true
        var tried = 0
        val joined = NikonCameraAp.runAttempts(NikonCameraAp.attempts("NIKON_ZR_01234", 45_000), { wifi }) {
            tried += 1
            wifi = false
            false
        }
        assertFalse(joined)
        assertEquals(1, tried)
    }
}
