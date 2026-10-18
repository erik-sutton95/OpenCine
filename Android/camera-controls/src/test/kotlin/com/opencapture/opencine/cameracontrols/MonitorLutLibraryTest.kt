package com.opencapture.opencine.cameracontrols

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/** The shared app-private LUT library (A4-27; the store tests moved from OpenZCine). */
class MonitorLutLibraryTest {
    private val vendor = MonitorLutCategory("VENDOR")
    private val root: File = Files.createTempDirectory("opc-lut-library-").toFile()
    private val directories = mapOf(MonitorLutCategory.CUSTOM to File(root, "custom"), vendor to File(root, "vendor"))
    private var valid = true
    private var packedByteCount = 2 * 2 * 2 * 4
    private val pack: (ByteArray) -> ByteArray? = { bytes -> if (valid && bytes.isNotEmpty()) ByteArray(packedByteCount) { 0x7F } else null }

    private fun library() = MonitorLutLibrary(directories, pack)

    private suspend fun MonitorLutLibrary.imported(name: String?, bytes: ByteArray = byteArrayOf(1), category: MonitorLutCategory = MonitorLutCategory.CUSTOM) =
        assertIs<MonitorLutImportResult.Imported>(importCube(category, bytes, name)).entry

    @Test fun importKeepsTheOperatorsNameAndSurvivesARestart() = runTest {
        val library = library()
        val imported = library.imported("../../Operator Look.cube")

        assertEquals("Operator Look.cube", imported.selection.fileName)
        assertEquals("Operator Look", imported.displayName)
        assertEquals(2, imported.cubeSize)
        assertTrue(File(root, "custom/Operator Look.cube").isFile)
        assertNotNull(library.packedCube(imported.selection))

        val reloaded = library()
        assertEquals(listOf(imported.selection), reloaded.entries(MonitorLutCategory.CUSTOM).map { it.selection })
        assertTrue(reloaded.prepare(imported.selection))
        assertNotNull(reloaded.packedCube(imported.selection))
    }

    @Test fun reimportReplacesTheSameNameAndUnnamedSourcesGetAFallback() = runTest {
        val library = library()
        library.imported("Look", byteArrayOf(1))
        library.imported("Look.cube", byteArrayOf(2))
        library.imported(null)
        library.imported("..")

        assertEquals(listOf("Imported.cube", "Look.cube"), library.entries.value.map { it.selection.fileName })
        assertEquals(listOf<Byte>(2), File(root, "custom/Look.cube").readBytes().toList())
    }

    // Catches a same-identity import that updates disk but leaves render payload/generation stale.
    @Test fun sameNameReplacementRefreshesPackedCubeAndRenderGenerationWithoutChangingIdentity() = runTest {
        val library = MonitorLutLibrary(directories, pack = { bytes ->
            bytes.singleOrNull()?.takeIf { it > 0 }?.let { value -> ByteArray(32) { value } }
        })
        try {
            val first = library.imported("Operator Look.cube", byteArrayOf(1))
            val generation = library.renderGeneration.value
            assertEquals(List<Byte>(32) { 1 }, assertNotNull(library.packedCube(first.selection)).rgba.toList())

            val replacement = library.imported("Operator Look.cube", byteArrayOf(2))
            assertEquals(first.selection, replacement.selection)
            assertEquals(listOf(first.selection), library.entries.value.map { it.selection })
            assertTrue(library.renderGeneration.value > generation)
            assertEquals(List<Byte>(32) { 2 }, assertNotNull(library.packedCube(first.selection)).rgba.toList())
            assertEquals(listOf<Byte>(2), File(root, "custom/Operator Look.cube").readBytes().toList())

            val replacedGeneration = library.renderGeneration.value
            assertIs<MonitorLutImportResult.Rejected>(
                library.importCube(MonitorLutCategory.CUSTOM, byteArrayOf(0), "Operator Look.cube"))
            assertEquals(replacedGeneration, library.renderGeneration.value)
            assertEquals(listOf(first.selection), library.entries.value.map { it.selection })
            assertEquals(List<Byte>(32) { 2 }, assertNotNull(library.packedCube(first.selection)).rgba.toList())
            assertEquals(listOf<Byte>(2), File(root, "custom/Operator Look.cube").readBytes().toList())
        } finally { root.deleteRecursively() }
    }

    @Test fun invalidPayloadNeverReachesStorageAndCorruptStorageReportsAFailure() = runTest {
        val library = library()
        valid = false
        assertIs<MonitorLutImportResult.Rejected>(library.importCube(MonitorLutCategory.CUSTOM, byteArrayOf(7), "look.cube"))
        assertTrue(root.walk().none { it.isFile })

        valid = true
        val imported = library.imported("look.cube")
        valid = false
        assertFalse(library.prepare(imported.selection))
        assertEquals(MonitorLutFailure.INVALID, library.failures.value[imported.selection])
        assertNull(library.packedCube(imported.selection))
        assertEquals(listOf(imported.selection), library.entries.value.map { it.selection })
    }

    @Test fun malformedPackedPayloadAndUnknownCategoryAreRejectedBeforeStorage() = runTest {
        packedByteCount = 1
        assertIs<MonitorLutImportResult.Rejected>(library().importCube(MonitorLutCategory.CUSTOM, byteArrayOf(3), "on-set.cube"))
        packedByteCount = 32
        assertIs<MonitorLutImportResult.Rejected>(library().importCube(MonitorLutCategory("OTHER"), byteArrayOf(3), "on-set.cube"))
        assertTrue(root.walk().none { it.isFile })
    }

    @Test fun missingFileReportsMissing() = runTest {
        val library = library()
        val imported = library.imported("gone.cube")
        File(root, "custom/gone.cube").delete()
        assertFalse(library.prepare(imported.selection))
        assertEquals(MonitorLutFailure.MISSING, library.failures.value[imported.selection])
    }

    @Test fun deletionRemovesOnlyItsLibraryState() = runTest {
        val library = library()
        val imported = library.imported("on-set.cube")
        val outside = File(root, "outside.cube").apply { writeBytes(byteArrayOf(1)) }

        assertTrue(library.delete(imported.selection))
        assertFalse(library.contains(imported.selection))
        assertTrue(library.entries.value.isEmpty())
        assertNull(library.packedCube(imported.selection))
        assertTrue(outside.isFile)
        assertNull(MonitorLutSelection.of(MonitorLutCategory.CUSTOM, "../outside.cube"))
    }

    @Test fun replacementStaysInCategoryAndSkipsInvalidCubes() = runTest {
        val library = library()
        val alpha = library.imported("alpha.cube")
        val bravo = library.imported("bravo.cube")
        val active = library.imported("active.cube")
        library.imported("aardvark.cube", category = vendor)
        File(root, "custom/alpha.cube").writeBytes(byteArrayOf())

        assertTrue(library.delete(active.selection))
        assertEquals(bravo.selection, library.firstPreparedReplacement(active.selection))
        assertEquals(MonitorLutFailure.INVALID, library.failures.value[alpha.selection])
    }

    @Test fun categoriesListSeparately() = runTest {
        val library = library()
        library.imported("look.cube")
        val vendorLook = library.imported("look.cube", category = vendor)
        assertEquals(listOf(vendorLook), library.entries(vendor))
        assertEquals(2, library.entries.value.size)
    }
}
