package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MediaTransferReceipt
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.runBlocking
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.io.File
import java.nio.file.Path
import java.nio.file.Files
import java.util.Collections
import java.util.UUID
import kotlin.test.*

class MonitorMediaCacheTest {
    @Test fun heldRealWriteDoesNotBlockAdmissionOrSuccessorRetire() = runTest {
        heldRealWriteDoesNotBlockAdmissionOrSuccessor(CacheWriterRetirement.RETIRE)
    }
    @Test fun heldRealWriteDoesNotBlockAdmissionOrSuccessorReplace() = runTest {
        heldRealWriteDoesNotBlockAdmissionOrSuccessor(CacheWriterRetirement.REPLACE)
    }
    @Test fun heldRealWriteDoesNotBlockAdmissionOrSuccessorAbort() = runTest {
        heldRealWriteDoesNotBlockAdmissionOrSuccessor(CacheWriterRetirement.ABORT)
    }
    @Test fun heldRealWriteDoesNotBlockAdmissionOrSuccessorClear() = runTest {
        heldRealWriteDoesNotBlockAdmissionOrSuccessor(CacheWriterRetirement.CLEAR)
    }
    private suspend fun heldRealWriteDoesNotBlockAdmissionOrSuccessor(retirement: CacheWriterRetirement) {
        val (parent, directory) = directory()
        val control = ControlledCacheWrite()
        val worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "opencine-cache-test-write").apply { isDaemon = true }
        }
        var old: MonitorMediaCacheWrite? = null
        var successor: MonitorMediaCacheWrite? = null
        try {
            val metadata = "{\"unknown\":19}".toByteArray()
            directory.write(metadata, "index.json")
            directory.write(byteArrayOf(42), "camera-object.part")
            val generation = directory.generation
            val captured = directory.beginWrite("files/take.mov", control::write)
            old = captured
            val operation = worker.submit<Unit> { runBlocking { captured.write(byteArrayOf(1, 2)) } }
            assertTrue(control.waitUntilEntered())
            // RED waits here for the independent controller. GREEN must finish admission
            // AND publish the exact successor before the held FileOutputStream can write.
            assertEquals(generation, directory.generation)
            when (retirement) {
                CacheWriterRetirement.RETIRE -> directory.retireWrites()
                CacheWriterRetirement.REPLACE -> Unit
                CacheWriterRetirement.ABORT -> captured.abort()
                CacheWriterRetirement.CLEAR -> directory.clear(listOf("index.json", "camera-object.part", "files"))
            }
            if (retirement == CacheWriterRetirement.RETIRE || retirement == CacheWriterRetirement.CLEAR) assertNotEquals(generation, directory.generation)
            val current = directory.beginWrite("files/take.mov")
            successor = current
            current.write(byteArrayOf(7, 8, 9))
            val committed = current.commit(MediaTransferReceipt(3))
            assertTrue(control.admissionFinishedBeforeRelease())
            val rejected = assertIs<MonitorMediaCacheException>(
                assertFailsWith<ExecutionException> { operation.get(5, TimeUnit.SECONDS) }.cause)
            assertEquals(MonitorMediaCacheFailure.RETIRED, rejected.failure)
            assertEquals(MonitorMediaCacheFailure.RETIRED,
                assertFailsWith<MonitorMediaCacheException> { captured.commit(MediaTransferReceipt(2)) }.failure)
            captured.abort()
            assertContentEquals(byteArrayOf(7, 8, 9), committed.readBytes())
            assertContentEquals(metadata, directory.read("index.json"))
            assertContentEquals(byteArrayOf(42), directory.read("camera-object.part"))
            assertEquals(listOf("take.mov"), File(directory.root, "files").list()?.toList())
            assertFalse(control.hitFailureDeadline)
        } finally {
            control.release(); old?.abort(); successor?.abort()
            worker.shutdown()
            assertTrue(worker.awaitTermination(5, TimeUnit.SECONDS))
            parent.deleteRecursively()
        }
    }

    @Test fun retirementScanningChecksOwnershipBeforeMetadata() = runTest {
        val parent = Files.createTempDirectory("opencine-retirement-metadata-").toFile()
        try {
            val unrelated = setOf("other", ".clearing-camera-invalid", ".clearing-camera-extra-${UUID.randomUUID()}")
            val lookups = Collections.synchronizedList(mutableListOf<String>())
            val observedParent = object : File(parent.path) {
                override fun listFiles(): Array<File>? = super.listFiles()?.map { child ->
                    object : File(child.path) {
                        override fun toPath(): Path {
                            if (name in unrelated) lookups.add(path)
                            return super.toPath()
                        }
                    }
                }?.toTypedArray()
            }
            val root = object : File(parent, "camera") {
                override fun getParentFile(): File = observedParent
            }
            val directory = MonitorMediaCacheDirectory(root)
            val prepared = File(parent, ".clearing-camera-${UUID.randomUUID()}")
            val unprepared = File(parent, ".retiring-camera-${UUID.randomUUID()}")
            for ((location, count) in listOf(root to 2, prepared to 3, unprepared to 5)) {
                assertTrue(location.mkdirs())
                File(location, "take.mov").writeBytes(ByteArray(count) { 1 })
            }
            unrelated.forEach { assertTrue(File(parent, it).mkdirs()) }
            val linked = File(parent, ".clearing-camera-${UUID.randomUUID()}")
            Files.createSymbolicLink(linked.toPath(), File(parent, "other").toPath())
            assertEquals(10L, directory.totalByteCount())
            assertTrue(lookups.isEmpty(), "Accounting must reject unrelated names before metadata: $lookups")
            directory.clear(emptyList())
            assertTrue(lookups.isEmpty(), "Clear must reject unrelated names before metadata: $lookups")
            assertFalse(prepared.exists())
            assertContentEquals(ByteArray(5) { 1 }, File(unprepared, "take.mov").readBytes())
            assertEquals(File(parent, "other").toPath(), Files.readSymbolicLink(linked.toPath()))
            unrelated.forEach { assertTrue(File(parent, it).isDirectory) }
        } finally { parent.deleteRecursively() }
    }

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

private enum class CacheWriterRetirement { RETIRE, REPLACE, ABORT, CLEAR }
// This is a real FileOutputStream write, paused only at its internal operation seam.
// The independent deadline releases RED/teardown. Success depends on ordering, not time.
private class ControlledCacheWrite {
    private val state = Any()
    private val entered = CountDownLatch(1)
    private val release = CountDownLatch(1)
    private val admitted = CountDownLatch(1)
    private var released = false
    private var deadlineHit = false
    init {
        Thread({
            val finished = admitted.await(5, TimeUnit.SECONDS)
            synchronized(state) {
                deadlineHit = !finished
                released = true
                release.countDown()
            }
        }, "opencine-cache-test-controller").apply { isDaemon = true }.start()
    }
    fun write(stream: FileOutputStream, bytes: ByteArray) {
        entered.countDown()
        release.await()
        stream.write(bytes)
    }
    fun waitUntilEntered(): Boolean = entered.await(5, TimeUnit.SECONDS)
    fun admissionFinishedBeforeRelease(): Boolean = synchronized(state) {
        val ordered = entered.count == 0L && !released
        admitted.countDown()
        ordered
    }
    val hitFailureDeadline: Boolean get() = synchronized(state) { deadlineHit }
    fun release() = synchronized(state) {
        released = true; release.countDown(); admitted.countDown()
    }
}
