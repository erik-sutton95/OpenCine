package com.opencapture.opencine.appkit

import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith

/** SIMULATED mirror: MonitorMediaCacheSelectedFilesTests. Uses actual temporary files. */
class MonitorMediaCacheSelectedFilesTest {
    private fun <T> withDirectory(block: (MonitorMediaCacheDirectory) -> T): T {
        val root = Files.createTempDirectory("selected-cache").toFile()
        try { return block(MonitorMediaCacheDirectory(root)) }
        finally { root.deleteRecursively() }
    }

    @Test fun selectedCountAndClearPreserveOtherMediaAndReportActualRemovals() = withDirectory { directory ->
        runBlocking {
            directory.write(ByteArray(10), "camera/clip.mov")
            directory.write(ByteArray(3), "camera/thumb.jpg")
            directory.write(ByteArray(7), "local/recording.mov")
            directory.write(byteArrayOf(1), "camera/keep.txt")
            assertEquals(10L, directory.selectedByteCount(listOf("camera/clip.mov", "camera/clip.mov")))
            val removed = directory.removeFiles(listOf("camera/clip.mov", "camera/thumb.jpg", "camera/missing.mov"))
            assertEquals(13L, removed.removedBytes)
            assertEquals(emptyList(), removed.remainingFiles)
            assertEquals(0L, directory.selectedByteCount(listOf("camera/clip.mov")))
            assertContentEquals(ByteArray(7), directory.read("local/recording.mov"))
            assertContentEquals(byteArrayOf(1), directory.read("camera/keep.txt"))
        }
    }

    @Test fun failedRemovalCountsOnlyDeletedBytesAndRetainsRetryableFiles() = withDirectory { directory ->
        runBlocking {
            directory.write(ByteArray(4), "removed.mov")
            directory.write(ByteArray(6), "locked/blocked.mov")
            val locked = File(directory.root, "locked").toPath()
            Files.setPosixFilePermissions(locked, PosixFilePermissions.fromString("r-xr-xr-x"))
            try {
                val result = directory.removeFiles(listOf("removed.mov", "locked/blocked.mov"))
                assertEquals(4L, result.removedBytes)
                assertEquals(listOf("locked/blocked.mov"), result.remainingFiles)
                assertContentEquals(ByteArray(6), directory.read("locked/blocked.mov"))
            } finally { Files.setPosixFilePermissions(locked, PosixFilePermissions.fromString("rwxr-xr-x")) }
            val retry = directory.removeFiles(listOf("removed.mov", "locked/blocked.mov"))
            assertEquals(6L, retry.removedBytes)
            assertEquals(emptyList(), retry.remainingFiles)
        }
    }

    @Test fun cancelledCallerCannotRemoveFilesOrRetireWriters() = withDirectory { directory ->
        runBlocking {
            directory.write(ByteArray(4), "clip.mov")
            val generation = directory.generation
            launch {
                cancel()
                assertFailsWith<CancellationException> { directory.removeFiles(listOf("clip.mov")) }
                assertFailsWith<CancellationException> { directory.selectedByteCount(listOf("clip.mov")) }
            }.join()
            assertEquals(generation, directory.generation)
            assertContentEquals(ByteArray(4), directory.read("clip.mov"))
        }
    }

    @Test fun selectiveClearRetainsUnselectedLocalStagingBytes() = withDirectory { directory ->
        runBlocking {
            directory.write(ByteArray(4), "camera/clip.mov")
            val writer = directory.beginWrite("local/import.mov")
            try {
                writer.write(byteArrayOf(1, 2, 3))
                val staging = File(directory.root, "local").listFiles()!!.single()
                directory.removeFiles(listOf("camera/clip.mov"))
                assertContentEquals(byteArrayOf(1, 2, 3), staging.readBytes())
            } finally { writer.abort() }
        }
    }

    @Test fun unsafeSelectionNeverRemovesUnselectedFilesOrFollowsLinks() = withDirectory { directory ->
        runBlocking {
            directory.write(ByteArray(4), "keep.mov")
            Files.createSymbolicLink(File(directory.root, "link").toPath(), directory.root.toPath())
            assertFailsWith<MonitorMediaCacheException> {
                directory.removeFiles(listOf("keep.mov", "../outside"))
            }
            assertFailsWith<MonitorMediaCacheException> { directory.selectedByteCount(listOf("link/keep.mov")) }
            assertContentEquals(ByteArray(4), directory.read("keep.mov"))
        }
    }
}
