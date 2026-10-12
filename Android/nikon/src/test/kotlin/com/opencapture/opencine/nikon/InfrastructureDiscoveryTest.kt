package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The infrastructure search policy (moved from OpenZCine with the policy). Its Swift twin is
 * `InfrastructureDiscoveryTests.swift`; `NikonNetworkVectorTest` pins both to the same rows.
 */
class InfrastructureDiscoveryTest {
    // MARK: - Typed verdicts

    /**
     * Verdicts travelled as strings on iOS and drifted: a verdict nobody emitted was counted as
     * occupancy, while running out of file descriptors counted as `other`: evidence about the
     * phone, read as evidence about the network.
     */
    @Test
    fun `only an answer proves somebody holds the address`() {
        for (verdict in HostProbeVerdict.entries) {
            val tally = InfrastructureSweepTally.from(mapOf("10.0.0.2" to verdict))
            assertEquals(1, tally.hostsProbed, "$verdict")
            assertEquals(if (verdict.isOccupied) 1 else 0, tally.occupiedCount, "$verdict")
            assertEquals(if (verdict == HostProbeVerdict.OPEN) 1 else 0, tally.openCount, "$verdict")
        }
    }

    @Test
    fun `a tally counts open refused timeout and occupancy`() {
        val tally =
            InfrastructureSweepTally.from(
                mapOf(
                    "192.168.1.1" to HostProbeVerdict.REFUSED,
                    "192.168.1.10" to HostProbeVerdict.TIMEOUT,
                    "192.168.1.20" to HostProbeVerdict.TIMEOUT,
                    "192.168.1.246" to HostProbeVerdict.OPEN,
                    "192.168.1.50" to HostProbeVerdict.NO_ROUTE,
                    "192.168.1.60" to HostProbeVerdict.DENIED,
                ),
            )

        assertEquals(6, tally.hostsProbed)
        assertEquals(1, tally.openCount)
        assertEquals(1, tally.refusedCount)
        assertEquals(2, tally.timeoutCount)
        assertEquals(1, tally.noRouteCount)
        assertEquals(1, tally.deniedCount)
        assertEquals(listOf("192.168.1.246"), tally.openHosts)
        assertEquals(2, tally.occupiedCount)
    }

    /** A body that wakes on the second pass must not be forgotten because the first pass missed it. */
    @Test
    fun `passes union rather than overwrite each other`() {
        val first =
            InfrastructureSweepTally.from(
                mapOf("10.0.0.2" to HostProbeVerdict.TIMEOUT, "10.0.0.3" to HostProbeVerdict.REFUSED),
            )
        val second =
            InfrastructureSweepTally.from(
                mapOf("10.0.0.2" to HostProbeVerdict.OPEN, "10.0.0.3" to HostProbeVerdict.REFUSED),
            )
        val merged = first.merging(second)

        assertEquals(2, merged.hostsProbed)
        assertEquals(listOf("10.0.0.2"), merged.openHosts)
        assertEquals(listOf("10.0.0.2", "10.0.0.3"), merged.occupiedHosts)
    }

    // MARK: - classifyMiss

    /**
     * The verdict the app owed an operator on a 6 GHz/MLO network: the phone and the camera held
     * addresses on one subnet from one DHCP server, and no packet passed between them. Every host
     * went silent, and the app said "still searching" for days.
     */
    @Test
    fun `a silent subnet is reported as unreachable, not as camera not found`() {
        val silent =
            InfrastructureSweepTally.from(
                (2..200).associate { "192.168.1.$it" to HostProbeVerdict.TIMEOUT },
            )
        assertEquals(
            InfrastructureMissReason.NetworkUnreachable,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = false,
                tally = silent,
            ),
        )

        // The same subnet with the router answering is a LIVE network holding no camera: a
        // different sentence, and a different thing to go and do.
        val live = silent.copy(refusedCount = 1, occupiedCount = 1, occupiedHosts = listOf("192.168.1.1"))
        assertEquals(
            InfrastructureMissReason.HostsVisibleNoPtp,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = false,
                tally = live,
            ),
        )

        // No sweep at all must never be dressed up as one.
        assertEquals(
            InfrastructureMissReason.CameraNotFound,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = false,
                tally = null,
            ),
        )
    }

    @Test
    fun `preflight failures and a held camera outrank any tally`() {
        assertEquals(
            InfrastructureMissReason.NoScannableInterface,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.NoScannableInterface,
                onCameraAccessPoint = false,
                tally = null,
            ),
        )
        assertEquals(
            InfrastructureMissReason.OnCameraAccessPoint,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = true,
                tally = null,
            ),
        )
        assertEquals(
            InfrastructureMissReason.HeldByOtherDevice("Erik's iPad"),
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = false,
                tally = null,
                heldHolderName = "Erik's iPad",
            ),
        )
    }
}
