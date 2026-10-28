package com.opencapture.opencine.nikon

import com.opencapture.opencine.gyro.FakeGyroNative
import com.opencapture.opencine.gyro.GyroCameraIdentity
import com.opencapture.opencine.gyro.GyroStabilizationState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class NikonGyroCameraAdapterTest {
    @Test
    fun identityPrefersSerial() = runTest {
        val session = ScriptedCameraSession(CameraIdentity("Nikon ZR", "ZR", "123"))
        val adapter = NikonGyroCameraAdapter(session, null, FakeGyroNative(), backgroundScope) { 1.0 }
        runCurrent()

        assertEquals(GyroCameraIdentity("nikon-123", "Nikon ZR"), adapter.identity.value)
        assertFalse(adapter.providesLevel)
    }

    @Test
    fun stabilizationMapsBothValues() = runTest {
        val session = ScriptedCameraSession(CameraIdentity("Nikon ZR", "ZR", "123"))
        session.properties.value = CameraPropertySnapshot(vibrationReduction = "ON", electronicVr = "ON")
        session.reportedProperties.value = CameraPropertySnapshot(vibrationReduction = "SPORT", electronicVr = "OFF")
        val adapter = NikonGyroCameraAdapter(session, null, FakeGyroNative(), backgroundScope) { 1.0 }
        runCurrent()

        assertEquals(
            GyroStabilizationState(mapOf("movieVR" to "SPORT", "electronicVR" to "OFF"), null),
            adapter.stabilization.value,
        )
    }

    @Test
    fun writesInOrderAndStopAtRefusal() = runTest {
        val session = ScriptedCameraSession(CameraIdentity("Nikon ZR", "ZR", "123"))
        session.refuseControl = CameraControl.ELECTRONIC_VR
        val adapter = NikonGyroCameraAdapter(session, null, FakeGyroNative(), backgroundScope) { 1.0 }
        runCurrent()

        assertFalse(adapter.writeStabilization(mapOf("movieVR" to "SPORT", "electronicVR" to "ON")))
        assertEquals(
            listOf(
                CameraControl.VIBRATION_REDUCTION to "SPORT",
                CameraControl.ELECTRONIC_VR to "ON",
            ),
            session.writes,
        )
    }

    @Test
    fun movieVRRefusalPreventsElectronicVRWrite() = runTest {
        val session = ScriptedCameraSession(CameraIdentity("Nikon ZR", "ZR", "123"))
        session.refuseControl = CameraControl.VIBRATION_REDUCTION
        val adapter = NikonGyroCameraAdapter(session, null, FakeGyroNative(), backgroundScope) { 1.0 }
        runCurrent()

        assertFalse(adapter.writeStabilization(mapOf("movieVR" to "SPORT", "electronicVR" to "ON")))
        assertEquals(listOf(CameraControl.VIBRATION_REDUCTION to "SPORT"), session.writes)
    }

    @Test
    fun invalidElectronicVRPreventsEveryWrite() = runTest {
        val session = ScriptedCameraSession(CameraIdentity("Nikon ZR", "ZR", "123"))
        val adapter = NikonGyroCameraAdapter(session, null, FakeGyroNative(), backgroundScope) { 1.0 }
        runCurrent()

        assertFalse(adapter.writeStabilization(mapOf("movieVR" to "SPORT", "electronicVR" to "INVALID")))
        assertEquals(emptyList(), session.writes)
    }

    @Test
    fun debugFixtureLevelIsNoReading() {
        val level = LiveCameraLevel(
            rollDegrees = 0.0,
            pitchDegrees = 0.0,
            yawDegrees = 0.0,
            isDebugFixture = true,
        )

        assertNull(NikonGyroCameraAdapter.cameraLevel(level, FakeGyroNative(), 4.0).down)
        assertNull(NikonGyroCameraAdapter.cameraLevel(level.copy(isDebugFixture = false, hasPitch = false), FakeGyroNative(), 4.0).down)
    }

    @Test
    fun videoModeFollowsSelector() = runTest {
        val session = ScriptedCameraSession(CameraIdentity("Nikon ZR", "ZR", "123"))
        val adapter = NikonGyroCameraAdapter(session, null, FakeGyroNative(), backgroundScope) { 1.0 }
        runCurrent()

        assertNull(adapter.videoMode.value)
        session.reportedProperties.value = CameraPropertySnapshot(captureSelector = "video")
        runCurrent()
        assertEquals(true, adapter.videoMode.value)
        session.reportedProperties.value = CameraPropertySnapshot(captureSelector = "photo")
        runCurrent()
        assertEquals(false, adapter.videoMode.value)
    }
}

private class ScriptedCameraSession(identity: CameraIdentity) : CameraSession {
    override val state = MutableStateFlow<CameraSessionState>(CameraSessionState.Connected(identity))
    override val recordingState = MutableStateFlow(CameraRecordingState.STANDBY)
    override val reportedRecording = MutableStateFlow<Boolean?>(null)
    val properties = MutableStateFlow(CameraPropertySnapshot())
    override val cameraProperties: StateFlow<CameraPropertySnapshot> = properties
    val reportedProperties = MutableStateFlow(CameraPropertySnapshot())
    override val reportedCameraProperties: StateFlow<CameraPropertySnapshot> = reportedProperties
    val writes = mutableListOf<Pair<CameraControl, String>>()
    var refuseControl: CameraControl? = null

    override suspend fun connect() = Unit

    override suspend fun setRecording(recording: Boolean) {
        reportedRecording.value = recording
    }

    override suspend fun disconnect() {
        state.value = CameraSessionState.Disconnected
    }

    override suspend fun applyControl(control: CameraControl, label: String) {
        writes += control to label
        if (control == refuseControl) throw CameraControlException.CommandRejected
    }
}
