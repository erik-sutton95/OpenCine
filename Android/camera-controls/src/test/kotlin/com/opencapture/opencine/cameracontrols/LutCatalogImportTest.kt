package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.LutCatalog
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LutCatalogImportTest {
    @Test
    fun importAndDeleteRoundTrip() {
        val dir = File.createTempFile("opc-luts", "").apply {
            delete()
            mkdirs()
        }
        try {
            val entry = LutCatalog.importCube("Look.cube", "LUT_3D_SIZE 2\n".toByteArray(), dir)
            assertEquals("custom:Look.cube", entry.id)
            assertEquals("Look", entry.title)
            assertTrue(File(dir, "Look.cube").isFile)
            assertEquals(listOf("Look.cube"), LutCatalog.listCustom(dir).map { it.fileName })
            LutCatalog.deleteCustom("Look.cube", dir)
            assertTrue(LutCatalog.listCustom(dir).isEmpty())
        } finally {
            dir.deleteRecursively()
        }
    }
}
