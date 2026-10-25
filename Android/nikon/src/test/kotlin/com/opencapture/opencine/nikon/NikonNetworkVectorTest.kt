package com.opencapture.opencine.nikon

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Kotlin half of `Fixtures/nikon-network-vectors.tsv`: the Nikon network policies Swift owns
 * (`CameraWiFiSSID`, `CameraDiscovery`, `InfrastructureDiscovery`), re-implemented in
 * `NikonNetworkPolicy.kt`. See `Tests/OpenCineNikonTests/NikonNetworkVectorTests.swift`.
 */
class NikonNetworkVectorTest {
    private val vectors: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "nikon-network-vectors.tsv").readLines()
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .map { it.split("\t") }

    private fun value(field: String): String? = when (field) {
        "<nil>" -> null
        "<empty>" -> ""
        else -> field
    }

    private fun verdict(name: String): HostProbeVerdict = when (name) {
        "open" -> HostProbeVerdict.OPEN
        "refused" -> HostProbeVerdict.REFUSED
        "timeout" -> HostProbeVerdict.TIMEOUT
        "noRoute" -> HostProbeVerdict.NO_ROUTE
        "noNetwork" -> HostProbeVerdict.NO_NETWORK
        "denied" -> HostProbeVerdict.DENIED
        "unreachableOther" -> HostProbeVerdict.UNREACHABLE_OTHER
        else -> error("unknown verdict $name")
    }

    private fun tally(field: String): InfrastructureSweepTally {
        val c = field.split(",").map(String::toInt)
        return InfrastructureSweepTally(c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7])
    }

    private fun described(tally: InfrastructureSweepTally): String = with(tally) {
        val counts = listOf(openCount, occupiedCount, timeoutCount, refusedCount, noRouteCount, deniedCount, otherCount, hostsProbed)
        val hosts = { list: List<String> -> list.joinToString(",").ifEmpty { "<empty>" } }
        counts.joinToString(",") + "|" + hosts(occupiedHosts) + "|" + hosts(openHosts)
    }

    private fun described(reason: InfrastructureMissReason): String = when (reason) {
        InfrastructureMissReason.LocalNetworkDenied -> "localNetworkDenied"
        InfrastructureMissReason.NoScannableInterface -> "noScannableInterface"
        InfrastructureMissReason.OnCameraAccessPoint -> "onCameraAccessPoint"
        InfrastructureMissReason.NetworkUnreachable -> "networkUnreachable"
        InfrastructureMissReason.HostsVisibleNoPtp -> "hostsVisibleNoPTP"
        InfrastructureMissReason.CameraNotFound -> "cameraNotFound"
        is InfrastructureMissReason.HeldByOtherDevice -> "heldByOtherDevice:${reason.holder}"
    }

    private fun preflight(name: String): InfrastructurePreflight = when (name) {
        "ready" -> InfrastructurePreflight.Ready(listOf("192.168.1"))
        "noScannableInterface" -> InfrastructurePreflight.NoScannableInterface
        "localNetworkDenied" -> InfrastructurePreflight.LocalNetworkDenied
        else -> error("unknown preflight $name")
    }

    private fun answer(row: List<String>): String? = when (row[0]) {
        "apSsid" -> NikonAccessPointSsid.isNikonZAccessPoint(value(row[1])!!).toString()
        "dialable" -> NikonHosts.isDialableHost(value(row[1])!!).toString()
        "apHostKey" -> NikonHosts.pendingAccessPointHostKey(value(row[1]))
        "isApHostKey" -> NikonHosts.isAccessPointHostKey(value(row[1])!!).toString()
        "subnetBase" -> NikonHosts.subnetBase(value(row[1])!!)
        "privateIPv4" -> NikonHosts.isPrivateIPv4(value(row[1])!!).toString()
        "scanIface" -> NikonHosts.isScanInterface(value(row[1])!!, row[2]).toString()
        "tally" -> described(
            InfrastructureSweepTally.from(
                value(row[1])!!.split(",").filter(String::isNotEmpty).associate { pair ->
                    pair.substringBefore("=") to verdict(pair.substringAfter("="))
                },
            ),
        )
        "classify" -> described(
            InfrastructureDiscovery.classifyMiss(
                preflight(row[1]), row[2].toBooleanStrict(), value(row[3])?.let(::tally), value(row[4]),
            ),
        )
        else -> error("unknown kind ${row[0]}")
    }

    @Test
    fun `fixture is present and covers every policy`() {
        assertTrue(vectors.size > 60, "fixture missing or truncated: ${vectors.size} rows")
        assertEquals(
            setOf("apSsid", "dialable", "apHostKey", "isApHostKey", "subnetBase", "privateIPv4", "scanIface", "tally", "classify"),
            vectors.map { it[0] }.toSet(),
        )
    }

    @Test
    fun `kotlin policies match every vector`() {
        for (row in vectors) {
            assertEquals(value(row.last()), answer(row), "row: ${row.joinToString(" | ")}")
        }
    }
}
