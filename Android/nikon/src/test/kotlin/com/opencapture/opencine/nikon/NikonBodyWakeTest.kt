package com.opencapture.opencine.nikon

import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Swift twin: `NikonBodyWakeTests.swift`. */
class NikonBodyWakeTest {
    @Test
    fun `an awake body goes straight on with one dial and no pause`() = runTest {
        val dialed = mutableListOf<String>()
        val outcome = NikonBodyWake.awaitAnswer("192.168.1.20") { dialed += it; true }
        assertEquals(NikonBodyWake.Outcome.Answered(1), outcome)
        assertEquals(listOf("192.168.1.20"), dialed)
        assertEquals(0, currentTime)
    }

    @Test
    fun `a waking body is dialled again until it answers`() = runTest {
        var dials = 0
        val outcome = NikonBodyWake.awaitAnswer("192.168.1.20") { ++dials >= 4 }
        assertEquals(NikonBodyWake.Outcome.Answered(4), outcome)
        assertEquals(3 * NikonBodyWake.INTERVAL_MILLIS, currentTime)
    }

    @Test
    fun `a silent body is bounded by the dial count with no pause after the last dial`() = runTest {
        var dials = 0
        val outcome = NikonBodyWake.awaitAnswer("192.168.1.20") { dials++; false }
        assertEquals(NikonBodyWake.Outcome.Silent(NikonBodyWake.DIALS), outcome)
        assertEquals(NikonBodyWake.DIALS, dials)
        assertEquals((NikonBodyWake.DIALS - 1) * NikonBodyWake.INTERVAL_MILLIS, currentTime)
    }

    @Test
    fun `the silent copy names the camera and both real causes, matching Swift`() {
        val named = NikonBodyWake.silentMessage("ZR_6002199")
        assertTrue(named.startsWith("ZR_6002199 didn't answer on this network."))
        assertTrue("asleep" in named && "same Wi‑Fi" in named)
        assertFalse("timed out" in named.lowercase())
        assertTrue(NikonBodyWake.silentMessage(" ").startsWith("The camera didn't answer"))
        assertEquals("Waiting for ZR_6002199 to answer on the network…", NikonBodyWake.wakingMessage("ZR_6002199"))
    }
}
