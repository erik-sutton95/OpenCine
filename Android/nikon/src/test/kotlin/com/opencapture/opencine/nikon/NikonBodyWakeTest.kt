package com.opencapture.opencine.nikon

import kotlinx.coroutines.delay
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
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

    // The pause is measured on the test's virtual clock: on the default real clock a slow runner
    // spends a real millisecond inside a dial and the virtual pause comes out that much short.
    @Test
    fun `a waking body is dialled again until it answers`() = runTest {
        var dials = 0
        val outcome = NikonBodyWake.awaitAnswer("192.168.1.20", nowMillis = { currentTime }) { ++dials >= 4 }
        assertEquals(NikonBodyWake.Outcome.Answered(4), outcome)
        // These dials end at once, so each pause is the rest of its slot.
        assertEquals(3 * NikonBodyWake.SLOT_MILLIS, currentTime)
    }

    @Test
    fun `a silent body is bounded by the dial count with no pause after the last dial`() = runTest {
        var dials = 0
        val outcome = NikonBodyWake.awaitAnswer("192.168.1.20", nowMillis = { currentTime }) { dials++; false }
        assertEquals(NikonBodyWake.Outcome.Silent(NikonBodyWake.DIALS), outcome)
        assertEquals(NikonBodyWake.DIALS, dials)
        // Hardware pass 2026-10-25 (1.11, 3.7): dials a kernel refuses at once must still span the
        // whole wait, one slot each, instead of collapsing it to a few seconds.
        assertEquals((NikonBodyWake.DIALS - 1) * NikonBodyWake.SLOT_MILLIS, currentTime)
    }

    @Test
    fun `a dial that used its whole deadline is followed by the shortest pause only`() = runTest {
        val outcome =
            NikonBodyWake.awaitAnswer("192.168.1.20", nowMillis = { currentTime }) {
                delay(1_500)
                false
            }
        assertEquals(NikonBodyWake.Outcome.Silent(NikonBodyWake.DIALS), outcome)
        assertEquals(
            NikonBodyWake.DIALS * 1_500L + (NikonBodyWake.DIALS - 1) * NikonBodyWake.INTERVAL_MILLIS,
            currentTime,
        )
    }

    @Test
    fun `a dial cut short pauses for the rest of its slot, matching Swift`() {
        assertEquals(NikonBodyWake.SLOT_MILLIS, NikonBodyWake.pauseAfter(0))
        assertEquals(1_700L, NikonBodyWake.pauseAfter(300))
        assertEquals(NikonBodyWake.INTERVAL_MILLIS, NikonBodyWake.pauseAfter(1_900))
        assertEquals(NikonBodyWake.INTERVAL_MILLIS, NikonBodyWake.pauseAfter(5_000))
    }

    @Test
    fun `a connect that timed out counts against the wake, so the operator sees one wait`() = runTest {
        var alive = 0
        assertFailsWith<NikonBodyWake.SilentException> {
            NikonBodyWake.dial<String>(
                host = "192.168.1.20",
                isAlive = { alive++; false },
                nowMillis = { currentTime },
                dial = {
                    delay(10_000)
                    throw NikonBodyWake.DialFailure(DialTestFailure(), wakeWorthy = true)
                },
            )
        }
        assertEquals(5, alive)
        assertEquals(10_000L + 4 * NikonBodyWake.SLOT_MILLIS, currentTime)
        assertEquals(NikonBodyWake.DIALS, NikonBodyWake.dialsLeft(0))
        assertEquals(1, NikonBodyWake.dialsLeft(60_000))
    }

    @Test
    fun `the wake reports waiting, then the answer, before the retry dial`() = runTest {
        val events = mutableListOf<String>()
        var dials = 0
        NikonBodyWake.dial<String>(
            host = "192.168.1.20",
            isAlive = { events += "alive"; true },
            onWakeProgress = { events += it.name },
            dial = {
                dials++
                events += "dial"
                if (dials == 1) throw NikonBodyWake.DialFailure(DialTestFailure(), wakeWorthy = true)
                "connected"
            },
        )
        assertEquals(listOf("dial", "WAITING", "alive", "ANSWERED", "dial"), events)
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

    private class DialTestFailure : Exception("dial failed")

    @Test
    fun `an unreachable dial wakes the body and retries exactly once`() = runTest {
        var dials = 0
        var wakes = 0
        val alive = mutableListOf<String>()
        val value =
            NikonBodyWake.dial<String>(
                host = "192.168.1.20",
                isAlive = { host -> alive += host; true },
                onWake = { wakes++ },
                dial = {
                    dials++
                    if (dials == 1) throw NikonBodyWake.DialFailure(DialTestFailure(), wakeWorthy = true)
                    "connected"
                },
            )
        assertEquals("connected", value)
        assertEquals(2, dials)
        assertEquals(1, wakes)
        assertEquals(listOf("192.168.1.20"), alive)
    }

    @Test
    fun `a body the pre-dial wake already heard costs one presence dial and no second wait`() = runTest {
        // The app's saved-setup step (#91) asks the network before dialling an unseen setup; the
        // dial's own wake runs only if the dial still fails at the link layer. A body the first
        // step just heard answers the first presence dial, so the two never stack.
        var alive = 0
        var dials = 0
        var wakes = 0
        val pre = NikonBodyWake.awaitAnswer("192.168.1.20") { alive++; true }
        assertEquals(NikonBodyWake.Outcome.Answered(1), pre)
        val value =
            NikonBodyWake.dial<String>(
                host = "192.168.1.20",
                isAlive = { alive++; true },
                onWake = { wakes++ },
                dial = {
                    dials++
                    if (dials == 1) throw NikonBodyWake.DialFailure(DialTestFailure(), wakeWorthy = true)
                    "connected"
                },
            )
        assertEquals("connected", value)
        assertEquals(2, alive)
        assertEquals(2, dials)
        assertEquals(1, wakes)
        assertEquals(0, currentTime)
    }

    @Test
    fun `a silent wake ends with the honest copy and never redials`() = runTest {
        var dials = 0
        var alive = 0
        val failure =
            assertFailsWith<NikonBodyWake.SilentException> {
                NikonBodyWake.dial<String>(
                    host = "192.168.1.20",
                    deviceName = "ZR_6002199",
                    isAlive = { alive++; false },
                    dial = {
                        dials++
                        throw NikonBodyWake.DialFailure(DialTestFailure(), wakeWorthy = true)
                    },
                )
            }
        assertEquals(NikonBodyWake.silentMessage("ZR_6002199"), failure.message)
        assertEquals(1, dials)
        assertEquals(NikonBodyWake.DIALS, alive)
    }

    @Test
    fun `a second unreachable failure surfaces the honest silent error and wakes once`() = runTest {
        var dials = 0
        var wakes = 0
        val failure =
            assertFailsWith<NikonBodyWake.SilentException> {
                NikonBodyWake.dial<String>(
                    host = "192.168.1.20",
                    deviceName = "ZR_6002199",
                    isAlive = { true },
                    onWake = { wakes++ },
                    dial = {
                        dials++
                        throw NikonBodyWake.DialFailure(DialTestFailure(), wakeWorthy = true)
                    },
                )
            }
        assertEquals(NikonBodyWake.silentMessage("ZR_6002199"), failure.message)
        assertEquals(2, dials)
        assertEquals(1, wakes)
    }

    @Test
    fun `a refused dial never wakes the body`() = runTest {
        var dials = 0
        var wakes = 0
        var alive = 0
        assertFailsWith<DialTestFailure> {
            NikonBodyWake.dial<String>(
                host = "192.168.1.20",
                isAlive = { alive++; true },
                onWake = { wakes++ },
                dial = {
                    dials++
                    throw NikonBodyWake.DialFailure(DialTestFailure(), wakeWorthy = false)
                },
            )
        }
        assertEquals(1, dials)
        assertEquals(0, wakes)
        assertEquals(0, alive)
    }
}
