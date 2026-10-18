package com.opencapture.opencine.nikon

import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** The Nikon monitor's connection and recovery owner over the shared episode. SIMULATED session. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorSessionRecoveryTest {
    private fun TestScope.pictures() = MonitorPictureClock { testScheduler.currentTime }

    private fun MonitorPictureClock.present() {
        noteSourceFrame()
        notePresented()
    }

    private fun coordinator(session: CameraSession, pictures: MonitorPictureClock) =
        PictureAwareMonitorSessionRecoveryCoordinator(session = session, pictures = pictures, jitterSample = { 0.5 })

    @Test
    fun `the first connection is immediate and is not a recovery`() = runTest {
        val session = RecoverySession(true)
        val coordinator = coordinator(session, pictures())
        val states = mutableListOf<SessionRecoveryUi>()
        backgroundScope.launch { coordinator.recoveryState.collect { states += it } }
        backgroundScope.launch { coordinator.run() }
        runCurrent()

        assertEquals(1, session.connectCount)
        assertEquals(100L, session.cameraProperties.value.iso)
        assertEquals(listOf<SessionRecoveryUi>(SessionRecoveryUi.Idle), states)
    }

    @Test
    fun `a failed first connect recovers on the shared backoff and a fresh picture`() = runTest {
        val session = RecoverySession(false, false, true)
        val pictures = pictures()
        val coordinator = coordinator(session, pictures)
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        // The first connect failed; the episode retried at once and again after 0.5 s.
        advanceTimeBy(600)
        runCurrent()
        assertEquals(3, session.connectCount)
        assertEquals(SessionRecoveryUi.Retrying(attempt = 2, maxAttempts = 8), coordinator.recoveryState.value)

        pictures.present()
        advanceTimeBy(200)
        runCurrent()

        assertEquals(SessionRecoveryUi.Idle, coordinator.recoveryState.value)
        assertEquals(CameraRecordingState.RECORDING, session.recordingState.value)
    }

    @Test
    fun `a later drop starts a fresh episode at attempt one`() = runTest {
        val session = RecoverySession(true, true, true)
        val pictures = pictures()
        val coordinator = coordinator(session, pictures)
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        repeat(2) {
            session.loseConnection()
            runCurrent()
            assertEquals(SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 8), coordinator.recoveryState.value)
            advanceTimeBy(50)
            pictures.present()
            advanceTimeBy(100)
            runCurrent()
            assertEquals(SessionRecoveryUi.Idle, coordinator.recoveryState.value)
        }
        assertEquals(3, session.connectCount)
    }

    @Test
    fun `cancelling the monitor owner cancels a pending retry`() = runTest {
        val session = RecoverySession(false, false)
        val coordinator = coordinator(session, pictures())
        val recovery = backgroundScope.launch { coordinator.run() }
        runCurrent()
        assertEquals(2, session.connectCount)

        recovery.cancelAndJoin()
        advanceTimeBy(60_000)
        runCurrent()

        assertEquals(2, session.connectCount)
    }

    @Test
    fun `an external connection during backoff is adopted, not duplicated`() = runTest {
        val session = RecoverySession(false, false)
        val pictures = pictures()
        val coordinator = coordinator(session, pictures)
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        assertEquals(2, session.connectCount)

        session.restoreConnection()
        advanceTimeBy(600)
        pictures.present()
        advanceTimeBy(200)
        runCurrent()

        assertEquals(2, session.connectCount)
        assertEquals(SessionRecoveryUi.Idle, coordinator.recoveryState.value)
    }

    @Test
    fun `automatic retries are bounded and hand the decision to the operator`() = runTest {
        // Every attempt fails: eight attempts, then the card, never a loop behind "No camera".
        val session = RecoverySession()
        val coordinator = coordinator(session, pictures())
        val run = backgroundScope.launch { coordinator.run() }
        // Background work is not idled by advanceUntilIdle: walk the 31.5 s of backoff.
        advanceTimeBy(60_000)
        runCurrent()

        assertEquals(1 + 8, session.connectCount)
        assertEquals(SessionRecoveryUi.WaitingForOperator(attemptsMade = 8), coordinator.recoveryState.value)
        assertTrue(run.isCompleted)
    }

    @Test
    fun `a lifecycle restart keeps a spent budget for the operator, and retry starts afresh`() = runTest {
        val session = RecoverySession()
        val pictures = pictures()
        val coordinator = coordinator(session, pictures)
        backgroundScope.launch { coordinator.run() }
        advanceTimeBy(60_000)
        runCurrent()
        val connects = session.connectCount
        assertIs<SessionRecoveryUi.WaitingForOperator>(coordinator.recoveryState.value)

        backgroundScope.launch { coordinator.run() }
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(connects, session.connectCount, "a restart is not an operator retry")

        session.succeedNext = true
        coordinator.retry()
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        assertEquals(connects + 1, session.connectCount)
        assertEquals(SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 8), coordinator.recoveryState.value)
        advanceTimeBy(50)
        pictures.present()
        advanceTimeBy(100)
        runCurrent()
        assertEquals(SessionRecoveryUi.Idle, coordinator.recoveryState.value)
    }

    @Test
    fun `clustered drops of a healthy-reconnecting session pause for the operator`() = runTest {
        // Every reconnect SUCCEEDS with a picture, so the per-episode budget never fires; that is
        // the storm signature. Only the drop ledger stops the churn that wedges the body.
        val session = RecoverySession(true, true, true)
        val pictures = pictures()
        val coordinator = coordinator(session, pictures)
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        repeat(2) {
            session.loseConnection()
            runCurrent()
            advanceTimeBy(50)
            pictures.present()
            advanceTimeBy(100)
            runCurrent()
        }
        assertEquals(3, session.connectCount)

        session.loseConnection()
        runCurrent()

        assertEquals(3, session.connectCount)
        assertEquals(SessionRecoveryUi.PausedAfterDrops(drops = 3), coordinator.recoveryState.value)
    }

    @Test
    fun `the published state counts attempts truthfully while retrying`() = runTest {
        val session = RecoverySession()
        val coordinator = coordinator(session, pictures())
        val states = mutableListOf<SessionRecoveryUi>()
        backgroundScope.launch { coordinator.recoveryState.collect { states += it } }
        backgroundScope.launch { coordinator.run() }
        advanceTimeBy(1_600)
        runCurrent()

        assertEquals(
            listOf(
                SessionRecoveryUi.Idle,
                SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 8),
                SessionRecoveryUi.Retrying(attempt = 2, maxAttempts = 8),
                SessionRecoveryUi.Retrying(attempt = 3, maxAttempts = 8),
            ),
            states,
        )
    }

    /** Connect outcomes in order, then [succeedNext] for every later attempt. */
    private class RecoverySession(vararg outcomes: Boolean) : CameraSession {
        private val remainingOutcomes = ArrayDeque(outcomes.toList())
        private val mutableState =
            MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
        private val mutableRecordingState = MutableStateFlow(CameraRecordingState.STANDBY)
        private val mutableCameraProperties = MutableStateFlow(CameraPropertySnapshot())

        override val state: StateFlow<CameraSessionState> = mutableState
        override val recordingState: StateFlow<CameraRecordingState> = mutableRecordingState
        override val cameraProperties: StateFlow<CameraPropertySnapshot> = mutableCameraProperties

        var succeedNext = false
        var connectCount: Int = 0
            private set

        override suspend fun connect() {
            connectCount += 1
            mutableState.value = CameraSessionState.Connecting
            if (!(remainingOutcomes.removeFirstOrNull() ?: succeedNext)) {
                clearReadback()
                mutableState.value = CameraSessionState.Disconnected
                return
            }
            mutableCameraProperties.value = CameraPropertySnapshot(iso = connectCount * 100L)
            mutableRecordingState.value =
                if (connectCount >= 3) CameraRecordingState.RECORDING else CameraRecordingState.STANDBY
            mutableState.value = connectedState()
        }

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun disconnect() {
            loseConnection()
        }

        fun loseConnection() {
            clearReadback()
            mutableState.value = CameraSessionState.Disconnected
        }

        fun restoreConnection() {
            mutableState.value = connectedState()
        }

        private fun clearReadback() {
            mutableCameraProperties.value = CameraPropertySnapshot()
            mutableRecordingState.value = CameraRecordingState.STANDBY
        }

        private fun connectedState(): CameraSessionState.Connected =
            CameraSessionState.Connected(CameraIdentity("Recovery camera", "NIKON ZR", "RECOVERY-TEST"))
    }
}
