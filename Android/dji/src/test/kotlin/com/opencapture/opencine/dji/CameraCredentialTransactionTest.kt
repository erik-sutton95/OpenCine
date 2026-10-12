package com.opencapture.opencine.dji

import com.opencapture.opencine.platform.withCredentialIO
import com.opencapture.opencine.platform.CallbackOperationOwner
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.FoundCamera
import java.io.Closeable
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext

/** SIMULATED complete two-key store transactions through the actual session IO frontier.
 * Latches reproduce held migration/read/error work; no Keystore, camera, network or sleeps.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class CameraCredentialTransactionTest {
    private class Gate {
        val entered = CountDownLatch(1)
        private val released = CountDownLatch(1)
        fun block() {
            entered.countDown()
            check(released.await(5, TimeUnit.SECONDS)) { "SIMULATED gate was not released" }
        }
        fun awaitEntry() = assertTrue(entered.await(2, TimeUnit.SECONDS))
        fun release() { released.countDown() }
    }

    private class Fixture : Closeable {
        private val mainExecutor = Executors.newSingleThreadExecutor()
        private val ioExecutor = Executors.newFixedThreadPool(2)
        val main = mainExecutor.asCoroutineDispatcher()
        val io = ioExecutor.asCoroutineDispatcher()
        val transaction = Mutex()
        val source = CallbackOperationOwner<Any>()
        val resource = Any()
        val first = source.begin().also { source.attach(it, resource) }
        val current = { source.runIfCurrent(first, resource) {} }
        private val gates = mutableListOf<Gate>()
        init { Dispatchers.setMain(main) }
        fun gate() = Gate().also { gates += it }
        fun successor(): () -> Boolean {
            val next = source.begin().also { source.attach(it, resource) }
            return { source.runIfCurrent(next, resource) {} }
        }
        fun mainProgress(scope: CoroutineScope): Boolean {
            val advanced = CountDownLatch(1)
            scope.launch(Dispatchers.Main.immediate) { advanced.countDown() }
            return advanced.await(1, TimeUnit.SECONDS)
        }
        suspend fun ioProgress() { withContext(io) {} }
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

    private class Port : DjiConnectPort {
        override val found = MutableStateFlow<List<FoundCamera>>(emptyList())
        override val phaseFlow = MutableStateFlow(ConnectionPhase.IDLE)
        override val setupProgress = MutableStateFlow<String?>(null)
        override val failureDetail = MutableStateFlow<ConnectionFailure?>(null)
        override val joinedSSID: String? = null
        override val control: CameraSession = FakeCameraSession.djiLike()
        override fun startScan() = Unit
        override fun stopScan() = Unit
        override fun useSetup(setup: CameraConnectionSetup, network: MultiviewNetworkStore.Network?, restoreAccessPoint: Boolean) = Unit
        override fun reconnect(id: String) = Unit
        override fun disconnect() = Unit
    }
    private val saved = SavedCamera(
        "SIMULATED-camera", DjiCameraSessionAdapter.INTEGRATION,
        advertisedName = "SIMULATED-camera", model = "Osmo Pocket 3",
    )

    private fun scenario(block: suspend CoroutineScope.(Fixture) -> Unit) {
        Fixture().use { fixture ->
            runBlocking {
                try { block(fixture) }
                finally { fixture.releaseAll() }
            }
        }
    }

    @Test fun enteredMigrationCannotOverwriteSuccessorKnownCredentials() = scenario { fixture ->
        val gate = fixture.gate()
        val stored = AtomicReference("old-ssid" to "old-plaintext")
        val published = AtomicInteger()
        val successorWrites = AtomicInteger()
        val old = launch(Dispatchers.Main.immediate) {
            withCredentialIO(fixture.current, fixture.io, fixture.transaction) {
                val ssid = stored.get().first
                val password = stored.get().second
                // Existing decryptOrMigrate rereads SSID, then save may block in seal.
                val migrationSSID = stored.get().first
                gate.block()
                stored.set(migrationSSID to "sealed:$password")
                ssid to password
            }
            published.incrementAndGet()
        }
        gate.awaitEntry()
        val successorCurrent = fixture.successor()
        val next = launch(Dispatchers.Main.immediate) {
            withCredentialIO(successorCurrent, fixture.io, fixture.transaction) {
                successorWrites.incrementAndGet()
                stored.set("new-ssid" to "sealed:new-secret")
            }
        }
        val progressed = fixture.mainProgress(this)
        fixture.ioProgress()
        val writesBeforeRelease = successorWrites.get()
        gate.release(); old.join(); next.join()
        assertTrue(progressed)
        assertEquals(0, writesBeforeRelease)
        assertTrue(old.isCancelled)
        assertEquals(0, published.get())
        assertEquals("new-ssid" to "sealed:new-secret", stored.get())
        assertEquals(1, successorWrites.get())
    }

    @Test fun serializedLoadCannotMixTwoDifferentSavedPairs() = scenario { fixture ->
        val gate = fixture.gate()
        val stored = AtomicReference("old-ssid" to "old-secret")
        val read = async(Dispatchers.Main.immediate) {
            withCredentialIO(fixture.current, fixture.io, fixture.transaction) {
                val ssid = stored.get().first
                gate.block()
                ssid to stored.get().second
            }
        }
        gate.awaitEntry()
        val write = launch(Dispatchers.Main.immediate) {
            withCredentialIO(fixture.current, fixture.io, fixture.transaction) {
                stored.set("new-ssid" to "new-secret")
            }
        }
        val progressed = fixture.mainProgress(this)
        fixture.ioProgress()
        val beforeRelease = stored.get()
        gate.release()
        val loaded = read.await(); write.join()
        assertTrue(progressed)
        assertEquals("old-ssid" to "old-secret", beforeRelease)
        assertEquals("old-ssid" to "old-secret", loaded)
        assertEquals("new-ssid" to "new-secret", stored.get())
    }

    @Test fun queuedCanceledOrRetiredSaveAndRemoveNeverEnterStorage() {
        for (cancel in listOf(false, true)) for (remove in listOf(false, true)) scenario { fixture ->
            fixture.transaction.lock()
            val requested = CountDownLatch(1)
            val writes = AtomicInteger()
            val removals = AtomicInteger()
            val current = { requested.countDown(); fixture.current() }
            val waiting = launch(Dispatchers.Main.immediate) {
                withCredentialIO(current, fixture.io, fixture.transaction) {
                    if (remove) removals.incrementAndGet() else writes.incrementAndGet()
                }
            }
            val progressed: Boolean
            try {
                assertTrue(requested.await(2, TimeUnit.SECONDS))
                progressed = fixture.mainProgress(this)
                if (cancel) waiting.cancel() else fixture.source.begin()
            } finally {
                fixture.transaction.unlock()
            }
            waiting.join()
            assertTrue(progressed)
            assertTrue(waiting.isCancelled)
            assertEquals(0, writes.get())
            assertEquals(0, removals.get())
            assertFalse(fixture.transaction.isLocked)
        }
    }

    @Test fun actualIntegrationForgetJoinsMigrationBeforeSuccessorSave() = scenario { fixture ->
        val gate = fixture.gate()
        val stored = AtomicReference<Pair<String, String>?>("old-ssid" to "old-plaintext")
        val events = ConcurrentLinkedQueue<String>()
        val old = launch(Dispatchers.Main.immediate) {
            withCredentialIO(fixture.current, fixture.io, fixture.transaction) {
                val snapshot = checkNotNull(stored.get())
                gate.block()
                stored.set(snapshot.first to "sealed:${snapshot.second}")
                events += "old-migrated"
            }
        }
        gate.awaitEntry()
        val successorCurrent = fixture.successor()
        val integration = DjiIntegration(Port(), forgetCredentialsAsync = {
            withCredentialIO({ true }, fixture.io, fixture.transaction) {
                stored.set(null)
                events += "forgotten"
            }
        })
        val forget = launch(Dispatchers.Main.immediate) { integration.forget(saved) }
        assertTrue(fixture.mainProgress(this)) // forget has queued on the held Mutex before successor
        val next = launch(Dispatchers.Main.immediate) {
            withCredentialIO(successorCurrent, fixture.io, fixture.transaction) {
                stored.set("new-ssid" to "sealed:new-secret")
                events += "successor-saved"
            }
        }
        val progressed = fixture.mainProgress(this)
        fixture.ioProgress()
        val beforeRelease = events.toList()
        gate.release(); old.join(); forget.join(); next.join()
        assertTrue(progressed)
        assertEquals(emptyList(), beforeRelease)
        assertTrue(old.isCancelled)
        assertFalse(forget.isCancelled, "forget owns its caller Job rather than the retired GATT attempt")
        assertEquals(listOf("old-migrated", "forgotten", "successor-saved"), events.toList())
        assertEquals("new-ssid" to "sealed:new-secret", stored.get())
    }

    @Test fun canceledActualForgetNeverRemovesSuccessorCredentials() = scenario { fixture ->
        fixture.transaction.lock()
        val stored = AtomicReference("old-ssid" to "old-secret")
        val removals = AtomicInteger()
        val integration = DjiIntegration(Port(), forgetCredentialsAsync = {
            withCredentialIO({ true }, fixture.io, fixture.transaction) {
                removals.incrementAndGet()
                stored.set("removed" to "removed")
            }
        })
        val forget = launch(Dispatchers.Main.immediate) { integration.forget(saved) }
        val progressed: Boolean
        try {
            progressed = fixture.mainProgress(this)
            forget.cancel()
            stored.set("new-ssid" to "new-secret")
        } finally {
            fixture.transaction.unlock()
        }
        forget.join()
        assertTrue(progressed)
        assertTrue(forget.isCancelled)
        assertEquals(0, removals.get())
        assertEquals("new-ssid" to "new-secret", stored.get())
    }

    @Test fun admittedStoreFailureReleasesTransactionAndLeavesMainFree() = scenario { fixture ->
        supervisorScope {
            val gate = fixture.gate()
            val failed = async(Dispatchers.Main.immediate) {
                withCredentialIO<Unit>(fixture.current, fixture.io, fixture.transaction) {
                    gate.block()
                    error("SIMULATED unavailable")
                }
            }
            gate.awaitEntry()
            val progressed = fixture.mainProgress(this)
            gate.release()
            val failure = try { failed.await(); null } catch (error: IllegalStateException) { error }
            assertTrue(progressed)
            assertEquals("SIMULATED unavailable", failure?.message)
            assertFalse(fixture.transaction.isLocked)
            val next = async(Dispatchers.Main.immediate) {
                withCredentialIO(fixture.current, fixture.io, fixture.transaction) { "same-secret" }
            }
            assertEquals("same-secret", next.await())
        }
    }

    @Test fun existingPlainFunctionValueForgetKeepsItsOriginalContract() = scenario { _ ->
        val forgotten = mutableListOf<String>()
        val direct: (String) -> Unit = { forgotten += it }
        DjiIntegration(Port(), forgetCredentials = direct).forget(saved)
        assertEquals(listOf(saved.id), forgotten)
    }

    @Test fun legacyTrailingAndPositionalClockConstructorsKeepTheirBehavior() = scenario { _ ->
        val port = Port().also { it.phaseFlow.value = ConnectionPhase.LIVE }
        val reads = AtomicInteger()
        val expectedNow = 1_759_307_200_123L
        val trailing = DjiIntegration(port) { reads.incrementAndGet(); expectedNow }
        val forgotten = mutableListOf<String>()
        val direct: (String) -> Unit = { forgotten += it }
        val load: (String, Boolean) -> MultiviewNetworkStore.Network? = { _, _ -> null }
        val save: (String, String, Boolean) -> Unit = { _, _, _ -> }
        val clock: () -> Long = { reads.incrementAndGet(); expectedNow }
        val positional = DjiIntegration(port, load, save, direct, clock)
        val target = ConnectTarget.Nearby(NearbyCamera(
            saved.id, name = saved.advertisedName, model = saved.model,
            routes = setOf(com.opencapture.opencine.core.RouteKind.CAMERA_ACCESS_POINT),
        ))
        for (integration in listOf(trailing, positional)) {
            val events = withContext(Dispatchers.Main.immediate) { integration.connect(target).toList() }
            val connected = assertIs<ConnectionEvent.Connected>(events.single())
            assertEquals(expectedNow, connected.camera.saved.lastConnected)
        }
        assertEquals(2, reads.get(), "the legacy trailing clock runs once per actual connection record")
        positional.forget(saved)
        assertEquals(listOf(saved.id), forgotten)
        assertEquals(2, reads.get(), "forget must not reinterpret the clock as an async callback")
        val legacy = listOf(
            DjiConnectPort::class.java.name,
            "kotlin.jvm.functions.Function2",
            "kotlin.jvm.functions.Function3",
            "kotlin.jvm.functions.Function1",
            "kotlin.jvm.functions.Function0",
        )
        val signatures = DjiIntegration::class.java.declaredConstructors.map { constructor ->
            constructor.parameterTypes.map { it.name }
        }
        assertTrue(legacy in signatures, "original JVM five-argument constructor must remain")
        assertTrue(legacy + listOf("int", "kotlin.jvm.internal.DefaultConstructorMarker") in signatures,
            "original Kotlin default-argument JVM constructor must remain")
    }
}
