package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MediaTransferReceipt
import kotlinx.coroutines.test.runTest
import java.io.File
import java.util.UUID
import kotlin.test.*

class MonitorMediaCacheTest {
    private fun directory(): Pair<File, MonitorMediaCacheDirectory> {
        val parent = File(System.getProperty("java.io.tmpdir"), "opencine-cache-${UUID.randomUUID()}")
        return parent to MonitorMediaCacheDirectory(File(parent, "camera"))
    }
    @Test fun clearRetiresOldWriterBeforeNewRootCommit() = runTest {
        val (parent, directory) = directory()
        try {
            directory.write("{\"unknown\":19}".toByteArray(), "index.json")
            val old = directory.beginWrite("files/take.mov"); old.write(byteArrayOf(1))
            directory.clear(listOf("index.json"))
            val current = directory.beginWrite("files/take.mov"); current.write(byteArrayOf(2, 3))
            val committed = current.commit(MediaTransferReceipt(2))
            assertEquals(MonitorMediaCacheFailure.RETIRED, assertFailsWith<MonitorMediaCacheException> { old.write(byteArrayOf(4)) }.failure)
            assertEquals(MonitorMediaCacheFailure.RETIRED, assertFailsWith<MonitorMediaCacheException> { old.commit(MediaTransferReceipt(1)) }.failure)
            old.abort()
            assertContentEquals(byteArrayOf(2, 3), committed.readBytes())
            assertEquals("{\"unknown\":19}", directory.read("index.json").decodeToString())
        } finally { parent.deleteRecursively() }
    }
    @Test fun replacementAtSameDestinationRejectsOldCommitAndFinally() = runTest {
        val (parent, directory) = directory()
        try {
            val old = directory.beginWrite("files/take.mov"); old.write(byteArrayOf(1))
            val current = directory.beginWrite("files/take.mov"); current.write(byteArrayOf(2))
            val file = current.commit(MediaTransferReceipt(1))
            assertEquals(MonitorMediaCacheFailure.RETIRED, assertFailsWith<MonitorMediaCacheException> { old.commit(MediaTransferReceipt(1)) }.failure)
            old.abort(); assertContentEquals(byteArrayOf(2), file.readBytes())
        } finally { parent.deleteRecursively() }
    }
    @Test fun originalEligibilityPreservesNinetyPercentVersusExactSize() {
        val apple = MonitorMediaOriginalEligibility.MinimumFraction(9, 10)
        assertFalse(apple.accepts(89, 100)); assertTrue(apple.accepts(90, 100)); assertTrue(apple.accepts(91, 100))
        assertFalse(MonitorMediaOriginalEligibility.ExactSize.accepts(99, 100))
        assertTrue(MonitorMediaOriginalEligibility.ExactSize.accepts(100, 100))
        assertFalse(MonitorMediaOriginalEligibility.ExactSize.accepts(101, 100))
        assertTrue(apple.accepts(1, null)); assertFalse(apple.accepts(0, null)); assertTrue(apple.accepts(Long.MAX_VALUE, Long.MAX_VALUE))
    }
    @Test fun invalidReceiptCannotPublishStagedBytes() = runTest {
        val (parent, directory) = directory()
        try {
            val writer = directory.beginWrite("files/take.mov"); writer.write(byteArrayOf(1, 2))
            assertEquals(MonitorMediaCacheFailure.INVALID_RECEIPT, assertFailsWith<MonitorMediaCacheException> { writer.commit(MediaTransferReceipt(4)) }.failure)
            writer.abort(); assertNull(directory.existing("files/take.mov")); assertEquals(0L, directory.totalByteCount())
        } finally { parent.deleteRecursively() }
    }
    @Test fun explicitAddressCannotEscapeTheOwnedRoot() {
        val (parent, directory) = directory()
        try {
            for (address in listOf("../other", "/other", "files/../other", "files\\other", "")) {
                assertEquals(MonitorMediaCacheFailure.INVALID_ADDRESS, assertFailsWith<MonitorMediaCacheException> { directory.beginWrite(address) }.failure)
            }
        } finally { parent.deleteRecursively() }
    }
}
