package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.DiscoveryMode
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Every dial a pass made, by purpose (Swift `FakeDialer`). Android sends no PTP bytes while discovering. */
private class FakeDialer : NikonDialer {
    val dials = mutableListOf<Pair<String, NikonDialPurpose>>()
    var presences: Map<String, NikonPresence> = emptyMap()
    var alive: Set<String> = emptySet()
    var open: Set<String> = emptySet()
    val controlDials: List<String> get() = synchronized(dials) { dials.filter { it.second == NikonDialPurpose.CAMERA_CONTROL }.map { it.first } }

    override suspend fun presence(host: String): NikonPresence? {
        synchronized(dials) { dials += host to NikonDialPurpose.PRESENCE }
        return presences[host]
    }
    override suspend fun isAlive(host: String): Boolean {
        synchronized(dials) { dials += host to NikonDialPurpose.PRESENCE }
        return host in alive
    }
    override suspend fun scanControlPort(host: String, timeoutMillis: Int): HostProbeVerdict {
        synchronized(dials) { dials += host to NikonDialPurpose.CAMERA_CONTROL }
        return if (host in open) HostProbeVerdict.OPEN else HostProbeVerdict.TIMEOUT
    }
}

/** Swift suite `NikonDiscoveryTests`: the Nikon passive-only rule, pinned. */
class NikonDiscoveryTest {
    private val phone = listOf(NikonLocalInterface("wlan0", "192.168.1.42"))
    private var clock = 0L

    private fun discovery(dialer: NikonDialer) = NikonDiscovery(dialer, { phone }, nowNanos = { clock })

    /** physical-C C9: a saved connect asks with a fresh sweep, outside the list's rate window. */
    @Test
    fun currentHolderSweepsFreshAndNamesTheServingDevice() = runTest {
        val dialer = FakeDialer()
        val discovery = discovery(dialer)
        discovery.presenceSweep()
        dialer.presences = mapOf(
            "192.168.1.7" to NikonPresence("Phone B", "192.168.1.20"),
            "192.168.1.8" to NikonPresence("Phone C"),
        )
        assertEquals("Phone B", discovery.currentHolder("192.168.1.20"))
        assertEquals(null, discovery.currentHolder("192.168.1.30"))
        val swept = dialer.dials.size
        assertEquals(null, discovery.currentHolder("usb:1"))
        assertEquals(null, discovery.currentHolder("ap:NIKON_ZR"))
        assertEquals(swept, dialer.dials.size, "a cable or a pending access point sweeps nothing")
        assertTrue(dialer.controlDials.isEmpty())
        assertTrue(dialer.dials.none { it.first == "192.168.1.42" }, "this phone never asks itself")
    }

    @Test
    fun passiveDiscoveryNeverDialsTheControlPort() = runTest {
        val dialer = FakeDialer().apply {
            presences = mapOf("192.168.1.7" to NikonPresence("Phone B", "192.168.1.20"))
            alive = setOf("192.168.1.30")
            open = setOf("192.168.1.30", "192.168.1.20")
        }
        val discovery = discovery(dialer)
        val presences = discovery.presenceSweep()
        val alive = discovery.liveness(listOf("192.168.1.30", "192.168.1.31"))
        val search = discovery.search(DiscoveryMode.PASSIVE, listOf("192.168.1.30"))
        // Presence and liveness ran; not one dial reached a camera's control service.
        assertTrue(dialer.controlDials.isEmpty())
        assertEquals(253 + 2, dialer.dials.size)
        assertEquals(setOf("192.168.1.7"), presences?.keys)
        assertEquals(setOf("192.168.1.30"), alive)
        assertTrue(search.openHosts.isEmpty())
    }

    @Test
    fun thePassiveDialerRefusesCameraControl() = runTest {
        val dialer = FakeDialer()
        assertEquals(HostProbeVerdict.DENIED, PassiveDialer(dialer).scanControlPort("192.168.1.30", 100))
        assertTrue(dialer.dials.isEmpty())
    }

    @Test
    fun activeDiscoverySkipsShieldedHosts() = runTest {
        val dialer = FakeDialer().apply {
            presences = mapOf("192.168.1.7" to NikonPresence("Phone B", "192.168.1.20"))
            open = setOf("192.168.1.30", "192.168.1.20", "192.168.1.31")
        }
        val discovery = discovery(dialer)
        discovery.presenceSweep()
        val found = discovery.search(
            DiscoveryMode.ACTIVE, listOf("192.168.1.20", "192.168.1.30", "192.168.1.31"), excludedHosts = setOf("192.168.1.31"),
        )
        // The camera another device serves and the excluded one are never dialled.
        assertEquals(setOf("192.168.1.30"), dialer.controlDials.toSet())
        assertEquals(listOf("192.168.1.30"), found.openHosts)
    }

    @Test
    fun directedProbesDialOnlyDialableHostsOnThisPhonesSubnets() = runTest {
        val dialer = FakeDialer().apply { open = setOf("192.168.1.246", "192.168.129.246") }
        val found = discovery(dialer).search(
            DiscoveryMode.ACTIVE,
            // A travel router's sibling setup, a USB device key, a pending access-point key, a duplicate, nothing.
            listOf("192.168.1.246", "192.168.129.246", "usb:00000030-3030", "ap:NIKON_ZR_02199", " 192.168.1.246", ""),
        )
        assertEquals(listOf("192.168.1.246"), dialer.controlDials)
        assertEquals(listOf("192.168.1.246"), found.openHosts)
    }

    @Test
    fun onlyAnAnswerProvesOccupancy() {
        // A dial the OS refused, or one that exhausted this device, says nothing about the host.
        assertEquals(listOf(HostProbeVerdict.OPEN, HostProbeVerdict.REFUSED), HostProbeVerdict.entries.filter { it.isOccupied })
        assertEquals(
            listOf(HostProbeVerdict.TIMEOUT, HostProbeVerdict.NO_ROUTE, HostProbeVerdict.NO_NETWORK),
            HostProbeVerdict.entries.filter { it.isSilence },
        )
    }

    @Test
    fun theSweepIsMuteBeforeItIdentifies() = runTest {
        val dialer = FakeDialer().apply { open = setOf("192.168.1.55") }
        val found = discovery(dialer).search(DiscoveryMode.ACTIVE)
        // Android identifies at connect time: the sweep only dials, stops at the open host, and
        // never dials this phone.
        assertEquals(listOf("192.168.1.55"), found.openHosts)
        assertTrue("192.168.1.42" !in dialer.controlDials)
        assertEquals(253, dialer.controlDials.size)
    }

    @Test
    fun presenceSweepsAtMostEvery30Seconds() = runTest {
        val dialer = FakeDialer().apply { presences = mapOf("192.168.1.7" to NikonPresence("Phone B", "192.168.1.20")) }
        val discovery = discovery(dialer)
        assertTrue(discovery.presenceSweep() != null)
        clock += 29_000_000_000
        assertEquals(null, discovery.presenceSweep())
        discovery.search(DiscoveryMode.ACTIVE, listOf("192.168.1.20"))
        // Its shield still keeps the served camera safe.
        assertTrue("192.168.1.20" !in dialer.controlDials)
        clock += 2_000_000_000
        assertTrue(discovery.presenceSweep() != null)
    }
}
