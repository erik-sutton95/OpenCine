package com.opencapture.opencine.nikon

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Kotlin half of `Fixtures/nikon-setup-vectors.tsv`: which saved records are one setup and
 * which wins, as Swift `PTPIPSavedCameraRecords.canonicalized` decides. See
 * `Tests/OpenCineNikonTests/NikonSetupVectorTests.swift`.
 */
class NikonSetupVectorTest {
    private val vectors: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "nikon-setup-vectors.tsv").readLines()
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .map { it.split("\t") }

    private fun value(field: String): String? = field.takeIf { it != "<nil>" }

    private fun record(field: String): SavedCameraRecord {
        val (host, name, path, network, lastSeen) = field.split(",")
        val transport = when (path) {
            "accessPoint" -> SavedCameraTransport.CAMERA_ACCESS_POINT
            "infrastructure" -> SavedCameraTransport.INFRASTRUCTURE
            "phoneHotspot" -> SavedCameraTransport.PHONE_HOTSPOT
            "usbC" -> SavedCameraTransport.USB_C
            else -> error("unknown path $path")
        }
        return SavedCameraRecord(
            host, name, transport, value(lastSeen)?.toLong(),
            wifiSsid = value(network).takeIf { transport == SavedCameraTransport.CAMERA_ACCESS_POINT },
            networkName = value(network).takeIf { transport == SavedCameraTransport.INFRASTRUCTURE },
        )
    }

    private fun described(record: SavedCameraRecord): String =
        listOf(record.host, record.cameraName, record.wifiSsid ?: record.networkName ?: "<nil>").joinToString(",")

    @Test
    fun `fixture is present`() {
        assertTrue(vectors.size >= 20, "fixture missing or truncated: ${vectors.size} rows")
        assertEquals(setOf("canonical"), vectors.map { it[0] }.toSet())
    }

    @Test
    fun `kotlin canonicalization matches every vector`() {
        for (row in vectors) {
            val canonical = SavedCameraRecords.canonicalized(row[1].split("|").map(::record))
            assertEquals(row[2], canonical.joinToString("|", transform = ::described).ifEmpty { "<empty>" }, "row: ${row[1]}")
        }
    }
}
