package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.MonitorTransfer
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Swift suite `NikonMultiviewTests`: the Nikon operations a Pocket-standard Multiview tile needs.
 * Scripted links and a manual clock; physical Nikon behavior is untested.
 */
class NikonMultiviewTest {
    private class LinkDown : Exception()

    /** One opened PTP link: which host it reached and the serial GetDeviceInfo reported. */
    private data class Link(val host: String, val serial: String?)

    /** The bodies on the network, every dial and close, and a manual clock that `sleep` advances. */
    private class Network {
        val connects = mutableListOf<String>()
        val closed = mutableListOf<String>()
        val sleeps = mutableListOf<Duration>()
        var now = MonotonicInstant.ZERO
        val serials = mutableMapOf<String, String?>()

        fun connect(host: String): Link {
            connects += host
            if (host !in serials) throw LinkDown()
            return Link(host, serials[host])
        }
    }

    private fun opener(network: Network) = NikonMemberOpener(
        now = { network.now },
        sleep = { network.sleeps += it; network.now += it },
        connect = { network.connect(it) },
        serialNumber = { it.serial },
        close = { network.closed += it.host },
    )

    private val serial = "3001234"
    private val device = NikonMulticamPolicy.device(serial)!!

    // Open a picked body

    @Test
    fun openReturnsTheBodyAndItsSerialDevice() = runTest {
        val network = Network().apply { serials["192.168.1.30"] = serial }
        val result = opener(network).open("192.168.1.30", members = emptySet(), hostsInUse = emptySet())
        assertEquals(Link("192.168.1.30", serial), result.link)
        assertEquals(device, result.device)
        assertEquals(listOf("192.168.1.30"), network.connects)
        assertTrue(network.closed.isEmpty() && network.sleeps.isEmpty())
    }

    /** A host a member or Live View holds is never dialled: a second Init drops its session. */
    @Test
    fun openRefusesAHostInUseWithoutDialling() = runTest {
        val network = Network().apply { serials["192.168.1.30"] = serial }
        val result = opener(network).open("192.168.1.30", members = emptySet(), hostsInUse = setOf(" 192.168.1.30"))
        assertEquals(NikonMemberOpenRefusal.HOST_IN_USE, result.refusal)
        assertTrue(network.connects.isEmpty())
    }

    @Test
    fun openClosesAndRefusesABodyAlreadyInTheGroup() = runTest {
        val network = Network().apply { serials["192.168.1.40"] = serial } // the member, under a new address
        val result = opener(network).open("192.168.1.40", members = setOf(device), hostsInUse = emptySet())
        assertEquals(NikonMemberOpenRefusal.ALREADY_MEMBER, result.refusal)
        assertEquals(listOf("192.168.1.40"), network.closed)
    }

    @Test
    fun openClosesAndRefusesADifferentBody() = runTest {
        val network = Network().apply { serials["192.168.1.30"] = "3009999" }
        val result = opener(network).open("192.168.1.30", expectedSerial = serial, members = emptySet(), hostsInUse = emptySet())
        assertEquals(NikonMemberOpenRefusal.DIFFERENT_BODY, result.refusal)
        assertEquals(listOf("192.168.1.30"), network.closed)
    }

    /** Unknown is not a pass: without a serial the group cannot tell this body from a member. */
    @Test
    fun openClosesAndRefusesABodyWithoutASerial() = runTest {
        val network = Network().apply { serials["192.168.1.30"] = " " }
        val result = opener(network).open("192.168.1.30", members = emptySet(), hostsInUse = emptySet())
        assertEquals(NikonMemberOpenRefusal.NO_IDENTITY, result.refusal)
        assertEquals(listOf("192.168.1.30"), network.closed)
    }

    /** The settle after a close or a failed dial; other hosts never wait. */
    @Test
    fun openWaitsTheReconnectSettleAfterAClose() = runTest {
        val network = Network().apply {
            serials["192.168.1.30"] = serial
            serials["192.168.1.31"] = "3005678"
        }
        val opener = opener(network)
        val first = opener.open("192.168.1.30", members = emptySet(), hostsInUse = emptySet()).link!!
        opener.close(first, "192.168.1.30")
        network.now += 200.milliseconds
        opener.open("192.168.1.31", members = emptySet(), hostsInUse = emptySet())
        assertTrue(network.sleeps.isEmpty())
        opener.open("192.168.1.30", members = emptySet(), hostsInUse = emptySet())
        assertEquals(listOf(1_000.milliseconds), network.sleeps)

        // Nothing answers at .50: the dial fails.
        assertFailsWith<LinkDown> { opener.open("192.168.1.50", members = emptySet(), hostsInUse = emptySet()) }
        runCatching { opener.open("192.168.1.50", members = emptySet(), hostsInUse = emptySet()) }
        assertEquals(listOf(1_000.milliseconds, NikonMemberTiming.RECONNECT_SETTLE), network.sleeps)
        assertEquals(1_200.milliseconds, NikonMemberTiming.RECONNECT_SETTLE)
    }
}
