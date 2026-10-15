package com.opencapture.opencine.dji

import com.opencapture.opencine.platform.withCredentialIO
import com.opencapture.opencine.platform.CallbackOperationOwner
import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain

/** SIMULATED secure-store callbacks at the exact coroutine frontier used by PocketCameraSession.
 * Real owned Main/IO executors and the existing CallbackOperationOwner fence progress/cancellation.
 * No Android Keystore, camera, network, sleeps or credentials from the developer machine.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class CameraCredentialSchedulingTest {
    private class Gate {
        val entered = CountDownLatch(1)
        private val released = CountDownLatch(1)
        fun block() {
            entered.countDown()
            check(released.await(5, TimeUnit.SECONDS)) { "SIMULATED store gate was not released" }
        }
        fun awaitEntry() = assertTrue(entered.await(2, TimeUnit.SECONDS), "store did not enter")
        fun release() { released.countDown() }
    }

    private class Store(private val gate: Gate) {
        val reads = AtomicInteger()
        val saves = AtomicInteger()
        val removals = AtomicInteger()
        fun load(): Pair<String, String> {
            reads.incrementAndGet()
            gate.block()
            return "SIMULATED-camera" to "synthetic-secret"
        }
        fun save() { gate.block(); saves.incrementAndGet() }
        fun remove() { gate.block(); removals.incrementAndGet() }
    }

    private class Fixture : Closeable {
        val mainExecutor = Executors.newSingleThreadExecutor()
        val ioExecutor = Executors.newSingleThreadExecutor()
        val main = mainExecutor.asCoroutineDispatcher()
        val io = ioExecutor.asCoroutineDispatcher()
        val source = CallbackOperationOwner<Any>()
        val resource = Any()
        val first = source.begin().also { source.attach(it, resource) }
        val current = { source.runIfCurrent(first, resource) {} }
        private val gates = mutableListOf<Gate>()
        init { Dispatchers.setMain(main) }
        fun gate(): Gate = Gate().also { gates += it }
        fun mainProgress(scope: CoroutineScope): Boolean {
            val advanced = CountDownLatch(1)
            scope.launch(Dispatchers.Main.immediate) { advanced.countDown() }
            return advanced.await(1, TimeUnit.SECONDS)
        }
        fun releaseAll() { gates.forEach { it.release() } }
        override fun close() {
            releaseAll()
            Dispatchers.resetMain()
            main.close(); io.close()
            mainExecutor.shutdownNow(); ioExecutor.shutdownNow()
            check(mainExecutor.awaitTermination(2, TimeUnit.SECONDS))
            check(ioExecutor.awaitTermination(2, TimeUnit.SECONDS))
        }
    }

    private fun scenario(block: suspend CoroutineScope.(Fixture) -> Unit) {
        Fixture().use { fixture ->
            runBlocking {
                try { block(fixture) }
                finally { fixture.releaseAll() }
            }
        }
    }

    @Test fun blockedLoadLeavesMainFreeAndReturnsTheSameCredentials() = scenario { fixture ->
        val gate = fixture.gate()
        val store = Store(gate)
        val published = AtomicReference<Pair<String, String>?>(null)
        val network = AtomicInteger()
        val connection = launch(Dispatchers.Main.immediate) {
            val credentials = withCredentialIO(fixture.current, fixture.io) { store.load() }
            published.set(credentials)
            network.incrementAndGet()
        }
        gate.awaitEntry()
        val progressed = fixture.mainProgress(this)
        gate.release()
        connection.join()
        assertTrue(progressed, "secure load blocked the Main scheduler")
        assertEquals("SIMULATED-camera" to "synthetic-secret", published.get())
        assertEquals(1, store.reads.get())
        assertEquals(1, network.get())
    }

    @Test fun canceledBlockedReadCannotPublishCacheOrStartNetwork() = scenario { fixture ->
        val gate = fixture.gate()
        val store = Store(gate)
        val published = AtomicReference<Pair<String, String>?>(null)
        val cacheWrites = AtomicInteger()
        val network = AtomicInteger()
        val connection = launch(Dispatchers.Main.immediate) {
            val credentials = withCredentialIO(fixture.current, fixture.io) { store.load() }
            published.set(credentials)
            withCredentialIO(fixture.current, fixture.io) { cacheWrites.incrementAndGet() }
            network.incrementAndGet()
        }
        gate.awaitEntry()
        connection.cancel()
        val progressed = fixture.mainProgress(this)
        gate.release()
        connection.join()
        assertTrue(progressed)
        assertTrue(connection.isCancelled)
        assertNull(published.get())
        assertEquals(0, cacheWrites.get())
        assertEquals(0, network.get())
        assertEquals(1, store.reads.get(), "entered secure read keeps its own completion")
    }

    @Test fun sourceABACannotResumeTheOldConnectionOrBorrowSuccessorCredentials() = scenario { fixture ->
        val gate = fixture.gate()
        val store = Store(gate)
        val oldPublished = AtomicReference<Pair<String, String>?>(null)
        val oldCache = AtomicInteger()
        val oldNetwork = AtomicInteger()
        val old = launch(Dispatchers.Main.immediate) {
            val credentials = withCredentialIO(fixture.current, fixture.io) { store.load() }
            oldPublished.set(credentials)
            withCredentialIO(fixture.current, fixture.io) { oldCache.incrementAndGet() }
            oldNetwork.incrementAndGet()
        }
        gate.awaitEntry()
        // Same resource reused after A/B/A still has a different native callback token.
        fixture.source.begin().also { fixture.source.attach(it, Any()) }
        val successor = fixture.source.begin().also { fixture.source.attach(it, fixture.resource) }
        val successorCurrent = { fixture.source.runIfCurrent(successor, fixture.resource) {} }
        val nextPublished = AtomicReference<Pair<String, String>?>(null)
        val nextNetwork = AtomicInteger()
        val next = launch(Dispatchers.Main.immediate) {
            val credentials = withCredentialIO(successorCurrent, Dispatchers.IO) {
                "SIMULATED-camera" to "successor-secret"
            }
            nextPublished.set(credentials)
            nextNetwork.incrementAndGet()
        }
        assertTrue(fixture.mainProgress(this), "successor Main work must not wait for old secure read")
        next.join()
        gate.release()
        old.join()
        assertTrue(old.isCancelled)
        assertNull(oldPublished.get())
        assertEquals(0, oldCache.get())
        assertEquals(0, oldNetwork.get())
        assertEquals("SIMULATED-camera" to "successor-secret", nextPublished.get())
        assertEquals(1, nextNetwork.get())
        assertTrue(successorCurrent())
    }

    @Test fun retiredGattResourceRefusesPublicationWithoutJobCancellation() = scenario { fixture ->
        val gate = fixture.gate()
        val store = Store(gate)
        val published = AtomicInteger()
        val connection = launch(Dispatchers.Main.immediate) {
            withCredentialIO(fixture.current, fixture.io) { store.load() }
            published.incrementAndGet()
        }
        gate.awaitEntry()
        fixture.source.runIfCurrent(fixture.first) { fixture.source.detach(fixture.first) }
        assertFalse(fixture.current())
        gate.release()
        connection.join()
        assertTrue(connection.isCancelled)
        assertEquals(0, published.get())
    }

    @Test fun secureSaveAndRemoveBothLeaveMainFree() {
        for (save in listOf(true, false)) scenario { fixture ->
            val gate = fixture.gate()
            val store = Store(gate)
            val connection = launch(Dispatchers.Main.immediate) {
                withCredentialIO(fixture.current, fixture.io) {
                    if (save) store.save() else store.remove()
                }
            }
            gate.awaitEntry()
            val progressed = fixture.mainProgress(this)
            gate.release()
            connection.join()
            assertTrue(progressed, "secure mutation blocked Main")
            assertEquals(if (save) 1 else 0, store.saves.get())
            assertEquals(if (save) 0 else 1, store.removals.get())
        }
    }

    @Test fun canceledQueuedOperationNeverEntersSecureStorage() = scenario { fixture ->
        val blocker = fixture.gate()
        val ioHeld = launch(fixture.io) { blocker.block() }
        blocker.awaitEntry()
        val beforeDispatch = CountDownLatch(1)
        val reads = AtomicInteger()
        val connection = launch(Dispatchers.Main.immediate) {
            beforeDispatch.countDown()
            withCredentialIO(fixture.current, fixture.io) { reads.incrementAndGet() }
        }
        assertTrue(beforeDispatch.await(2, TimeUnit.SECONDS))
        val progressed = fixture.mainProgress(this)
        connection.cancel()
        blocker.release()
        ioHeld.join(); connection.join()
        assertTrue(progressed, "Main must yield while secure work waits for IO")
        assertTrue(connection.isCancelled)
        assertEquals(0, reads.get())
    }

    @Test fun expiredQueuedSourceNeverEntersSecureStorage() = scenario { fixture ->
        val blocker = fixture.gate()
        val ioHeld = launch(fixture.io) { blocker.block() }
        blocker.awaitEntry()
        val beforeDispatch = CountDownLatch(1)
        val writes = AtomicInteger()
        val connection = launch(Dispatchers.Main.immediate) {
            beforeDispatch.countDown()
            withCredentialIO(fixture.current, fixture.io) { writes.incrementAndGet() }
        }
        assertTrue(beforeDispatch.await(2, TimeUnit.SECONDS))
        val progressed = fixture.mainProgress(this)
        fixture.source.begin() // native retirement without canceling the connection Job
        blocker.release()
        ioHeld.join(); connection.join()
        assertTrue(progressed)
        assertTrue(connection.isCancelled)
        assertEquals(0, writes.get())
    }

    @Test fun enteredMutationCompletesButRetiredCallerCannotContinue() = scenario { fixture ->
        val gate = fixture.gate()
        val store = Store(gate)
        val network = AtomicInteger()
        val connection = launch(Dispatchers.Main.immediate) {
            withCredentialIO(fixture.current, fixture.io) { store.save() }
            network.incrementAndGet()
        }
        gate.awaitEntry()
        fixture.source.begin()
        connection.cancel()
        gate.release()
        connection.join()
        assertEquals(1, store.saves.get(), "entered secure transaction is not rolled back")
        assertEquals(0, network.get())
    }

    @Test fun missingCredentialsAndStoreFailureRetainTheirOriginalMeaning() = scenario { fixture ->
        val missing = async(Dispatchers.Main.immediate) {
            withCredentialIO<Pair<String, String>?>(fixture.current, fixture.io) { null }
        }
        assertNull(missing.await())
        supervisorScope {
            val failed = async(Dispatchers.Main.immediate) {
                withCredentialIO(fixture.current, fixture.io) { throw IllegalStateException("SIMULATED unavailable") }
            }
            val error = try { failed.await(); null } catch (error: IllegalStateException) { error }
            assertEquals("SIMULATED unavailable", error?.message)
        }
        assertTrue(fixture.current())
    }
}
