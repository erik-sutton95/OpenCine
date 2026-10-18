package com.opencapture.opencine.cameracontrols

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/** A downloaded pack lands in one library category through the library's own validation gate. */
class MonitorLutPackImportTest {
    private val root = createTempDirectory("lut-pack").toFile()
    private val vendor = MonitorLutCategory("VENDOR")
    /** Refuses a cube whose bytes say "bad", as the Swift gate refuses an invalid table. */
    private val library = MonitorLutLibrary(mapOf(vendor to File(root, "vendor")),
        pack = { bytes -> if (String(bytes).contains("bad")) null else ByteArray(2 * 2 * 2 * 4) { 0x7F } })

    @Test fun zipCubesImportAndRefusalsAreCounted() = runTest {
        val zip = File(root, "pack.zip").apply {
            writeBytes(zip("__MACOSX/._a.cube" to "junk", "Looks/A.cube" to "ok-a", "/B.cube" to "ok-b", "C.cube" to "bad"))
        }
        val result = library.importPack(vendor, zip, File(root, "staging"))
        assertEquals(MonitorLutPackImportResult(importedCount = 2, foundCubeEntries = 3, rejectedCubeEntries = 1), result)
        assertEquals(listOf("A.cube", "B.cube"), library.entries.value.map { it.selection.fileName }.sorted())
        assertTrue(File(root, "staging").listFiles().orEmpty().isEmpty(), "staging is cleaned")
    }

    @Test fun loneCubeAndNonArchivesAreReported() = runTest {
        val cube = File(root, "Single.cube").apply { writeText("ok") }
        assertEquals(MonitorLutPackImportResult(1, 1, 0), library.importPack(vendor, cube, File(root, "staging")))
        val page = File(root, "page.zip").apply { writeText("<html>terms</html>") }
        assertEquals(MonitorLutPackImportResult(0, notAnArchive = true), library.importPack(vendor, page, File(root, "staging")))
        val empty = File(root, "empty.zip").apply { writeBytes(zip("readme.txt" to "none")) }
        assertEquals(MonitorLutPackImportResult(0, foundCubeEntries = 0), library.importPack(vendor, empty, File(root, "staging")))
    }

    @Test fun cubeNamesAreSanitisedToSafeBasenames() {
        assertEquals("My_LUT__1_.cube", sanitizeLutCubeFileName("../dir/My LUT (1).cube"))
        assertEquals("lut.cube", sanitizeLutCubeFileName("folder/"))
    }

    private fun zip(vararg entries: Pair<String, String>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, body) in entries) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(body.toByteArray())
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }
}
