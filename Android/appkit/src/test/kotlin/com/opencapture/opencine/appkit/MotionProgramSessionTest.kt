package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.motion.GimbalProgram
import com.opencapture.opencine.motion.GimbalWaypoint
import com.opencapture.opencine.motion.MotionAxis
import com.opencapture.opencine.motion.MotionBounds
import com.opencapture.opencine.motion.MotionCapabilities
import com.opencapture.opencine.motion.MotionProgramTiming
import com.opencapture.opencine.motion.MotionReferenceFrame
import com.opencapture.opencine.motion.MotionService
import com.opencapture.opencine.motion.MotionTarget
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/** Swift MotionProgramSessionTests: same scenarios on the real coroutine owner and a manual clock. */
@OptIn(ExperimentalCoroutinesApi::class)
class MotionProgramSessionTest {
    private val timing = MotionProgramTiming(3.seconds, 33.milliseconds)
    private fun program(offset: Double = 0.0, loop: Boolean = false) = GimbalProgram(
        a = GimbalWaypoint(offset, 0.0, 1.0), b = GimbalWaypoint(offset + 20, 0.0, 1.0), durationAB = 2.0, loop = loop)
    private fun TestScope.owner(clock: ProgramClock) = MotionProgramSession(backgroundScope,
        now = { clock.instant }, sleep = { clock.sleep(it) })

    @Test fun countdownCancelHasNoFutureTargetOrStopCommand() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val motion = ProgramMotion()
        assertTrue(move.start(program(), MotionProgramSession.Source(motion) { true }, timing)); runCurrent()
        assertEquals(1, motion.moves.size); assertEquals(1, clock.pending)
        assertEquals(3, move.state.value.progress.countdown); assertNotNull(move.state.value.operation)
        move.cancel(); clock.advance(100.seconds); runCurrent()
        assertEquals(0, clock.pending); assertEquals(1, motion.moves.size); assertEquals(0, motion.stops)
        assertEquals(MotionProgramSession.State(), move.state.value)
    }

    @Test fun disconnectDuringMoveRetiresItsBudget() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val motion = ProgramMotion(); var current = true
        assertTrue(move.start(program(), MotionProgramSession.Source(motion) { current }, timing)); runCurrent()
        clock.advance(3.seconds); runCurrent()
        assertTrue(move.state.value.progress.canPause); assertEquals(2, motion.moves.size)
        current = false
        val count = motion.moves.size; clock.advance(33.milliseconds); runCurrent()
        assertFalse(move.state.value.progress.running); assertNull(move.state.value.operation)
        assertEquals(count, motion.moves.size); assertEquals(0, motion.stops)
    }

    @Test fun backgroundForegroundDoesNotRestartRetiredTake() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val motion = ProgramMotion(); var current = true
        val binding = MotionProgramSession.Source(motion) { current }
        assertTrue(move.start(program(), binding, timing)); runCurrent()
        current = false; clock.advance(33.milliseconds); runCurrent()
        assertNull(move.state.value.operation)
        current = true; clock.advance(100.seconds); runCurrent()
        assertFalse(move.state.value.progress.running); assertEquals(1, motion.moves.size); assertEquals(0, motion.stops)
        assertTrue(move.start(program(), binding, timing)); runCurrent(); assertEquals(2, motion.moves.size)
        move.cancel(); clock.advance(100.seconds); runCurrent()
    }

    @Test fun pauseResumeBudgetExcludesPausedWallTime() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val motion = ProgramMotion()
        assertTrue(move.start(program(), MotionProgramSession.Source(motion) { true }, timing)); runCurrent()
        assertFalse(move.pause()); clock.advance(3.seconds); runCurrent()
        clock.advance(500.milliseconds); runCurrent()
        assertTrue(move.pause()); assertTrue(abs(move.state.value.progress.elapsed - 0.5) < 1e-9)
        val count = motion.moves.size; clock.advance(100.seconds); runCurrent()
        assertEquals(count, motion.moves.size); assertTrue(move.state.value.progress.paused)
        assertTrue(move.resume()); clock.advance(250.milliseconds); runCurrent()
        assertEquals(count + 1, motion.moves.size); assertTrue(abs(move.state.value.progress.elapsed - 0.75) < 1e-9)
        clock.advance(1300.milliseconds); runCurrent()
        assertNull(move.state.value.operation); assertFalse(move.state.value.progress.running)
        assertEquals(20.0, motion.moves.last().yawDeg)
        assertEquals(1, motion.moves.count { it.yawDeg == 20.0 })
    }

    @Test fun loopEndAndLateTickKeepTheDeclaredDirection() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val motion = ProgramMotion()
        assertTrue(move.start(program(loop = true), MotionProgramSession.Source(motion) { true }, timing)); runCurrent()
        clock.advance(5.seconds); runCurrent()
        assertEquals(20.0, motion.moves.last().yawDeg); assertTrue(move.state.value.progress.reversing)
        clock.advance(2.seconds); runCurrent()
        assertEquals(0.0, motion.moves.last().yawDeg); assertFalse(move.state.value.progress.reversing)
        clock.advance(5.seconds); runCurrent()
        assertEquals(10.0, motion.moves.last().yawDeg); assertFalse(move.state.value.progress.reversing)
        move.cancel(); clock.advance(100.seconds); runCurrent()
    }

    @Test fun replacementRejectsOldReplyAndQueuedTarget() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val old = ProgramMotion(); val next = ProgramMotion()
        old.delaysReplies = true; var current = true
        assertTrue(move.start(program(loop = true), MotionProgramSession.Source(old) { current }, timing)); runCurrent()
        assertEquals(1, old.pending); assertEquals(1, clock.pending)
        val first = move.state.value.operation; current = false
        assertTrue(move.start(program(40.0), MotionProgramSession.Source(next) { true }, timing)); runCurrent()
        val successor = move.state.value.operation; assertNotEquals(first, successor)
        old.reply(false); runCurrent(); clock.advance(3.seconds); runCurrent()
        assertEquals(successor, move.state.value.operation); assertNull(move.state.value.failure)
        assertEquals(1, old.moves.size); assertEquals(2, next.moves.size)
        assertTrue(next.moves.all { it.yawDeg >= 40.0 })
        move.cancel(); clock.advance(100.seconds); runCurrent()
    }

    @Test fun repeatedStartCannotCompleteTheSuccessor() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val motion = ProgramMotion(); motion.delaysReplies = true
        val source = MotionProgramSession.Source(motion) { true }
        assertTrue(move.start(program(), source, timing)); runCurrent()
        val first = move.state.value.operation
        assertTrue(move.start(program(40.0), source, timing)); runCurrent()
        val successor = move.state.value.operation; assertEquals(2, motion.pending)
        motion.reply(false); runCurrent()
        assertNotEquals(first, successor); assertEquals(successor, move.state.value.operation)
        assertNull(move.state.value.failure)
        move.cancel(); motion.reply(true); clock.advance(100.seconds); runCurrent()
    }

    @Test fun sameSourceReentryIgnoresOldReply() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val motion = ProgramMotion(); motion.delaysReplies = true
        var epoch = 1
        assertTrue(move.start(program(), MotionProgramSession.Source(motion) { epoch == 1 }, timing)); runCurrent()
        epoch = 2
        assertTrue(move.start(program(40.0), MotionProgramSession.Source(motion) { epoch == 2 }, timing)); runCurrent()
        val successor = move.state.value.operation
        motion.reply(false); runCurrent()
        assertEquals(successor, move.state.value.operation); assertNull(move.state.value.failure)
        move.cancel(); motion.reply(true); clock.advance(100.seconds); runCurrent()
    }

    @Test fun reentrantPresentationCanReplaceBeforeFirstDispatch() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val old = ProgramMotion(); val next = ProgramMotion()
        var replaced = false
        move.onChange = { state ->
            if (!replaced && state.operation != null) {
                replaced = true
                move.start(program(40.0), MotionProgramSession.Source(next) { true }, timing)
            }
        }
        assertTrue(move.start(program(), MotionProgramSession.Source(old) { true }, timing)); runCurrent()
        assertTrue(old.moves.isEmpty()); assertEquals(40.0, next.moves.single().yawDeg)
        move.cancel(); clock.advance(100.seconds); runCurrent()
    }

    @Test fun targetRepliesDoNotThrottleTheDeclaredCadence() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val motion = ProgramMotion(); motion.delaysReplies = true
        assertTrue(move.start(program(), MotionProgramSession.Source(motion) { true }, timing)); runCurrent()
        clock.advance(3.seconds); runCurrent(); assertEquals(2, motion.pending)
        for (count in 3..7) {
            clock.advance(33.milliseconds); runCurrent(); assertEquals(count, motion.pending)
        }
        assertTrue(abs(move.state.value.progress.elapsed - 0.165) < 1e-9)
        move.cancel(); while (motion.pending > 0) motion.reply(true)
        clock.advance(100.seconds); runCurrent()
    }

    @Test fun rejectedTargetIsVisibleAndStopsFutureDispatch() = runTest {
        val clock = ProgramClock(); val move = owner(clock); val motion = ProgramMotion(); motion.accepts = false
        assertTrue(move.start(program(), MotionProgramSession.Source(motion) { true }, timing)); runCurrent()
        assertEquals(MotionProgramSession.Failure.COMMAND_REJECTED, move.state.value.failure)
        clock.advance(100.seconds); runCurrent()
        assertEquals(1, motion.moves.size); assertFalse(move.state.value.progress.running)
        assertNull(move.state.value.operation)
    }
    @Test fun sourcePredicateReplacementDuringPulseReturningFalse() = runTest {
        predicateReplacementDuringPulse(returning = false)
    }
    @Test fun sourcePredicateReplacementDuringPulseReturningTrue() = runTest {
        predicateReplacementDuringPulse(returning = true)
    }
    @Test fun sourcePredicateReplacementDuringReplyReturningFalse() = runTest {
        predicateReplacementDuringReply(returning = false)
    }
    @Test fun sourcePredicateReplacementDuringReplyReturningTrue() = runTest {
        predicateReplacementDuringReply(returning = true)
    }

    private fun TestScope.predicateReplacementDuringPulse(returning: Boolean) {
        val clock = ProgramClock(); val move = owner(clock); val old = ProgramMotion(); val next = ProgramMotion()
        var replaceOnCheck = false
        var successor: OperationID? = null
        var successorStarted = false
        val publications = mutableListOf<OperationID?>()
        move.onChange = { publications += it.operation }
        val source = MotionProgramSession.Source(old) {
            if (!replaceOnCheck) true else {
                replaceOnCheck = false
                successorStarted = move.start(program(40.0), MotionProgramSession.Source(next) { true }, timing)
                successor = move.state.value.operation
                returning
            }
        }
        assertTrue(move.start(program(loop = true), source, timing)); runCurrent()
        assertEquals(1, old.moves.size); assertEquals(1, clock.pending)
        val previous = move.state.value.operation
        publications.clear(); replaceOnCheck = true
        clock.advance(33.milliseconds); runCurrent()
        assertFalse(replaceOnCheck); assertTrue(successorStarted); assertNotNull(successor)
        assertNotEquals(previous, successor)
        assertEquals(successor, move.state.value.operation); assertTrue(move.state.value.progress.running)
        assertNull(move.state.value.failure); assertTrue(publications.all { it == successor })
        assertEquals(1, old.moves.size); assertEquals(0, old.stops)
        assertEquals(40.0, next.moves.single().yawDeg)
        clock.advance(3.seconds); runCurrent()
        assertEquals(2, next.moves.size); assertEquals(successor, move.state.value.operation)
        move.cancel(); clock.advance(100.seconds); runCurrent()
    }

    private fun TestScope.predicateReplacementDuringReply(returning: Boolean) {
        val clock = ProgramClock(); val move = owner(clock); val old = ProgramMotion(); val next = ProgramMotion()
        old.delaysReplies = true
        var replaceOnCheck = false
        var successor: OperationID? = null
        var successorStarted = false
        val publications = mutableListOf<OperationID?>()
        move.onChange = { publications += it.operation }
        val source = MotionProgramSession.Source(old) {
            if (!replaceOnCheck) true else {
                replaceOnCheck = false
                successorStarted = move.start(program(40.0), MotionProgramSession.Source(next) { true }, timing)
                successor = move.state.value.operation
                returning
            }
        }
        assertTrue(move.start(program(loop = true), source, timing)); runCurrent()
        assertEquals(1, old.pending); assertEquals(1, clock.pending)
        val previous = move.state.value.operation
        publications.clear(); replaceOnCheck = true
        old.reply(false); runCurrent()
        assertFalse(replaceOnCheck); assertTrue(successorStarted); assertNotNull(successor)
        assertNotEquals(previous, successor)
        assertEquals(successor, move.state.value.operation); assertTrue(move.state.value.progress.running)
        assertNull(move.state.value.failure); assertTrue(publications.all { it == successor })
        assertEquals(1, old.moves.size); assertEquals(0, old.stops)
        assertEquals(40.0, next.moves.single().yawDeg)
        clock.advance(3.seconds); runCurrent()
        assertEquals(2, next.moves.size); assertEquals(successor, move.state.value.operation)
        move.cancel(); clock.advance(100.seconds); runCurrent()
    }
}

private class ProgramClock {
    var instant = MonotonicInstant.ZERO
        private set
    private val sleepers = mutableListOf<Pair<MonotonicInstant, Continuation<Unit>>>()
    val pending: Int get() = sleepers.size
    suspend fun sleep(duration: Duration): Unit = suspendCoroutine { sleepers += (instant + duration) to it }
    fun advance(duration: Duration) {
        instant += duration
        val due = sleepers.filter { it.first <= instant }
        sleepers.removeAll(due.toSet())
        due.forEach { it.second.resume(Unit) }
    }
}

private class ProgramMotion : MotionService {
    override val capabilities = MotionCapabilities(setOf(MotionAxis.PAN, MotionAxis.TILT, MotionAxis.ZOOM),
        MotionReferenceFrame.HANDLE, MotionBounds(-48.0..225.0, -44.0..70.0), null, 300.milliseconds, 0.15)
    val moves = mutableListOf<GimbalWaypoint>()
    var stops = 0
    var accepts = true
    var delaysReplies = false
    private val replies = mutableListOf<Continuation<Boolean>>()
    val pending: Int get() = replies.size
    override suspend fun move(target: MotionTarget, duration: Duration?): Boolean {
        assertNull(duration); moves += target.pose
        return if (delaysReplies) suspendCoroutine { replies += it } else accepts
    }
    fun reply(accepted: Boolean) { replies.removeAt(0).resume(accepted) }
    override suspend fun stick(pan: Double, tilt: Double): Boolean = true
    override suspend fun recenter(): Boolean = true
    override suspend fun stop(): Boolean { stops += 1; return true }
    override val poses: StateFlow<ObservedValue<GimbalWaypoint>> = MutableStateFlow(ObservedValue.unknown)
}
