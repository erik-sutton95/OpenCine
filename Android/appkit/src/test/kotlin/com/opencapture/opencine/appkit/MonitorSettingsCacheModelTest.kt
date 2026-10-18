package com.opencapture.opencine.appkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.*

/** Swift mirror: MonitorSettingsCacheModelTests; deliberate replies after cancellation. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorSettingsCacheModelTest {
    private class IO {
        val counts = mutableListOf<CompletableDeferred<Long>>()
        val clears = mutableListOf<CompletableDeferred<Unit>>()
        var current = true
        fun source(identity: MonitorSettingsCacheIdentity, revision: Long = 0) = MonitorSettingsCacheSource(
            identity, revision, { current },
            { withContext(NonCancellable) { CompletableDeferred<Long>().also { counts += it }.await() } },
            { withContext(NonCancellable) { CompletableDeferred<Unit>().also { clears += it }.await() } },
        )
    }
    @Test fun currentEmptyCacheIsKnownZero() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope); val io = IO()
        model.refresh(io.source(MonitorSettingsCacheIdentity("original-cache", null))); runCurrent()
        assertNull(model.state.value.bytes)
        io.counts[0].complete(0); runCurrent(); assertEquals(0L, model.state.value.bytes)
        model.retire()
    }
    @Test fun replacementRejectsOldCount() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope); val first = IO(); val next = IO()
        model.refresh(first.source(MonitorSettingsCacheIdentity("A", "first"))); runCurrent()
        model.refresh(next.source(MonitorSettingsCacheIdentity("B", "next"))); runCurrent()
        first.counts[0].complete(99); runCurrent(); assertNull(model.state.value.bytes)
        next.counts[0].complete(7); runCurrent(); assertEquals(7L, model.state.value.bytes)
        model.retire()
    }
    @Test fun revisionRefreshRejectsOldCountInSameNamespace() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope); val io = IO()
        val id = MonitorSettingsCacheIdentity("A", "first")
        model.refresh(io.source(id)); runCurrent()
        model.refresh(io.source(id, 1)); runCurrent()
        io.counts[1].complete(8); runCurrent(); io.counts[0].complete(99); runCurrent()
        assertEquals(8L, model.state.value.bytes); model.retire()
    }
    @Test fun lostAuthorityAndReplacementRetireCapturedConfirmation() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope); val io = IO()
        model.refresh(io.source(MonitorSettingsCacheIdentity("A", "first"))); runCurrent()
        io.counts[0].complete(9); runCurrent()
        model.requestClear(); assertTrue(model.state.value.confirmationPresented)
        io.current = false; model.clear(); assertFalse(model.state.value.clearing); assertTrue(io.clears.isEmpty())
        io.current = true; model.requestClear()
        model.refresh(io.source(MonitorSettingsCacheIdentity("A", "replacement"))); runCurrent()
        model.clear(); assertTrue(io.clears.isEmpty()); assertFalse(model.state.value.confirmationPresented)
        io.counts[1].complete(9); model.retire(); runCurrent()
    }
    @Test fun disappearedThenReenteredCacheRejectsLateClearFailure() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope); val io = IO()
        val id = MonitorSettingsCacheIdentity("A", "first")
        model.refresh(io.source(id)); runCurrent(); io.counts[0].complete(9); runCurrent()
        model.requestClear(); model.clear(); runCurrent(); assertEquals(1, io.clears.size)
        model.retire(); model.refresh(io.source(id)); runCurrent()
        io.counts[1].complete(3); io.clears[0].completeExceptionally(IllegalStateException("captured IO failed")); runCurrent()
        assertEquals(3L, model.state.value.bytes); assertFalse(model.state.value.clearFailed); assertFalse(model.state.value.clearing)
        model.retire()
    }
    @Test fun cancellingConfirmationSendsNoIOAndClearRunsOnce() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope); val io = IO()
        model.refresh(io.source(MonitorSettingsCacheIdentity("A", null))); runCurrent(); io.counts[0].complete(8); runCurrent()
        model.requestClear(); model.cancelConfirmation(); model.clear(); assertTrue(io.clears.isEmpty())
        model.requestClear(); model.clear(); model.requestClear(); model.clear(); runCurrent()
        assertEquals(1, io.clears.size)
        io.clears[0].completeExceptionally(IllegalStateException("captured IO failed")); runCurrent()
        assertTrue(model.state.value.clearFailed); assertFalse(model.state.value.clearing)
        io.counts.drop(1).forEach { it.complete(8) }; runCurrent()
        model.retire(); assertFalse(model.state.value.clearFailed)
    }
    @Test fun failedClearRecountsRemainingBytesAndRetainsTheFailure() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope); val io = IO()
        model.refresh(io.source(MonitorSettingsCacheIdentity("original-cache", "first"))); runCurrent()
        io.counts[0].complete(800); runCurrent()
        model.requestClear(); model.clear(); runCurrent()
        io.clears[0].completeExceptionally(IllegalStateException("remaining bucket failed")); runCurrent()
        try {
            assertEquals(2, io.counts.size)
            assertTrue(model.state.value.clearFailed); assertNull(model.state.value.bytes)
            assertEquals("remaining bucket failed", model.state.value.failure)
            io.counts[1].complete(300); runCurrent()
            assertEquals(300L, model.state.value.bytes)
            assertTrue(model.state.value.clearFailed)
            assertEquals("remaining bucket failed", model.state.value.failure)
        } finally { io.counts.drop(1).forEach { it.complete(300) }; model.retire() }
    }

    @Test fun successfulClearRecountsTheCapturedNamespaceWithoutAContentReport() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope); val io = IO()
        model.refresh(io.source(MonitorSettingsCacheIdentity("original-cache", "first"))); runCurrent()
        io.counts[0].complete(800); runCurrent(); assertEquals(800L, model.state.value.bytes)
        model.requestClear(); model.clear(); runCurrent(); assertEquals(1, io.clears.size)
        io.clears[0].complete(Unit); runCurrent(); assertEquals(2, io.counts.size)
        assertFalse(model.state.value.clearing); assertNull(model.state.value.bytes)
        io.counts[1].complete(0); runCurrent(); assertEquals(0L, model.state.value.bytes)
        model.retire()
    }
}
