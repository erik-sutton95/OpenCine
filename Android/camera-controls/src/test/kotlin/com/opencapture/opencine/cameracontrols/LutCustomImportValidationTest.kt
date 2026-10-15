package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.LutCatalog
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/**
 * A4-27: the picker's custom import used to store any bytes as a LUT, so a broken file silently
 * rendered as no look. It now goes through the library, which stores nothing the app's Swift
 * validator (`CubeLUT.validatedImport`, stood in for here) refuses.
 */
class LutCustomImportValidationTest {
    @Test fun customImportRefusesBytesThatAreNotACube() = runTest {
        val dir = Files.createTempDirectory("opc-luts-").toFile()
        try {
            val library = MonitorLutLibrary(mapOf(MonitorLutCategory.CUSTOM to dir), pack = { bytes ->
                if (String(bytes).startsWith("LUT_3D_SIZE")) ByteArray(2 * 2 * 2 * 4) else null
            })
            assertIs<MonitorLutImportResult.Rejected>(
                library.importCube(MonitorLutCategory.CUSTOM, "not a cube".toByteArray(), "Broken.cube"))
            assertTrue(library.entries.value.isEmpty())
            assertTrue(LutCatalog.storedCustom(dir.list().orEmpty().toList()).isEmpty())
        } finally { dir.deleteRecursively() }
    }
}
