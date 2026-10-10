package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MonitorMediaReturnSession
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlin.test.*

private class MediaReturnGate {
    var entered = 0
    var returned = 0
    private val pending = mutableListOf<Continuation<Unit>>()
    suspend fun wait() { entered += 1; suspendCoroutine<Unit> { pending.add(it) }; returned += 1 }
    fun release() { val held = pending.toList(); pending.clear(); held.forEach { it.resume(Unit) } }
}
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaReturnSessionTest {
    @Test fun explicitReturnCompletesOneAdmittedClaim() = runTest {
        val session = MonitorMediaReturnSession(backgroundScope); val gate = MediaReturnGate()
        try {
            var completions = 0
            val token = session.start({ true }, { gate.wait() }, { completions += 1 })
            assertEquals(1L, token); assertTrue(session.pending)
            runCurrent(); assertEquals(1, gate.entered)
            gate.release(); runCurrent()
            assertFalse(session.pending); assertEquals(1, completions); assertEquals(token, session.generation)
        } finally { session.cancel(); gate.release() }
    }
    @Test fun cancelBeforeDispatchSendsNoClaim() = runTest {
        val session = MonitorMediaReturnSession(backgroundScope); var claims = 0
        session.start({ true }, { claims += 1 }); val retired = session.task
        session.cancel(); runCurrent(); retired?.join()
        assertEquals(0, claims); assertFalse(session.pending); assertEquals(2L, session.generation)
    }
    @Test fun lateCompletionCannotClearSuccessorClaim() = runTest {
        val session = MonitorMediaReturnSession(backgroundScope); val old = MediaReturnGate(); val fresh = MediaReturnGate()
        try {
            var oldCompleted = 0; var freshCompleted = 0
            session.start({ true }, { old.wait() }, { oldCompleted += 1 }); runCurrent(); assertEquals(1, old.entered)
            val outgoing = session.task
            session.start({ true }, { fresh.wait() }, { freshCompleted += 1 }); runCurrent(); assertEquals(1, fresh.entered)
            old.release(); runCurrent(); outgoing?.join()
            assertTrue(session.pending); assertEquals(0, oldCompleted); assertEquals(0, freshCompleted)
            fresh.release(); runCurrent(); assertFalse(session.pending); assertEquals(1, freshCompleted)
        } finally { session.cancel(); old.release(); fresh.release() }
    }
    @Test fun sourceReentryDuringClaimSuppressesCompletion() = runTest {
        val session = MonitorMediaReturnSession(backgroundScope); val gate = MediaReturnGate()
        try {
            var current = true; var completions = 0
            session.start({ current }, { gate.wait() }, { completions += 1 }); runCurrent(); assertEquals(1, gate.entered)
            val outgoing = session.task
            current = false; gate.release(); runCurrent(); outgoing?.join()
            assertFalse(session.pending); assertEquals(0, completions)
        } finally { session.cancel(); gate.release() }
    }
    @Test fun absentAdmissionAdvancesIntentWithoutPendingTask() = runTest {
        val session = MonitorMediaReturnSession(backgroundScope); var claims = 0
        session.start({ false }, { claims += 1 }); session.start({ false }, { claims += 1 })
        assertEquals(2L, session.generation); assertFalse(session.pending); assertEquals(0, claims)
    }
    @Test fun predicateReentryCannotDispatchOutgoingClaim() = runTest {
        val session = MonitorMediaReturnSession(backgroundScope); var reads = 0; var old = 0; var fresh = 0
        session.start({
            reads += 1
            if (reads == 2) session.start({ true }, { fresh += 1 })
            true
        }, { old += 1 })
        runCurrent()
        assertFalse(session.pending); assertEquals(0, old); assertEquals(1, fresh); assertEquals(2L, session.generation)
    }
    @Test fun directTaskCancellationClearsPendingGate() = runTest {
        val session = MonitorMediaReturnSession(backgroundScope); var claims = 0
        session.start({ true }, { claims += 1 }); val task = session.task
        task?.cancel(); runCurrent(); task?.join()
        assertFalse(session.pending); assertEquals(0, claims); assertEquals(1L, session.generation)
    }
    @Test fun repeatedStartRetiresPreviousBeforeDispatch() = runTest {
        val session = MonitorMediaReturnSession(backgroundScope); var old = 0; var fresh = 0
        session.start({ true }, { old += 1 }); val retired = session.task
        session.start({ true }, { fresh += 1 }); runCurrent(); retired?.join()
        assertFalse(session.pending); assertEquals(0, old); assertEquals(1, fresh); assertEquals(2L, session.generation)
    }
}
