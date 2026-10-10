package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeSamples
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class MonitorPlaybackScopeSessionTest {
    @Test fun heldSourceReadCannotPublishIntoReplacementItem() = runTest {
        val gate = CompletableDeferred<Unit>(); var started = false
        val clock = CompletableDeferred<Unit>()
        val session = MonitorPlaybackScopeSession<Int>(backgroundScope, 84, sleep = { clock.await() },
            derive = { _, value, _ -> ScopeAssistBundle(revision = value.toLong()) })
        try {
            val owner = UUID.randomUUID()
            session.synchronize(MonitorPlaybackItemToken(owner, 1), true, 1, read = {
                started = true; withContext(NonCancellable) { gate.await() }; MonitorPlaybackScopeFrame(1, ScopeSamples.EMPTY)
            }, ifCurrent = { true })
            runCurrent(); assertTrue(started)
            session.synchronize(MonitorPlaybackItemToken(owner, 2), true, 2,
                read = { MonitorPlaybackScopeFrame(2, ScopeSamples.EMPTY) }, ifCurrent = { true })
            runCurrent(); assertEquals(2L, session.bundle.value.revision)
            gate.complete(Unit); runCurrent(); assertEquals(2L, session.bundle.value.revision)
        } finally { session.close(); gate.complete(Unit); clock.complete(Unit) }
    }
    @Test fun heldDerivationCannotOverwriteNewCalibration() = runTest {
        val gate = CompletableDeferred<Unit>(); var started = false; val clock = CompletableDeferred<Unit>()
        val session = MonitorPlaybackScopeSession<Int>(backgroundScope, 84, sleep = { clock.await() }, derive = { _, value, _ ->
            if (value == 1) { started = true; withContext(NonCancellable) { gate.await() } }
            ScopeAssistBundle(revision = value.toLong())
        })
        try {
            val item = MonitorPlaybackItemToken(UUID.randomUUID(), 1)
            session.synchronize(item, true, 1, { MonitorPlaybackScopeFrame(1, ScopeSamples.EMPTY) }, { true })
            runCurrent(); assertTrue(started)
            session.synchronize(item, true, 2, { MonitorPlaybackScopeFrame(1, ScopeSamples.EMPTY) }, { true })
            runCurrent(); assertEquals(2L, session.bundle.value.revision)
            gate.complete(Unit); runCurrent(); assertEquals(2L, session.bundle.value.revision)
        } finally { session.close(); gate.complete(Unit); clock.complete(Unit) }
    }
    @Test fun sameNativePublicationDerivesOnceAndUsesOriginalCadence() = runTest {
        var reads = 0; val clocks = mutableListOf<CompletableDeferred<Unit>>()
        val session = MonitorPlaybackScopeSession<Int>(backgroundScope, 84, sleep = {
            assertEquals(84L, it); val clock = CompletableDeferred<Unit>(); clocks += clock; clock.await()
        }, derive = { _, _, previous -> ScopeAssistBundle(revision = previous.revision + 1) })
        try {
            session.synchronize(MonitorPlaybackItemToken(UUID.randomUUID(), 1), true, 1,
                { reads += 1; MonitorPlaybackScopeFrame(9, ScopeSamples.EMPTY) }, { true })
            runCurrent(); assertEquals(1, clocks.size); clocks[0].complete(Unit)
            runCurrent(); assertEquals(2, clocks.size); assertEquals(2, reads); assertEquals(1L, session.bundle.value.revision)
        } finally { session.close(); clocks.forEach { it.complete(Unit) } }
    }
    @Test fun admissionReentryClosesBeforeNativeRead() = runTest {
        var reads = 0
        val session = MonitorPlaybackScopeSession<Int>(backgroundScope, 84, derive = { _, _, _ -> ScopeAssistBundle(revision = 1) })
        session.synchronize(MonitorPlaybackItemToken(UUID.randomUUID(), 1), true, 1,
            { reads += 1; MonitorPlaybackScopeFrame(1, ScopeSamples.EMPTY) }, { session.close(); true })
        runCurrent(); assertEquals(0, reads); assertEquals(ScopeAssistBundle.EMPTY, session.bundle.value)
    }
    @Test fun closeDuringDerivationRetiresPublicationAndClock() = runTest {
        val gate = CompletableDeferred<Unit>(); var started = false; var clocks = 0
        val session = MonitorPlaybackScopeSession<Int>(backgroundScope, 84, sleep = { clocks += 1 }, derive = { _, _, _ ->
            started = true; withContext(NonCancellable) { gate.await() }; ScopeAssistBundle(revision = 9)
        })
        try {
            session.synchronize(MonitorPlaybackItemToken(UUID.randomUUID(), 1), true, 1,
                { MonitorPlaybackScopeFrame(1, ScopeSamples.EMPTY) }, { true })
            runCurrent(); assertTrue(started); session.close(); gate.complete(Unit); runCurrent()
            assertEquals(ScopeAssistBundle.EMPTY, session.bundle.value); assertEquals(0, clocks)
        } finally { session.close(); gate.complete(Unit) }
    }
}
