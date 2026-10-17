package com.opencapture.opencine.vocabulary

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Kotlin half of `Fixtures/storage-readout.tsv` (A5-11). Swift owns the same readout in
 * `StorageReadout.swift` and reads the same rows (`StorageReadoutVectorTests`).
 */
class StorageReadoutVectorTest {
    private val rows: List<List<String>> =
        File(System.getProperty("opencine.fixtures"), "storage-readout.tsv")
            .takeIf { it.isFile }
            ?.readLines()
            .orEmpty()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }

    @Suppress("DEPRECATION")
    @Test fun originalStorageGetterUsesTheCommonReadout() {
        assertEquals("2.15 GB · 50%", CameraStatus(storageFreeMb = 2048, storageTotalMb = 4096).storageLabel)
        assertEquals("0 B · 0%", CameraStatus(storageFreeMb = 0, storageTotalMb = 4096).storageLabel)
        assertEquals(StorageReadout.UNAVAILABLE, CameraStatus().storageLabel)
    }

    @Test
    fun bytesReadTheSharedText() {
        val bytes = rows.filter { it.first() == "bytes" }
        assertTrue(bytes.size > 5)
        for (row in bytes) {
            val readout = StorageReadout(row[1].toLong(), row[2].toLongOrNull())
            assertEquals(row[3], readout.free, "$row")
            assertEquals(row[4], readout.label, "$row")
        }
    }

    @Test
    fun statusVolumeRuleReadsTheSharedText() {
        val mib = rows.filter { it.first() == "mib" }
        assertTrue(mib.size > 5)
        for (row in mib) {
            val status = CameraStatus(
                storageFreeMb = row[1].toInt(), storageTotalMb = row[2].toInt(),
                sdFreeMb = row[3].toInt(), sdTotalMb = row[4].toInt(),
            )
            assertEquals(row[5], status.storageReadout?.label ?: "-", "$row")
        }
    }
}
