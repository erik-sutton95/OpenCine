package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MediaTransferReceipt
import kotlinx.coroutines.test.runTest
import java.io.File
import java.util.UUID
import kotlin.test.*

class MonitorMediaCacheTest {
    @Test fun retiringWritesPreservesResumableFilesAndFencesOldFinally() = runTest {
        val (parent, directory) = directory()
        try {
            directory.root.mkdirs()
            val partial = File(directory.root, "camera-object.part")
            partial.writeBytes(byteArrayOf(8, 9))
            val old = directory.beginWrite("take.mov"); old.write(byteArrayOf(1))
            val generation = directory.generation
            directory.retireWrites()
            assertNotEquals(generation, directory.generation)
            val current = directory.beginWrite("take.mov"); current.write(byteArrayOf(2, 3))
            val committed = current.commit(MediaTransferReceipt(2))
            assertEquals(MonitorMediaCacheFailure.RETIRED, assertFailsWith<MonitorMediaCacheException> { old.commit(MediaTransferReceipt(1)) }.failure)
            old.abort()
            assertContentEquals(byteArrayOf(2, 3), committed.readBytes())
            assertContentEquals(byteArrayOf(8, 9), partial.readBytes())
        } finally { parent.deleteRecursively() }
    }
    private fun directory(): Pair<File, MonitorMediaCacheDirectory> {
        val parent = File(System.getProperty("java.io.tmpdir"), "opencine-cache-${UUID.randomUUID()}")
        return parent to MonitorMediaCacheDirectory(File(parent, "camera"))
    }
    private data class RetirementFixture(
        val parent: File, val ownPrepared: File, val ownUnprepared: File,
        val siblingPrepared: File, val siblingUnprepared: File,
        val own: MonitorMediaCacheDirectory, val sibling: MonitorMediaCacheDirectory,
    )
    private fun retirementFixture(): RetirementFixture {
        val (parent, own) = directory()
        val sibling = MonitorMediaCacheDirectory(File(parent, "camera-extra"))
        val ownPrepared = File(parent, ".clearing-camera-${UUID.randomUUID()}")
        val ownUnprepared = File(parent, ".retiring-camera-${UUID.randomUUID()}")
        val siblingPrepared = File(parent, ".clearing-camera-extra-${UUID.randomUUID()}")
        val siblingUnprepared = File(parent, ".retiring-camera-extra-${UUID.randomUUID()}")
        for ((root, count) in listOf(own.root to 2, ownPrepared to 7, ownUnprepared to 5,
            sibling.root to 17, siblingPrepared to 11, siblingUnprepared to 13)) {
            check(root.mkdirs()); File(root, "take.mov").writeBytes(ByteArray(count) { count.toByte() })
        }
        return RetirementFixture(parent, ownPrepared, ownUnprepared, siblingPrepared, siblingUnprepared, own, sibling)
    }
    @Test fun prefixOverlappingRootsDoNotShareRetiredByteCounts() = runTest {
        val fixture = retirementFixture()
        try {
            assertEquals(14L, fixture.own.totalByteCount())
            assertEquals(41L, fixture.sibling.totalByteCount())
        } finally { fixture.parent.deleteRecursively() }
    }
    @Test fun clearPreservesPrefixOverlappingRetiredRoots() = runTest {
        val fixture = retirementFixture()
        try {
            fixture.own.clear(emptyList())
            assertFalse(fixture.ownPrepared.exists())
            assertContentEquals(ByteArray(5) { 5 }, File(fixture.ownUnprepared, "take.mov").readBytes())
            assertContentEquals(ByteArray(17) { 17 }, File(fixture.sibling.root, "take.mov").readBytes())
            assertTrue(fixture.siblingPrepared.exists(), "Sibling prepared retirement must remain")
            assertContentEquals(ByteArray(11) { 11 }, File(fixture.siblingPrepared, "take.mov").readBytes())
            assertContentEquals(ByteArray(13) { 13 }, File(fixture.siblingUnprepared, "take.mov").readBytes())
            assertEquals(5L, fixture.own.totalByteCount())
            assertEquals(41L, fixture.sibling.totalByteCount())
        } finally { fixture.parent.deleteRecursively() }
    }
    @Test fun unrecognizedRetirementNamesRemainOutsideOwnedCache() = runTest {
        val (parent, directory) = directory()
        try {
            val names = listOf(".clearing-camera-retry", ".retiring-camera-1-1-1-1-1",
                ".clearing-camera-${UUID.randomUUID()}-extra")
            for (name in names) {
                val root = File(parent, name); check(root.mkdirs())
                File(root, "take.mov").writeBytes(byteArrayOf(1, 2, 3))
            }
            assertEquals(0L, directory.totalByteCount())
            directory.clear(emptyList())
            for (name in names) assertContentEquals(byteArrayOf(1, 2, 3), File(File(parent, name), "take.mov").readBytes())
        } finally { parent.deleteRecursively() }
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
