package com.opencapture.opencine.media

import java.nio.file.Files
import java.nio.file.Path
import java.nio.channels.FileChannel
import java.nio.ByteBuffer
import java.nio.file.StandardOpenOption
import java.util.concurrent.CancellationException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class MonitorMediaShareStagerTest {
    @Test fun completeSourceIsCopiedAtomicallyWithSuppliedMimeAndCapacityFacts() = withRoot { root ->
        val entry = completed(root, "clip.MOV", byteArrayOf(1, 2, 3, 4))
        val stager = stager(root, bytes = 4, count = 1)
        val result = stager.stage(entry, "clip.MOV", "video/*")
        assertEquals("clip.MOV", result.displayName)
        assertEquals("video/*", result.mimeType)
        assertTrue(result.file.startsWith(root.resolve("cache/share/ready")))
        assertFalse(result.file.startsWith(root.resolve("source")))
        assertContentEquals(byteArrayOf(1, 2, 3, 4), Files.readAllBytes(result.file))
        assertContentEquals(byteArrayOf(1, 2, 3, 4), Files.readAllBytes(entry.finalPath))
        assertEquals(0L, fileCount(root.resolve("cache/share/staging")))
    }

    @Test fun partialUnsafeAndMalformedSourcesCannotPublishReadyFiles() = withRoot { root ->
        val partial = ProgressiveMediaCache(root.resolve("source")).openEntry(
            "camera", ProgressiveMediaCacheIdentity("partial.mov", "partial"), 4,
        )
        partial.append(0, byteArrayOf(1, 2))
        val stager = stager(root)
        val error = assertFailsWith<IncompleteMonitorMediaShareException> {
            stager.stage(partial, "partial.mov", "video/*")
        }
        assertEquals(ProgressiveMediaCacheState.ACTIVE, error.cacheState)
        val complete = completed(root, "complete.mov", byteArrayOf(3, 4))
        assertFailsWith<UnsafeMonitorMediaShareFilenameException> {
            stager.stage(complete, "../complete.mov", "video/*")
        }
        assertFailsWith<InvalidMonitorMediaShareSourceException> {
            stager.stage(complete, "complete.mov", "video/mp4\ninvalid")
        }
        assertEquals(0L, fileCount(root.resolve("cache/share/ready")))
        assertContentEquals(byteArrayOf(1, 2), Files.readAllBytes(partial.partialPath))
    }

    @Test fun cancellationRemovesOnlyItsUnpublishedCopy() = withRoot { root ->
        val current = completed(root, "current.mov", byteArrayOf(1, 2))
        val candidate = completed(root, "next.mov", byteArrayOf(3, 4, 5, 6))
        val stager = stager(root)
        val granted = stager.stage(current, "current.mov", "video/*")
        var checks = 0
        assertFailsWith<CancellationException> {
            stager.stage(candidate, "next.mov", "video/*") {
                checks += 1
                if (checks == 4) throw CancellationException("cancel during copy")
            }
        }
        assertEquals(1L, fileCount(root.resolve("cache/share/ready")))
        assertEquals(0L, fileCount(root.resolve("cache/share/staging")))
        assertContentEquals(byteArrayOf(1, 2), Files.readAllBytes(granted.file))
        assertContentEquals(byteArrayOf(3, 4, 5, 6), Files.readAllBytes(candidate.finalPath))
    }

    @Test fun sourceReplacementAfterOpeningCannotRedirectTheCopy() = withRoot { root ->
        val entry = completed(root, "clip.mov", byteArrayOf(1, 2, 3, 4))
        val old = root.resolve("retained.mov")
        val replacement = root.resolve("replacement.mov")
        Files.write(replacement, byteArrayOf(9, 9, 9, 9))
        var checks = 0
        val result = stager(root).stage(entry, "clip.mov", "video/*") {
            checks += 1
            if (checks == 2) {
                Files.move(entry.finalPath, old)
                Files.createSymbolicLink(entry.finalPath, replacement)
            }
        }
        assertContentEquals(byteArrayOf(1, 2, 3, 4), Files.readAllBytes(result.file))
        assertContentEquals(byteArrayOf(1, 2, 3, 4), Files.readAllBytes(old))
        assertContentEquals(byteArrayOf(9, 9, 9, 9), Files.readAllBytes(replacement))
    }

    @Test fun symlinkAndWrongLengthPreparedExportsRefuseWithoutDeletingBorrowedFiles() = withRoot { root ->
        val original = root.resolve("export.mov")
        val symbolic = root.resolve("linked.mov")
        Files.write(original, byteArrayOf(7, 8, 9))
        Files.createSymbolicLink(symbolic, original)
        val stager = stager(root)
        assertFailsWith<InvalidMonitorMediaShareSourceException> {
            stager.stagePreparedArtifact(symbolic, 3, "linked.mov", "video/mp4")
        }
        assertFailsWith<InvalidMonitorMediaShareSourceException> {
            stager.stagePreparedArtifact(original, 4, "export.mov", "video/mp4")
        }
        assertEquals(0L, fileCount(root.resolve("cache/share/ready")))
        assertContentEquals(byteArrayOf(7, 8, 9), Files.readAllBytes(original))
    }

    @Test fun aDigestChangeCannotReuseAnEqualLengthGrant() = withRoot { root ->
        val entry = completed(root, "clip.mov", byteArrayOf(1, 2))
        val stager = stager(root)
        val first = stager.stage(entry, "clip.mov", "video/*")
        Files.write(entry.finalPath, byteArrayOf(8, 9))
        val second = stager.stage(entry, "clip.mov", "video/*")
        assertNotEquals(first.file, second.file)
        assertContentEquals(byteArrayOf(1, 2), Files.readAllBytes(first.file))
        assertContentEquals(byteArrayOf(8, 9), Files.readAllBytes(second.file))
    }

    @Test fun sameLengthMutationDuringCopyCannotPublishMixedContent() = withRoot { root ->
        val entry = completed(root, "mutable.mov", byteArrayOf(1, 2, 3, 4))
        var checks = 0
        assertFailsWith<InvalidMonitorMediaShareSourceException> {
            stager(root).stage(entry, "mutable.mov", "video/*") {
                checks += 1
                if (checks == 5) FileChannel.open(entry.finalPath, StandardOpenOption.WRITE).use {
                    it.write(ByteBuffer.wrap(byteArrayOf(9)))
                }
            }
        }
        assertEquals(0L, fileCount(root.resolve("cache/share/ready")))
        assertEquals(0L, fileCount(root.resolve("cache/share/staging")))
        assertContentEquals(byteArrayOf(9, 2, 3, 4), Files.readAllBytes(entry.finalPath))
    }

    @Test fun validCompleteContentChangedBeforeEntryRemainsShareable() = withRoot { root ->
        val entry = completed(root, "revised.mov", byteArrayOf(1, 2))
        Files.write(entry.finalPath, byteArrayOf(8, 9))
        val result = stager(root).stage(entry, "revised.mov", "video/*")
        assertContentEquals(byteArrayOf(8, 9), Files.readAllBytes(result.file))
    }

    @Test fun capacityRefusesActiveGrantsAndReclaimsOnlyAtTheSuppliedExpiry() = withRoot { root ->
        var now = 100L
        val stager = stager(root, bytes = 4, count = 1, retention = 24L * 60L * 60L * 1000L) { now }
        val first = completed(root, "first.mov", byteArrayOf(1, 2, 3, 4))
        val next = completed(root, "next.mov", byteArrayOf(5, 6, 7, 8))
        val granted = stager.stage(first, "first.mov", "video/*")
        now += 24L * 60L * 60L * 1000L - 1
        assertFailsWith<MonitorMediaShareCacheLimitException> {
            stager.stage(next, "next.mov", "video/*")
        }
        assertTrue(Files.exists(granted.file))
        now += 1
        val successor = stager.stage(next, "next.mov", "video/*")
        assertFalse(Files.exists(granted.file))
        assertContentEquals(byteArrayOf(5, 6, 7, 8), Files.readAllBytes(successor.file))
        assertContentEquals(byteArrayOf(1, 2, 3, 4), Files.readAllBytes(first.finalPath))
    }

    @Test fun regrantExtendsRetentionWithoutGrowingTheReadyCache() = withRoot { root ->
        var now = 10L
        val stager = stager(root, bytes = 2, count = 1, retention = 20) { now }
        val entry = completed(root, "clip.mov", byteArrayOf(1, 2))
        val next = completed(root, "next.mov", byteArrayOf(3, 4))
        val first = stager.stage(entry, "clip.mov", "video/*")
        now = 29
        val reused = stager.stage(entry, "clip.mov", "video/*")
        assertEquals(first.file, reused.file)
        now = 30
        assertFailsWith<MonitorMediaShareCacheLimitException> {
            stager.stage(next, "next.mov", "video/*")
        }
        now = 49
        stager.stage(next, "next.mov", "video/*")
        assertEquals(1L, fileCount(root.resolve("cache/share/ready")))
    }

    @Test fun oneAndMixedManyIntentsKeepTheActualGrantAndStreamContract() = withRoot { root ->
        val video = MonitorStagedMediaShare(root.resolve("video.mov"), "video.mov", "video/*")
        val photo = MonitorStagedMediaShare(root.resolve("photo.jpg"), "photo.jpg", "image/*")
        val one = MonitorMediaShareIntentSpec.forShare(video, "Supplied media label")
        assertEquals("android.intent.action.SEND", one.action)
        assertEquals("video/*", one.mimeType)
        assertEquals("video.mov", one.clipDataLabel)
        assertEquals("Share video.mov", one.chooserTitle)
        assertTrue(one.streamExtraIncluded && one.grantsReadUriPermission)
        val many = MonitorMediaShareIntentSpec.forShares(listOf(video, photo), "Supplied media label")
        assertEquals("android.intent.action.SEND_MULTIPLE", many.action)
        assertEquals("*/*", many.mimeType)
        assertEquals("Supplied media label", many.clipDataLabel)
        assertEquals("Share 2 items", many.chooserTitle)
        assertTrue(many.streamExtraIncluded && many.grantsReadUriPermission)
    }

    private fun stager(
        root: Path, bytes: Long = 1_073_741_824L, count: Int = 8,
        retention: Long = 24L * 60L * 60L * 1000L, clock: () -> Long = { 100L },
    ): MonitorMediaShareStager = MonitorMediaShareStager(
        root.resolve("cache"), MonitorMediaShareStagingPolicy(bytes, count, retention, 2), clock,
    )

    private fun completed(root: Path, filename: String, bytes: ByteArray): ProgressiveMediaCacheEntry {
        val entry = ProgressiveMediaCache(root.resolve("source")).openEntry(
            "camera", ProgressiveMediaCacheIdentity(filename, filename), bytes.size.toLong(),
        )
        entry.append(0, bytes)
        entry.complete()
        return entry
    }

    private fun fileCount(root: Path): Long = Files.list(root).use { it.count() }

    private fun withRoot(body: (Path) -> Unit) {
        val root = Files.createTempDirectory("opencine-share-")
        try { body(root) }
        finally { Files.walk(root).use { it.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists) } }
    }
}
