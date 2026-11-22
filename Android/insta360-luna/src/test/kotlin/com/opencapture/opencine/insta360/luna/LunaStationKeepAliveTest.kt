package com.opencapture.opencine.insta360.luna

import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Firmware v1.2.7 leaves a Wi-Fi or hotspot setup's network about 60 s after each join; the
 * keep-alive asks it to join again over the control link (Swift `LunaStationKeepAliveTests`).
 */
class LunaStationKeepAliveTest {
    private val network = LunaStationNetwork("Studio", "synthetic1", false)

    @Test fun theRequestIsTheJoinOfTheSameNetwork() {
        assertContentEquals(LunaStationWire.join("Studio", "synthetic1"), LunaStationWire.keepAlive("Studio", "synthetic1"))
        assertTrue(LunaStationWire.KEEP_ALIVE_INTERVAL_MS < 60_000L)
    }

    @Test fun theJoinIsSentAtOnceThenEveryInterval() = runTest {
        val codes = mutableListOf<Int>()
        val job = launch { LunaStationKeepAlive.run(network, { code, _ -> codes += code }, {}) }
        runCurrent()
        assertEquals(1, codes.size)
        advanceTimeBy(LunaStationWire.KEEP_ALIVE_INTERVAL_MS); runCurrent()
        assertEquals(2, codes.size)
        advanceTimeBy(LunaStationWire.KEEP_ALIVE_INTERVAL_MS); runCurrent()
        assertEquals(3, codes.size)
        assertTrue(codes.all { it == LunaStationWire.SET_WIFI_CONNECTION_INFO })
        job.cancel()
    }

    @Test fun aMissedAnswerIsLoggedAndTheNextJoinStillGoes() = runTest {
        var failing = true
        var sent = 0
        val logs = mutableListOf<String>()
        val job = launch {
            LunaStationKeepAlive.run(network, { _, _ -> sent += 1; if (failing) error("no answer") }, { logs += it })
        }
        runCurrent()
        failing = false
        advanceTimeBy(LunaStationWire.KEEP_ALIVE_INTERVAL_MS); runCurrent()
        assertEquals(2, sent)
        assertEquals(listOf("luna: station keep-alive not answered (1 in a row)", "luna: station keep-alive answered again"), logs)
        assertTrue(logs.none { "synthetic1" in it })
        job.cancel()
    }
}
