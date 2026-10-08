package com.opencapture.opencine.media

import java.nio.channels.ClosedChannelException
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.Executors
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import kotlin.test.*

class ProgressiveMediaCacheTest {
    private val identity = ProgressiveMediaCacheIdentity("C0001.MOV", "volume\u0000object\u0000capture\u0000C0001.MOV")

    @Test fun purgeRetiresWriterBeforeSamePathIsReused() = withCache { _, cache ->
        val old = cache.openEntry("camera", identity, 4)
        old.append(0, byteArrayOf(1, 2))
        cache.purgeEntry("camera", identity)
        val current = cache.openEntry("camera", identity, 4)
        current.append(0, byteArrayOf(3, 4))
        assertEquals(old.partialPath, current.partialPath)
        assertFailsWith<ProgressiveMediaCacheStateException> { old.append(2, byteArrayOf(9, 9)) }
        assertFailsWith<ProgressiveMediaCacheStateException> { old.resume() }
        assertFailsWith<ProgressiveMediaCacheStateException> { old.complete() }
        current.append(2, byteArrayOf(5, 6))
        current.complete()
        assertContentEquals(byteArrayOf(3, 4, 5, 6), Files.readAllBytes(current.finalPath))
        assertSame(current, cache.completedEntryOrNull("camera", identity, 4))
    }

    @Test fun completedClearFencesOldEntryAndPreservesResumableTransfer() = withCache { root, cache ->
        val completed = cache.openEntry("camera", identity, 1)
        completed.append(0, byteArrayOf(1)); completed.complete()
        val partial = cache.openEntry("camera", ProgressiveMediaCacheIdentity("C0002.MOV", "second"), 2)
        partial.append(0, byteArrayOf(2))
        val foreign = root.resolve("operator-note"); Files.write(foreign, byteArrayOf(8))
        val result = cache.clearCompletedEntries()
        assertEquals(1, result.removedCompleteEntryCount)
        assertEquals(1, result.preservedIncompleteEntryCount)
        assertFailsWith<ProgressiveMediaCacheStateException> { completed.resume() }
        assertFailsWith<ProgressiveMediaCacheStateException> { completed.reader().openAt(0) }
        partial.append(1, byteArrayOf(3)); partial.complete()
        assertContentEquals(byteArrayOf(2, 3), Files.readAllBytes(partial.finalPath))
        assertContentEquals(byteArrayOf(8), Files.readAllBytes(foreign))
    }

    @Test fun readerCloseWakesWaitAndLeavesTransferWritable() = withCache { _, cache ->
        val entry = cache.openEntry("camera", identity, 3)
        val reader = entry.reader(); assertEquals(3L, reader.openAt(0))
        val executor = Executors.newSingleThreadExecutor()
        try {
            val pending = executor.submit<Int> { reader.read(ByteArray(3), 0, 3) }
            reader.close()
            val failure = assertFailsWith<ExecutionException> { pending.get(2, TimeUnit.SECONDS) }
            assertIs<ClosedChannelException>(failure.cause)
            assertEquals(ProgressiveMediaCacheState.ACTIVE, entry.state)
            entry.append(0, byteArrayOf(1, 2, 3)); entry.complete()
            entry.reader().use { current ->
                assertEquals(2L, current.openAt(1, 2))
                val bytes = ByteArray(3)
                assertEquals(2, current.read(bytes, 0, 3))
                assertContentEquals(byteArrayOf(2, 3, 0), bytes)
                assertEquals(-1, current.read(bytes, 0, 3))
            }
        } finally {
            reader.close()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(2, TimeUnit.SECONDS))
        }
    }

    private fun withCache(block: (Path, ProgressiveMediaCache) -> Unit) {
        val root = Files.createTempDirectory("opencine-progressive-")
        try { block(root, ProgressiveMediaCache(root)) }
        finally { Files.walk(root).use { it.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists) } }
    }
}
