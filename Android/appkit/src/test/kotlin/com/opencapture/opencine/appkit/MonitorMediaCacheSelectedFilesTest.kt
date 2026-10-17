package com.opencapture.opencine.appkit

import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

private class SelectedPathFile(file: File) : File(file.path) {
    var onPath: (() -> Unit)? = null
    override fun toPath(): Path {
        onPath?.invoke()
        return super.toPath()
    }
}

/** SIMULATED mirror: MonitorMediaCacheSelectedFilesTests. Uses actual temporary files. */
class MonitorMediaCacheSelectedFilesTest {
    private fun <T> withDirectory(block: (MonitorMediaCacheDirectory) -> T): T {
        val root = Files.createTempDirectory("selected-cache").toFile()
        try { return block(MonitorMediaCacheDirectory(root)) }
        finally { root.deleteRecursively() }
    }

    @Test fun selectedClearCannotDeleteASuccessorCommittedAfterRetirement() {
        val location = Files.createTempDirectory("selected-successor").toFile()
        val root = SelectedPathFile(location)
        val directory = MonitorMediaCacheDirectory(root)
        try {
            directory.write(ByteArray(4), "clip.mov")
            val generation = directory.generation
            root.onPath = {
                if (directory.generation != generation) {
                    root.onPath = null
                    directory.write(byteArrayOf(9, 8, 7), "clip.mov")
                }
            }
            val result = runBlocking { directory.removeFiles(listOf("clip.mov")) }
            assertEquals(0L, result.removedBytes)
            assertEquals(emptyList(), result.remainingFiles)
            assertContentEquals(byteArrayOf(9, 8, 7), directory.read("clip.mov"))
        } finally { location.deleteRecursively() }
    }

    @Test fun heldSelectedStatDoesNotBlockSuccessorAdmission() {
        val location = Files.createTempDirectory("selected-stat-admission").toFile()
        val root = SelectedPathFile(location)
        val directory = MonitorMediaCacheDirectory(root)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val admitted = CountDownLatch(1)
        var clear: CompletableFuture<MonitorMediaCacheRemoval>? = null
        var successor: CompletableFuture<Unit>? = null
        try {
            directory.write(ByteArray(4), "clip.mov")
            val generation = directory.generation
            root.onPath = {
                if (directory.generation != generation) {
                    root.onPath = null
                    entered.countDown()
                    release.await()
                }
            }
            clear = CompletableFuture.supplyAsync { runBlocking { directory.removeFiles(listOf("clip.mov")) } }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            successor = CompletableFuture.supplyAsync {
                directory.write(byteArrayOf(9, 8, 7), "clip.mov")
                admitted.countDown()
            }
            val admittedWhileHeld = admitted.await(5, TimeUnit.SECONDS)
            release.countDown()
            val result = clear.get(5, TimeUnit.SECONDS)
            successor.get(5, TimeUnit.SECONDS)
            assertTrue(admittedWhileHeld, "A held selected stat must not hold namespace admission")
            assertEquals(0L, result.removedBytes)
            assertContentEquals(byteArrayOf(9, 8, 7), directory.read("clip.mov"))
        } finally {
            release.countDown()
            clear?.get(5, TimeUnit.SECONDS)
            successor?.get(5, TimeUnit.SECONDS)
            location.deleteRecursively()
        }
    }

    @Test fun selectedDirectoriesRemoveNestedBytesAndPreserveUnselectedMedia() = withDirectory { directory ->
        runBlocking {
            directory.write(ByteArray(3), "camera/thumbs/old/a.jpg")
            directory.write(ByteArray(4), "camera/thumbs/old/deep/b.jpg")
            directory.write(ByteArray(7), "local/recording.mov")
            directory.write(ByteArray(11), "camera/keep.txt")
            val result = directory.removeFiles(listOf("camera/thumbs/old"))
            assertEquals(7L, result.removedBytes)
            assertEquals(emptyList(), result.remainingFiles)
            assertFalse(File(directory.root, "camera/thumbs/old").exists())
            assertContentEquals(ByteArray(7), directory.read("local/recording.mov"))
            assertContentEquals(ByteArray(11), directory.read("camera/keep.txt"))
        }
    }

    @Test fun selectedDirectoryFailuresRetainDeclaredRootForAnAccurateRetry() = withDirectory { directory ->
        runBlocking {
            directory.write(ByteArray(4), "camera/thumbs/free.jpg")
            directory.write(ByteArray(6), "camera/thumbs/old/blocked.jpg")
            val locked = File(directory.root, "camera/thumbs/old").toPath()
            Files.setPosixFilePermissions(locked, PosixFilePermissions.fromString("r-xr-xr-x"))
            try {
                val result = directory.removeFiles(listOf("camera/thumbs/free.jpg", "camera/thumbs/old"))
                assertEquals(4L, result.removedBytes)
                assertEquals(listOf("camera/thumbs/old"), result.remainingFiles)
            } finally { Files.setPosixFilePermissions(locked, PosixFilePermissions.fromString("rwxr-xr-x")) }
            val retry = directory.removeFiles(listOf("camera/thumbs/free.jpg", "camera/thumbs/old"))
            assertEquals(6L, retry.removedBytes)
            assertEquals(emptyList(), retry.remainingFiles)
            assertFalse(File(directory.root, "camera/thumbs/old").exists())
        }
    }

    @Test fun selectedDirectoryNeverFollowsAnOutsideLink() = withDirectory { directory ->
        val outside = Files.createTempDirectory("selected-outside").toFile()
        try {
            File(outside, "keep.jpg").writeBytes(ByteArray(9))
            directory.write(ByteArray(3), "camera/thumbs/old/a.jpg")
            val link = File(directory.root, "camera/thumbs/old/link").toPath()
            Files.createSymbolicLink(link, outside.toPath())
            runBlocking {
                val result = directory.removeFiles(listOf("camera/thumbs/old"))
                assertEquals(3L, result.removedBytes)
                assertEquals(listOf("camera/thumbs/old"), result.remainingFiles)
                assertTrue(Files.isSymbolicLink(link))
                assertContentEquals(ByteArray(9), File(outside, "keep.jpg").readBytes())
                Files.delete(link)
                val retry = directory.removeFiles(result.remainingFiles)
                assertEquals(0L, retry.removedBytes)
                assertEquals(emptyList(), retry.remainingFiles)
            }
        } finally { outside.deleteRecursively() }
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
