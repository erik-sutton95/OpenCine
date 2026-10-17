package com.opencapture.opencine.nikon

import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * A6-02: a returned PTP control session is not a recovered monitor. Recovery ends on a source
 * frame and a presented picture after the attempt started, and the whole run stops at the shared
 * 180 s budget.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorSessionRecoveryPictureTest {
    private fun TestScope.pictures() = MonitorPictureClock { testScheduler.currentTime }

    /** The monitor's frame and present paths both ran now. */
    private fun MonitorPictureClock.present() {
        noteSourceFrame()
        notePresented()
    }

    private fun coordinator(session: CameraSession, pictures: MonitorPictureClock) =
        PictureAwareMonitorSessionRecoveryCoordinator(session = session, pictures = pictures, jitterSample = { 1.0 })

    @Test
    fun `a returned control session without a picture keeps recovering`() = runTest {
        val session = PictureSession()
        val coordinator = coordinator(session, pictures())
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        assertEquals(1, session.connectCount)

        session.loseConnection()
        advanceTimeBy(5_000)
        runCurrent()

        assertEquals(2, session.connectCount)
        assertIs<CameraSessionState.Connected>(session.state.value)
        assertEquals(SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 8), coordinator.recoveryState.value)
    }

    @Test
    fun `a picture from before the attempt does not end recovery`() = runTest {
        val session = PictureSession()
        val pictures = pictures()
        val coordinator = coordinator(session, pictures)
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        pictures.present()

        advanceTimeBy(500)
        session.loseConnection()
        advanceTimeBy(1_000)
        runCurrent()

        assertEquals(2, session.connectCount)
        assertIs<SessionRecoveryUi.Retrying>(coordinator.recoveryState.value)
    }

    @Test
    fun `a fresh picture after the reconnect ends recovery`() = runTest {
        val session = PictureSession()
        val pictures = pictures()
        val coordinator = coordinator(session, pictures)
        backgroundScope.launch { coordinator.run() }
        runCurrent()

        session.loseConnection()
        advanceTimeBy(1_000)
        runCurrent()
        pictures.present()
        advanceTimeBy(200)
        runCurrent()

        assertEquals(SessionRecoveryUi.Idle, coordinator.recoveryState.value)
        assertEquals(2, session.connectCount)
    }

    @Test
    fun `automatic recovery hands to the operator at the total budget`() = runTest {
        // The reconnect dials a camera that never answers: no attempt ever returns.
        val session = PictureSession(hangOnReconnect = true)
        val coordinator = coordinator(session, pictures())
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        session.loseConnection()
        runCurrent()

        advanceTimeBy(180_001)
        runCurrent()

        assertIs<SessionRecoveryUi.WaitingForOperator>(coordinator.recoveryState.value)
    }

    @Test
    fun `control sessions that never show a picture stop at the total budget`() = runTest {
        val session = PictureSession()
        val coordinator = coordinator(session, pictures())
        backgroundScope.launch { coordinator.run() }
        runCurrent()
        session.loseConnection()

        advanceTimeBy(180_001)
        runCurrent()

        assertIs<SessionRecoveryUi.WaitingForOperator>(coordinator.recoveryState.value)
        val connects = session.connectCount
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(connects, session.connectCount, "no automatic connect after the budget")
    }

    /** Every connect returns the control session; [hangOnReconnect] never returns after the first. */
    private class PictureSession(private val hangOnReconnect: Boolean = false) : CameraSession {
        private val mutableState =
            MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
        override val state: StateFlow<CameraSessionState> = mutableState
        override val recordingState: StateFlow<CameraRecordingState> =
            MutableStateFlow(CameraRecordingState.STANDBY)

        var connectCount: Int = 0
            private set

        override suspend fun connect() {
            connectCount += 1
            mutableState.value = CameraSessionState.Connecting
            if (hangOnReconnect && connectCount > 1) CompletableDeferred<Unit>().await()
            mutableState.value =
                CameraSessionState.Connected(CameraIdentity("Recovery camera", "NIKON ZR", "PICTURE"))
        }

        override suspend fun setRecording(recording: Boolean) = Unit

        override suspend fun disconnect() {
            loseConnection()
        }

        fun loseConnection() {
            mutableState.value = CameraSessionState.Disconnected
        }
    }
}
