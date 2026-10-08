package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MonitorAudioMeterChannel
import com.opencapture.opencine.media.MonitorAudioMeterLevels
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.*
import kotlinx.coroutines.withContext
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorPlaybackAudioSessionTest {
    private fun token() = MonitorPlaybackItemToken(UUID.randomUUID(), 1L)
    private fun levels(db: Double) = MonitorAudioMeterLevels(
        MonitorAudioMeterChannel(db, db), MonitorAudioMeterChannel(db, db))

    @Test fun manualClockKeepsTheOriginalCadenceAndUnknownInput() = runTest {
        val times = mutableListOf<Pair<Double, Boolean>>()
        var reset = 0
        val audio = MonitorPlaybackAudioSession(backgroundScope,
            read = { elapsed, muted -> times += elapsed to muted; null }, reset = { reset += 1 },
            now = { testScheduler.currentTime * 1_000_000L })
        audio.synchronize(token(), visible = true, outputMuted = false) { true }
        runCurrent(); advanceTimeBy(41); runCurrent(); assertTrue(times.isEmpty())
        advanceTimeBy(1); runCurrent()
        assertEquals(listOf(0.042 to false), times); assertNull(audio.levels.value)
        audio.close(); assertEquals(2, reset)
    }

    @Test fun HidingTheMeterCancelsRealPollingAndShowingItRetainsConformMute() = runTest {
        var reads = 0
        val audio = MonitorPlaybackAudioSession(backgroundScope,
            read = { _, muted -> reads += 1; if (muted) null else levels(-12.0) }, reset = {},
            now = { testScheduler.currentTime * 1_000_000L })
        val item = token()
        audio.synchronize(item, visible = true, outputMuted = false) { true }
        runCurrent(); advanceTimeBy(42); runCurrent(); assertEquals(levels(-12.0), audio.levels.value)
        audio.synchronize(item, visible = false, outputMuted = false) { true }
        assertNull(audio.levels.value); advanceTimeBy(420); runCurrent(); assertEquals(1, reads)
        audio.synchronize(item, visible = true, outputMuted = true) { true }
        runCurrent(); advanceTimeBy(42); runCurrent(); assertEquals(2, reads); assertNull(audio.levels.value)
        audio.close(); advanceTimeBy(420); runCurrent(); assertEquals(2, reads)
    }

    @Test fun SourcePredicateSuccessorCannotBeOverwrittenWhetherItReturnsFalseOrTrue() = runTest {
        for (result in listOf(false, true)) {
            lateinit var audio: MonitorPlaybackAudioSession
            val successor = token()
            var resets = 0
            audio = MonitorPlaybackAudioSession(backgroundScope, read = { _, _ -> levels(-6.0) },
                reset = { resets += 1 }, now = { testScheduler.currentTime * 1_000_000L })
            audio.synchronize(token(), visible = true, outputMuted = false) {
                audio.synchronize(successor, visible = true, outputMuted = false) { true }
                result
            }
            runCurrent(); advanceTimeBy(42); runCurrent()
            assertEquals(1, resets); assertEquals(levels(-6.0), audio.levels.value)
            audio.close()
        }
    }

    @Test fun TickPredicateReentryCannotCancelTheSuccessorWhetherFalseOrTrue() = runTest {
        for (result in listOf(false, true)) {
            lateinit var audio: MonitorPlaybackAudioSession
            val successor = token()
            var armed = false; var fired = false; var reads = 0
            audio = MonitorPlaybackAudioSession(backgroundScope, read = { _, _ -> reads += 1; levels(-9.0) },
                reset = {}, now = { testScheduler.currentTime * 1_000_000L })
            audio.synchronize(token(), visible = true, outputMuted = false) {
                if (armed && !fired) {
                    fired = true
                    audio.synchronize(successor, visible = true, outputMuted = false) { true }
                    result
                } else true
            }
            runCurrent(); armed = true; advanceTimeBy(42); runCurrent()
            assertTrue(fired); assertEquals(0, reads); assertNull(audio.levels.value)
            advanceTimeBy(42); runCurrent(); assertEquals(1, reads); assertEquals(levels(-9.0), audio.levels.value)
            audio.close()
        }
    }

    @Test fun NativeReadReentryCannotPublishOutgoingLevels() = runTest {
        lateinit var audio: MonitorPlaybackAudioSession
        val successor = token(); var reads = 0
        audio = MonitorPlaybackAudioSession(backgroundScope, read = { _, _ ->
            reads += 1
            if (reads == 1) {
                audio.synchronize(successor, visible = true, outputMuted = false) { true }
                levels(-3.0)
            } else levels(-18.0)
        }, reset = {}, now = { testScheduler.currentTime * 1_000_000L })
        audio.synchronize(token(), visible = true, outputMuted = false) { true }
        runCurrent(); advanceTimeBy(42); runCurrent(); assertNull(audio.levels.value)
        advanceTimeBy(42); runCurrent(); assertEquals(levels(-18.0), audio.levels.value)
        audio.close()
    }

    @Test fun RetiredUncancellableWaitCannotReadOrClearSuccessorLevels() = runTest {
        val oldWait = CompletableDeferred<Unit>(); var waits = 0; var reads = 0
        val audio = MonitorPlaybackAudioSession(backgroundScope, read = { _, _ -> reads += 1; levels(-15.0) },
            reset = {}, now = { testScheduler.currentTime * 1_000_000L }, sleep = { milliseconds ->
                waits += 1
                if (waits == 1) withContext(NonCancellable) { oldWait.await() } else delay(milliseconds)
            })
        audio.synchronize(token(), visible = true, outputMuted = false) { true }; runCurrent()
        audio.synchronize(token(), visible = true, outputMuted = false) { true }; runCurrent()
        advanceTimeBy(42); runCurrent(); assertEquals(1, reads); assertEquals(levels(-15.0), audio.levels.value)
        oldWait.complete(Unit); runCurrent(); assertEquals(1, reads); assertEquals(levels(-15.0), audio.levels.value)
        audio.close()
    }
}
