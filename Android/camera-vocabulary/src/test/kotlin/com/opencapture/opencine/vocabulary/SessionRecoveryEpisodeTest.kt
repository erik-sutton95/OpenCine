package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.vocabulary.SessionRecoveryEpisode.Cleanup
import com.opencapture.opencine.vocabulary.SessionRecoveryEpisode.Progress
import com.opencapture.opencine.vocabulary.SessionRecoveryEpisode.Stage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * Shared recovery conformance scenarios (A6-02, A6-11), the Kotlin twin of the Swift
 * `SessionRecoveryEpisodeTests`. SIMULATED transport on virtual time.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionRecoveryEpisodeTest {
    private class Host(val scope: TestScope, deadline: SessionRecoveryEpisode.AttemptDeadline) :
        SessionRecoveryEpisode.Port {
        var owns: Boolean? = true
        var admits = true
        var progress = Progress.RUNNING
        var stage: Stage? = null
        var sourceAtMs: Long? = null
        var presentedAtMs: Long? = null
        var connects = 0
        val cleanups = mutableListOf<Cleanup>()
        val published = mutableListOf<SessionRecoveryEpisode.Snapshot>()
        var onConnect: (suspend () -> Unit)? = null
        var onChanged: ((SessionRecoveryEpisode.Snapshot) -> Unit)? = null
        val waits = mutableListOf<Long>()
        val episode =
            SessionRecoveryEpisode(
                scope = scope.backgroundScope,
                port = this,
                attemptDeadline = deadline,
                timing = SessionRecoveryEpisode.Timing(nowMs = { scope.testScheduler.currentTime }, jitter = { 0.5 }),
                changed = {
                    published += it
                    onChanged?.invoke(it)
                },
            )

        override fun observe() =
            SessionRecoveryEpisode.Observation(owns, progress, stage, sourceAtMs, presentedAtMs)

        override fun cleanup(kind: Cleanup, attempt: SessionRecoveryEpisode.Attempt) {
            cleanups += kind
        }

        override suspend fun connect(attempt: SessionRecoveryEpisode.Attempt): Boolean {
            connects += 1
            onConnect?.invoke()
            attempt.checkContinuation()
            return admits
        }

        var holder: String? = null
        val holderAsks = mutableListOf<Int>()

        var onHolder: (suspend () -> Unit)? = null

        override suspend fun holder(attempt: SessionRecoveryEpisode.Attempt, number: Int): String? {
            holderAsks += number
            onHolder?.invoke()
            return holder
        }

        fun present() {
            val now = scope.testScheduler.currentTime
            sourceAtMs = now
            presentedAtMs = now
        }

        fun begin(trigger: SessionRecoveryTrigger = SessionRecoveryTrigger.BLE_DROPPED) =
            episode.begin("SIMULATED camera", trigger, "SIMULATED drop")

        val state get() = episode.snapshot.value.state
    }

    private fun TestScope.host(attemptMs: Long = 30_000, stages: Map<Stage, Long> = emptyMap()) =
        Host(this, SessionRecoveryEpisode.AttemptDeadline(attemptMs, stages))

    /** physical-C C9/C10: the phone that lost the camera must not take it straight back. */
    @Test
    fun `another device holding the camera stops recovery before any dial`() = runTest {
        val host = host()
        host.holder = "Phone B"
        assertTrue(host.begin(SessionRecoveryTrigger.DATALINK_LOST))
        runCurrent()
        assertEquals(SessionRecoveryUi.TakenOver("Phone B"), host.state)
        assertEquals(0, host.connects)
        assertEquals(listOf(1), host.holderAsks)
        assertTrue(host.episode.snapshot.value.cardGraceElapsed)
        // A later loss reporter for the same drop cannot restart the run behind the card.
        assertFalse(host.begin(SessionRecoveryTrigger.DATALINK_LOST))
        // The operator's retry is the take-back: it dials without asking.
        assertTrue(host.episode.retry())
        runCurrent()
        assertEquals(1, host.connects)
        assertEquals(listOf(1), host.holderAsks)
    }

    @Test
    fun `nobody holding the camera lets every automatic attempt dial`() = runTest {
        val host = host(attemptMs = 1_000)
        assertTrue(host.begin(SessionRecoveryTrigger.DATALINK_LOST))
        runCurrent()
        advanceTimeBy(1_100)
        runCurrent()
        advanceTimeBy(5_000)
        runCurrent()
        assertTrue(host.connects >= 2)
        assertEquals((1..host.connects).toList(), host.holderAsks)
    }

    @Test
    fun `a control session without a picture keeps retrying until the attempt deadline`() = runTest {
        val host = host()
        assertTrue(host.begin())
        runCurrent()
        assertEquals(1, host.connects)
        advanceTimeBy(29_900)
        runCurrent()
        assertEquals(SessionRecoveryUi.Retrying(1, 8), host.state)
        assertTrue(host.episode.snapshot.value.holdsPicture)
        advanceTimeBy(700)
        runCurrent()
        assertEquals(2, host.connects)
        assertEquals(listOf(Cleanup.INITIAL_DROP, Cleanup.FAILED_ATTEMPT), host.cleanups)
        assertEquals(SessionRecoveryUi.Retrying(2, 8), host.state)
    }

    @Test
    fun `a fresh source frame and presented picture after the attempt start end recovery`() = runTest {
        val host = host()
        assertTrue(host.begin())
        runCurrent()
        advanceTimeBy(1_000)
        host.present()
        advanceTimeBy(150)
        runCurrent()
        val snapshot = host.episode.snapshot.value
        assertEquals(SessionRecoveryUi.Idle, snapshot.state)
        assertFalse(snapshot.holdsPicture)
        assertFalse(snapshot.reconnecting)
        assertFalse(host.episode.isRunning)
        assertNull(host.episode.currentEpisodeId)
        assertEquals(listOf(Cleanup.INITIAL_DROP), host.cleanups)
    }

    @Test
    fun `a stale or partial picture does not end recovery`() = runTest {
        for ((source, presented) in listOf(-1L to -1L, 1L to -1L, -1L to 1L, 1L to null)) {
            val host = host()
            advanceTimeBy(10_000)
            assertTrue(host.begin())
            runCurrent()
            val started = testScheduler.currentTime
            host.sourceAtMs = started + source
            host.presentedAtMs = presented?.let { started + it }
            advanceTimeBy(1_500)
            runCurrent()
            assertEquals(SessionRecoveryUi.Retrying(1, 8), host.state, "source=$source presented=$presented")
            host.episode.cancel()
        }
    }

    @Test
    fun `attempts that never show a picture stop at the total budget`() = runTest {
        val host = host()
        assertTrue(host.begin())
        advanceTimeBy(SessionRecoveryPolicy.AUTOMATIC_RECOVERY_BUDGET_MS - 1)
        runCurrent()
        assertIs<SessionRecoveryUi.Retrying>(host.state)
        advanceTimeBy(2)
        runCurrent()
        assertIs<SessionRecoveryUi.WaitingForOperator>(host.state)
        assertEquals(Cleanup.BUDGET_EXHAUSTED, host.cleanups.last())
        assertTrue(host.episode.snapshot.value.holdsPicture)
        assertTrue(host.episode.snapshot.value.cardGraceElapsed)
        val connects = host.connects
        advanceTimeBy(220_000)
        runCurrent()
        assertEquals(connects, host.connects)
        assertFalse(host.begin(SessionRecoveryTrigger.SOFTAP_LOST), "the spent budget waits for the operator")
    }

    @Test
    fun `a connect that never returns stops at the total budget`() = runTest {
        val host = host()
        host.onConnect = { CompletableDeferred<Unit>().await() }
        assertTrue(host.begin())
        advanceTimeBy(SessionRecoveryPolicy.AUTOMATIC_RECOVERY_BUDGET_MS + 1)
        runCurrent()
        assertIs<SessionRecoveryUi.WaitingForOperator>(host.state)
        assertEquals(1, host.connects)
    }

    @Test
    fun `total budget hands back before an uncancellable connect returns`() = runTest {
        val host = host()
        val gate = CompletableDeferred<Unit>()
        host.onConnect = { withContext(NonCancellable) { gate.await() } }
        assertTrue(host.begin())
        runCurrent()
        advanceTimeBy(180_000)
        runCurrent()
        val state = host.state
        val cleanup = host.cleanups.last()
        val published = host.published.toList()
        gate.complete(Unit)
        runCurrent()
        assertEquals(SessionRecoveryUi.WaitingForOperator(1), state)
        assertEquals(Cleanup.BUDGET_EXHAUSTED, cleanup)
        assertEquals(published, host.published)
        host.episode.cancel()
    }

    @Test
    fun `eight failed attempts hand back with the shared waits`() = runTest {
        val host = host()
        host.admits = false
        assertTrue(host.begin())
        // 0.5 + 1 + 2 + 4 + 8 + 8 + 8 s of backoff, then no further attempt.
        advanceTimeBy(31_500)
        assertEquals(SessionRecoveryUi.Retrying(7, 8), host.state)
        assertEquals(7, host.connects)
        runCurrent()
        assertEquals(SessionRecoveryUi.WaitingForOperator(8), host.state)
        assertEquals(8, host.connects)
        assertEquals(8, host.cleanups.count { it == Cleanup.FAILED_ATTEMPT })
        advanceTimeBy(220_000)
        runCurrent()
        assertEquals(8, host.connects)
    }

    @Test
    fun `a transport that gives up counts a failure`() = runTest {
        val host = host()
        host.progress = Progress.FAILED
        assertTrue(host.begin())
        runCurrent()
        assertEquals(1, host.connects)
        advanceTimeBy(501)
        runCurrent()
        assertEquals(2, host.connects)
    }

    @Test
    fun `a superseded source waits for the operator without reconnecting`() = runTest {
        val host = host()
        assertTrue(host.begin())
        runCurrent()
        host.progress = Progress.SUPERSEDED
        advanceTimeBy(50)
        host.present()
        advanceTimeBy(100)
        runCurrent()
        assertEquals(SessionRecoveryUi.WaitingForOperator(1), host.state)
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(1, host.connects)
        assertTrue(host.episode.snapshot.value.holdsPicture)
        // The spinner agrees with the state: waiting for the operator is not reconnecting.
        assertEquals(false, host.episode.snapshot.value.reconnecting)
    }

    @Test
    fun `stage ceilings restart when the stage changes`() = runTest {
        val host = host(attemptMs = 100_000, stages = mapOf(Stage.CONNECTING to 5_000L, Stage.LIVE to 4_000L))
        host.stage = Stage.CONNECTING
        assertTrue(host.begin())
        runCurrent()
        advanceTimeBy(3_000)
        host.stage = Stage.OPENING_LINK
        advanceTimeBy(17_000)
        runCurrent()
        assertEquals(1, host.connects, "a stage without a ceiling runs on the attempt ceiling")
        host.stage = Stage.LIVE
        advanceTimeBy(4_000)
        runCurrent()
        assertEquals(1, host.connects)
        advanceTimeBy(700)
        runCurrent()
        assertEquals(2, host.connects)
    }

    @Test
    fun `the card waits out its grace behind attempt one`() = runTest {
        val host = host()
        assertTrue(host.begin())
        advanceTimeBy(2_499)
        runCurrent()
        assertFalse(host.episode.snapshot.value.cardGraceElapsed)
        advanceTimeBy(1)
        runCurrent()
        assertTrue(host.episode.snapshot.value.cardGraceElapsed)
    }

    @Test
    fun `clustered drops pause until the operator retries`() = runTest {
        val host = host()
        repeat(2) {
            assertTrue(host.begin())
            runCurrent()
            advanceTimeBy(50)
            host.present()
            advanceTimeBy(100)
            runCurrent()
            assertEquals(SessionRecoveryUi.Idle, host.state)
            host.connects = 0
        }
        assertTrue(host.begin())
        assertEquals(SessionRecoveryUi.PausedAfterDrops(3), host.state)
        assertEquals(listOf(Cleanup.INITIAL_DROP, Cleanup.STORM_PAUSE), host.cleanups.takeLast(2))
        assertTrue(host.episode.snapshot.value.cardGraceElapsed)
        assertFalse(host.begin(SessionRecoveryTrigger.SOFTAP_LOST))
        assertTrue(host.episode.retry())
        runCurrent()
        assertEquals(1, host.connects)
        assertEquals(SessionRecoveryUi.Retrying(1, 8), host.state)
    }

    @Test
    fun `refused triggers missing targets and foreign connections do nothing`() = runTest {
        val host = host()
        assertFalse(host.begin(SessionRecoveryTrigger.FEED_WATCHDOG))
        assertFalse(host.episode.begin(null, SessionRecoveryTrigger.BLE_DROPPED, "SIMULATED"))
        host.owns = null
        assertFalse(host.begin())
        host.owns = false
        assertFalse(host.begin())
        assertTrue(host.cleanups.isEmpty())
        assertTrue(host.published.isEmpty())
        assertEquals(SessionRecoveryEpisode.Snapshot(), host.episode.snapshot.value)
    }

    @Test
    fun `losing the connection mid attempt stops without acting`() = runTest {
        val host = host()
        assertTrue(host.begin())
        runCurrent()
        val published = host.published.size
        host.owns = false
        advanceTimeBy(200_000)
        runCurrent()
        assertEquals(1, host.connects)
        assertEquals(published, host.published.size)
        assertEquals(listOf(Cleanup.INITIAL_DROP), host.cleanups)
    }

    @Test
    fun `a retired attempt's late connect cannot act for its successor`() = runTest {
        val host = host()
        val gate = CompletableDeferred<Unit>()
        host.onConnect = { gate.await() }
        assertTrue(host.begin())
        runCurrent()
        host.episode.cancel(clearHold = false)
        host.onConnect = null
        assertTrue(host.begin(SessionRecoveryTrigger.OPERATOR_RETRY))
        runCurrent()
        assertEquals(2, host.connects)
        advanceTimeBy(50)
        host.present()
        advanceTimeBy(100)
        runCurrent()
        assertEquals(SessionRecoveryUi.Idle, host.state)
        val snapshot = host.episode.snapshot.value
        val cleanups = host.cleanups.toList()
        gate.complete(Unit)
        runCurrent()
        assertEquals(snapshot, host.episode.snapshot.value)
        assertEquals(cleanups, host.cleanups)
        assertEquals(2, host.connects)
    }

    @Test
    fun `cancelling inside the first publication installs nothing`() = runTest {
        val host = host()
        host.onChanged = { if (it.state is SessionRecoveryUi.Retrying) host.episode.cancel() }
        assertFalse(host.begin())
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(SessionRecoveryEpisode.Snapshot(), host.episode.snapshot.value)
        assertFalse(host.episode.isRunning)
        assertEquals(0, host.connects)
    }

    @Test
    fun `a throwing connect counts as a failed attempt`() = runTest {
        val host = host()
        host.onConnect = { throw IllegalStateException("SIMULATED radio off") }
        assertTrue(host.begin())
        runCurrent()
        assertEquals(1, host.connects)
        advanceTimeBy(501)
        runCurrent()
        assertEquals(2, host.connects)
        assertEquals(Cleanup.FAILED_ATTEMPT, host.cleanups[1])
    }
    /**
     * Hardware pass 7.2a: in the background Android blocks the camera network, so each attempt
     * there failed in milliseconds and all 8 were spent before the app came back. A drop admitted
     * while the host is paused holds its picture and dials only after [SessionRecoveryEpisode.resume].
     */
    @Test
    fun `a drop admitted while the host is paused waits to dial until resume`() = runTest {
        val host = host()
        host.admits = false
        host.episode.pause()
        assertTrue(host.begin())
        advanceTimeBy(SessionRecoveryPolicy.AUTOMATIC_RECOVERY_BUDGET_MS * 2)
        runCurrent()
        assertEquals(0, host.connects)
        assertEquals(SessionRecoveryUi.Retrying(1, 8), host.state)
        assertTrue(host.episode.snapshot.value.holdsPicture)
        assertEquals(listOf(Cleanup.INITIAL_DROP), host.cleanups)
        host.admits = true
        host.episode.resume()
        runCurrent()
        assertEquals(1, host.connects)
        advanceTimeBy(1_000)
        host.present()
        advanceTimeBy(150)
        runCurrent()
        assertEquals(SessionRecoveryUi.Idle, host.state)
    }

    @Test
    fun `an attempt the OS refuses while paused is not counted`() = runTest {
        val host = host()
        val refused = CompletableDeferred<Unit>()
        host.onConnect = { refused.await() }
        host.admits = false
        assertTrue(host.begin())
        runCurrent()
        assertEquals(1, host.connects)
        host.episode.pause()
        refused.complete(Unit)
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(1, host.connects, "no attempt dials while paused")
        assertEquals(SessionRecoveryUi.Retrying(1, 8), host.state)
        assertEquals(listOf(Cleanup.INITIAL_DROP, Cleanup.FAILED_ATTEMPT), host.cleanups)
        assertFalse(host.episode.snapshot.value.reconnecting)
        host.onConnect = null
        host.episode.resume()
        runCurrent()
        assertEquals(2, host.connects, "resume dials at once, without a backoff")
        assertEquals(SessionRecoveryUi.Retrying(1, 8), host.state)
    }

    @Test
    fun `the total budget counts only time the host is active`() = runTest {
        val host = host(attemptMs = 1_000_000)
        assertTrue(host.begin())
        advanceTimeBy(60_000)
        runCurrent()
        host.episode.pause()
        advanceTimeBy(600_000)
        runCurrent()
        assertIs<SessionRecoveryUi.Retrying>(host.state)
        host.episode.resume()
        runCurrent()
        advanceTimeBy(SessionRecoveryPolicy.AUTOMATIC_RECOVERY_BUDGET_MS - 60_000 - 1)
        runCurrent()
        assertIs<SessionRecoveryUi.Retrying>(host.state)
        advanceTimeBy(2)
        runCurrent()
        assertIs<SessionRecoveryUi.WaitingForOperator>(host.state)
        assertEquals(Cleanup.BUDGET_EXHAUSTED, host.cleanups.last())
    }

    @Test
    fun `resuming an episode that waits for the operator dials nothing`() = runTest {
        val host = host()
        host.admits = false
        assertTrue(host.begin())
        advanceTimeBy(40_000)
        runCurrent()
        assertEquals(SessionRecoveryUi.WaitingForOperator(8), host.state)
        host.episode.pause()
        host.episode.resume()
        advanceTimeBy(400_000)
        runCurrent()
        assertEquals(8, host.connects)
        assertEquals(SessionRecoveryUi.WaitingForOperator(8), host.state)
    }

    @Test
    fun `a pause while the holder is asked keeps the attempt from dialing`() = runTest {
        val host = host()
        val asked = CompletableDeferred<Unit>()
        host.onHolder = { asked.await() }
        assertTrue(host.begin(SessionRecoveryTrigger.DATALINK_LOST))
        runCurrent()
        assertEquals(listOf(1), host.holderAsks)
        host.episode.pause()
        asked.complete(Unit)
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(0, host.connects, "no attempt dials while paused")
        host.episode.resume()
        runCurrent()
        assertEquals(1, host.connects)
    }
}
