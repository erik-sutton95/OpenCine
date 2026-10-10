package com.opencapture.opencine.appkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.*

/** Swift mirror: MonitorSettingsCacheObservationTests. No wall clock or filesystem IO. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorSettingsCacheObservationTest {
    private val identity = MonitorSettingsCacheIdentity("cache", "source")
    private fun source(count: suspend () -> Long = { 0 }, clear: suspend () -> Unit = {},
        summary: (() -> String?)? = null, current: () -> Boolean = { true }) =
        MonitorSettingsCacheSource(identity, 0, current, count, clear, summary)

    @Test fun readFailureKeepsUnknownBytesAndExactReportedMessage() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope)
        model.refresh(source(count = { throw IllegalStateException("read denied") })); runCurrent()
        assertNull(model.state.value.bytes)
        assertTrue(model.state.value.readFailed)
        assertEquals("read denied", model.state.value.failure)
        model.refresh(source(count = { 0 })); runCurrent()
        assertEquals(0L, model.state.value.bytes)
        assertFalse(model.state.value.readFailed)
        assertNull(model.state.value.failure)
        model.retire()
    }

    @Test fun absentErrorMessageAndClearReceiptRemainUnknown() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope)
        model.refresh(source(count = { throw IllegalStateException() })); runCurrent()
        assertTrue(model.state.value.readFailed); assertNull(model.state.value.failure)
        model.refresh(source()); runCurrent()
        model.requestClear(); model.clear(); runCurrent()
        assertFalse(model.state.value.clearing); assertNull(model.state.value.clearSummary)
        assertEquals(0L, model.state.value.bytes)
        model.retire()
    }

    @Test fun successfulClearReportsNativeReceiptAndRecounts() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope)
        var counts = 0
        val receipt = "Removed 8 MB; kept 2 MB incomplete."
        model.refresh(source(count = { counts++; if (counts == 1) 10 else 2 }, summary = { receipt })); runCurrent()
        model.requestClear(); model.clear(); runCurrent()
        assertEquals(receipt, model.state.value.clearSummary)
        assertEquals(2L, model.state.value.bytes)
        assertEquals(2, counts)
        model.retire(); assertNull(model.state.value.clearSummary)
    }

    @Test fun replacementRejectsLateReadFailure() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope)
        val reply = CompletableDeferred<Long>()
        model.refresh(source(count = { withContext(NonCancellable) { reply.await() } })); runCurrent()
        model.refresh(source(count = { 7 })); runCurrent()
        reply.completeExceptionally(IllegalStateException("retired read")); runCurrent()
        assertEquals(7L, model.state.value.bytes)
        assertFalse(model.state.value.readFailed); assertNull(model.state.value.failure)
        model.retire()
    }

    @Test fun summaryReplacementCannotPublishOrRecountSuccessor() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope)
        var successorCounts = 0
        val successor = source(count = { successorCounts++; 11 })
        model.refresh(source(count = { 8 }, summary = { model.refresh(successor); "retired receipt" })); runCurrent()
        model.requestClear(); model.clear(); runCurrent()
        assertEquals(11L, model.state.value.bytes)
        assertEquals(1, successorCounts)
        assertNull(model.state.value.clearSummary)
        assertFalse(model.state.value.clearing)
        model.retire()
    }

    @Test fun predicateReplacementBeforeClearRefusesOldIO() = runTest {
        for (answer in listOf(false, true)) {
            val model = MonitorSettingsCacheModel(backgroundScope)
            var replace = false; var oldClears = 0
            val successor = source(count = { 13 })
            model.refresh(source(count = { 8 }, clear = { oldClears++ }, current = {
                if (replace) { replace = false; model.refresh(successor); answer } else true
            })); runCurrent()
            model.requestClear(); replace = true; model.clear(); runCurrent()
            assertEquals(0, oldClears)
            assertEquals(13L, model.state.value.bytes)
            assertFalse(model.state.value.clearing)
            model.retire()
        }
    }

    @Test fun synchronousCountPublicationPreservesSuccessor() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope)
        var replaced = false; var successorCounts = 0
        val successor = source(count = { successorCounts++; 19 })
        val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            model.state.collect { value ->
                if (value.bytes == 8L && !replaced) { replaced = true; model.refresh(successor) }
            }
        }
        model.refresh(source(count = { 8 })); runCurrent()
        assertEquals(19L, model.state.value.bytes)
        assertEquals(1, successorCounts)
        observer.cancel(); model.retire()
    }

    @Test fun synchronousClearFinishPreservesSuccessorTask() = runTest {
        val model = MonitorSettingsCacheModel(backgroundScope)
        var sawClear = false; var replaced = false; var successorCounts = 0
        val successor = source(count = { successorCounts++; 23 })
        val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            model.state.collect { value ->
                if (value.clearing) sawClear = true
                if (sawClear && !value.clearing && !replaced) { replaced = true; model.refresh(successor) }
            }
        }
        model.refresh(source(count = { 8 })); runCurrent()
        model.requestClear(); model.clear(); runCurrent()
        assertEquals(23L, model.state.value.bytes)
        assertEquals(1, successorCounts)
        assertNull(model.state.value.clearSummary)
        observer.cancel(); model.retire()
    }
}
