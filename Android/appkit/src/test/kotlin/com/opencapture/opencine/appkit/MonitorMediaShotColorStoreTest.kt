package com.opencapture.opencine.appkit

import kotlinx.coroutines.test.runTest
import java.nio.file.Files
import kotlin.test.*

/** Pocket's generation fence, now the shared shot color store (A4-34). */
class MonitorMediaShotColorStoreTest {
    @Test fun warmMapCannotOutliveOrRecreateClearedMetadata() = runTest {
        val parent = Files.createTempDirectory("opencine-shot-color-").toFile()
        try {
            val directory = MonitorMediaCacheRoot(parent).directory("camera")
            directory.shotColors.remember("take", 65)
            assertEquals(65, directory.shotColors.color("take"))
            val outgoing = directory.generation
            directory.clear(preserving = listOf("index.json"))
            assertNull(directory.shotColors.color("take"))
            directory.shotColors.remember("take", 65, outgoing)
            assertFalse(directory.file("color.json").exists())
            directory.shotColors.remember("successor", 3, directory.generation)
            assertNull(directory.shotColors.color("take"))
            assertEquals(3, directory.shotColors.color("successor"))
        } finally { parent.deleteRecursively() }
    }

    @Test fun preservingClearKeepsColorsAndReadsNeverWrite() = runTest {
        val parent = Files.createTempDirectory("opencine-shot-color-").toFile()
        try {
            val directory = MonitorMediaCacheRoot(parent).directory("camera")
            assertNull(directory.shotColors.color("take"))
            assertFalse(directory.file("color.json").exists())
            directory.shotColors.remember("take", 2)
            directory.shotColors.remember("ignored", -1)
            directory.clear(preserving = listOf("index.json", "color.json"))
            assertEquals(2, directory.shotColors.color("take"))
            assertNull(directory.shotColors.color("ignored"))
        } finally { parent.deleteRecursively() }
    }

    @Test fun legacyAdoptionNeverOverwritesStoredCodes() {
        val parent = Files.createTempDirectory("opencine-shot-color-").toFile()
        try {
            val directory = MonitorMediaCacheRoot(parent).directory("camera")
            directory.shotColors.remember("take", 2)
            directory.shotColors.adopt(mapOf("take" to 9, "old" to 4, "unknown" to -1))
            assertEquals(2, directory.shotColors.color("take"))
            assertEquals(4, directory.shotColors.color("old"))
            assertNull(directory.shotColors.color("unknown"))
        } finally { parent.deleteRecursively() }
    }

    @Test fun ownersOfOneDirectoryShareTheStore() {
        val parent = Files.createTempDirectory("opencine-shot-color-").toFile()
        try {
            val root = MonitorMediaCacheRoot(parent)
            root.directory("camera").shotColors.remember("take", 7)
            assertSame(root.directory("camera").shotColors, root.directory("camera").shotColors)
            val storage = MonitorMediaCacheStorage()
            storage.directory(java.io.File(parent, "camera")).shotColors.remember("other", 1)
            assertEquals(7, storage.directory(java.io.File(parent, "camera")).shotColors.color("take"))
        } finally { parent.deleteRecursively() }
    }
}
