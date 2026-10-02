package com.opencapture.opencine.dji

import com.opencapture.opencine.core.AudioLevels
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.PowerStatus
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.motion.MotionAxis
import com.opencapture.opencine.motion.GimbalWaypoint as MotionWaypoint

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * CORE-02 gate checks for the Android Pocket seam (iOS `DJICameraSessionAdapterTests`): declared
 * support is routed, reported state stays separate from requested state, an unconfirmed settle
 * is never success, and record start/stop is explicit and idempotent.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DjiCameraSessionAdapterTest {
    @Test
    fun everyDeclaredCapabilityReachesTheWire() = runTest {
        val keys = adapter(FakePort()).current.capabilities.descriptors.keys
        assertEquals(
            setOf(SettingKey.ISO, SettingKey.WHITE_BALANCE, SettingKey.WHITE_BALANCE_TINT, SettingKey.RECORDING),
            keys,
        )
        for (key in keys) {
            val port = FakePort()
            val seam = adapter(port)
            val snapshot = seam.current
            val intent = assertNotNull(validIntent(key, snapshot), "no test value for $key")
            val receipt = seam.submit(CameraCommand(intent, CommandPreconditions(snapshot)))
            assertEquals(CommandStage.Sent, receipt.stage, "$key is declared, so a valid request must reach the wire")
            assertEquals(1, port.fired.size)
        }
    }

    @Test
    fun undeclaredSettingStaysUnknownInsteadOfPretending() = runTest {
        val receipt = adapter(FakePort()).request(
            CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 50)))),
        )
        assertEquals(CommandStage.Rejected(CommandRejection.SupportUnknown), receipt.stage)
    }

    @Test
    fun whiteBalanceRequestStaysPendingUntilTheCameraReportsIt() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        val receipt = seam.setWhiteBalanceCustom(5_600, 0)
        assertEquals(CommandStage.Sent, receipt.stage)
        assertEquals(listOf("wb 5600 0"), port.fired)
        port.answer(ControlWireEvent.ACKNOWLEDGED)
        assertEquals(CommandStage.AwaitingObservation, seam.receipt(receipt.operation)?.stage, "An ACK is not a value")
        assertEquals(
            SettingValue.WhiteBalance(WhiteBalanceValue.Auto),
            seam.current.value(SettingKey.WHITE_BALANCE).value,
            "Reported stays the camera's Auto",
        )
        port.state = port.state.copy(whiteBalance = ReportedWhiteBalance(CameraCommands.WB_CUSTOM, 5_600, 0))
        seam.sessionDidChange()
        assertEquals(CommandStage.Confirmed, seam.receipt(receipt.operation)?.stage)
        assertEquals(
            SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5_600)),
            seam.current.value(SettingKey.WHITE_BALANCE).value,
        )
    }

    @Test
    fun tintIsItsOwnSettingAndKeepsThePendingWhiteBalance() = runTest {
        val port = FakePort()
        port.state = port.state.copy(whiteBalance = ReportedWhiteBalance(CameraCommands.WB_CUSTOM, 5_600, 0))
        val seam = adapter(port)
        assertEquals(SettingValue.WhiteBalanceTint(0.0), seam.current.value(SettingKey.WHITE_BALANCE_TINT).value)

        // Only the tint changed: one tint write, carried on the current Kelvin.
        val tint = seam.setWhiteBalanceCustom(5_600, 12)
        assertEquals(CameraCommandIntent.Set(SettingValue.WhiteBalanceTint(12.0)), tint.intent)
        assertEquals(listOf("wb 5600 12"), port.fired)

        // A Kelvin step keeps the pending tint, and tint is never confirmed by Kelvin alone.
        port.state = port.state.copy(pendingWhiteBalance = ReportedWhiteBalance(CameraCommands.WB_CUSTOM, 5_600, 12))
        seam.request(CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(4_300))))
        assertEquals("wb 4300 12", port.fired.last())
        assertEquals(
            CommandStage.Rejected(CommandRejection.OutOfDomain),
            seam.request(CameraCommandIntent.Set(SettingValue.WhiteBalanceTint(150.0))).stage,
        )
    }

    @Test
    fun isoIsConfirmedOnlyByItsOwnReadback() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        val receipt = seam.setIsoIndex(0x06)
        port.answer(ControlWireEvent.ACKNOWLEDGED)
        port.state = port.state.copy(whiteBalance = ReportedWhiteBalance(CameraCommands.WB_AUTO, 0, 3))
        seam.sessionDidChange()
        assertEquals(CommandStage.AwaitingObservation, seam.receipt(receipt.operation)?.stage)
        assertEquals(SettingValue.Iso(ISOValue.Manual(400)), seam.current.value(SettingKey.ISO).value)
        port.state = port.state.copy(isoIndex = 0x06)
        seam.sessionDidChange()
        assertEquals(CommandStage.Confirmed, seam.receipt(receipt.operation)?.stage)
    }

    @Test
    fun acknowledgedWithoutReadbackTimesOutInsteadOfSucceeding() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        val receipt = seam.request(CameraCommandIntent.StartRecording)
        port.answer(ControlWireEvent.ACKNOWLEDGED)
        testScheduler.advanceTimeBy(seam.readbackTimeout + 1.milliseconds)
        assertEquals(CommandStage.TimedOut, seam.outcome(receipt.operation)?.stage)
        assertEquals(RecordingState.IDLE, seam.current.recording.value)
    }

    @Test
    fun settleWithoutAckOrMatchingStatusIsNeverSuccess() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        val receipt = seam.setWhiteBalanceCustom(4_300, 0)
        // `settleInflightTimeout` with no ACK and no matching report.
        port.answer(ControlWireEvent.UNCONFIRMED)
        assertEquals(CommandStage.TimedOut, seam.receipt(receipt.operation)?.stage)
        port.answer(ControlWireEvent.ACKNOWLEDGED)
        assertEquals(CommandStage.TimedOut, seam.receipt(receipt.operation)?.stage, "A late ACK never rewrites it")
    }

    @Test
    fun cameraRefusalIsRejected() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        val receipt = seam.request(CameraCommandIntent.StartRecording)
        port.answer(ControlWireEvent.REFUSED)
        assertEquals(CommandStage.Rejected(CommandRejection.CameraRefused), seam.receipt(receipt.operation)?.stage)
    }

    @Test
    fun replacedRequestThatNeverLeftIsNotSent() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        val receipt = seam.setIsoIndex(0x06)
        port.answer(ControlWireEvent.NOT_SENT)
        assertEquals(
            CommandStage.Failed(com.opencapture.opencine.core.CommandFailure.NOT_SENT),
            seam.receipt(receipt.operation)?.stage,
        )
    }

    @Test
    fun startWhileRecordingSendsNothing() = runTest {
        val port = FakePort(recording = true)
        val seam = adapter(port)
        assertEquals(CommandStage.Confirmed, seam.request(CameraCommandIntent.StartRecording).stage)
        port.state = port.state.copy(recording = false)
        assertEquals(CommandStage.Confirmed, seam.request(CameraCommandIntent.StopRecording).stage)
        assertTrue(port.fired.isEmpty(), "No record frame was fired")
    }

    @Test
    fun unknownRecordingStateRefusesTheToggleShapedWire() = runTest {
        val port = FakePort(recording = null)
        val seam = adapter(port)
        assertEquals(null, seam.current.recording.value, "Unknown is not idle")
        assertEquals(CommandStage.Rejected(CommandRejection.RecordingStateUnknown), seam.shutter()?.stage)
        assertTrue(port.fired.isEmpty())
        assertEquals("Waiting for the camera's record state", port.note)
    }

    @Test
    fun shutterResolvesToAnExplicitIntentFromTheReportedState() = runTest {
        for (recording in listOf(false, true)) {
            val port = FakePort(recording = recording)
            val receipt = adapter(port).shutter()
            assertEquals(
                if (recording) CameraCommandIntent.StopRecording else CameraCommandIntent.StartRecording,
                receipt?.intent,
            )
            assertEquals(listOf("record ${!recording}"), port.fired)
        }
    }

    @Test
    fun photoModeFiresAStillWithoutARecordIntent() = runTest {
        val port = FakePort()
        port.state = port.state.copy(shootingMode = CameraCommands.SHOOT_PHOTO)
        assertEquals(null, adapter(port).shutter())
        assertEquals(listOf("photo"), port.fired)
    }

    @Test
    fun replacedLinkEndsInFlightWorkAndRefusesOldPreconditions() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        val before = seam.current
        val receipt = seam.setIsoIndex(0x06)
        seam.linkDidChange()
        assertEquals(CommandStage.OutcomeUnknown, seam.receipt(receipt.operation)?.stage)
        val stale = seam.submit(
            CameraCommand(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(800))), CommandPreconditions(before)),
        )
        assertEquals(CommandStage.Rejected(CommandRejection.StaleEpoch), stale.stage)
    }

    @Test
    fun missingTelemetryStaysUnknown() = runTest {
        val port = FakePort()
        port.state = PocketControlState()
        val snapshot = adapter(port).current
        assertEquals(ConnectionState.Discovered, snapshot.connection)
        assertEquals(ObservedValue.unknown, snapshot.recording)
        assertEquals(PowerStatus.unknown, snapshot.power)
        assertEquals(ObservedValue.unknown, snapshot.storage)
        assertTrue(snapshot.settings.isEmpty())
        assertEquals(
            CommandStage.Rejected(CommandRejection.NotConnected),
            adapter(port).setIsoIndex(0x06).stage,
        )
    }

    /**
     * SHELL-01: what each body publishes and the layout it projects to over an app base that
     * carries only clip delete, clip star and the internet hop (Swift `eachBodyPublishesItsLayout`).
     */
    @Test
    fun eachBodyPublishesItsLayout() = runTest {
        val base = MonitorLayoutCapabilities(clipDelete = true, clipStar = true, requiresInternetHop = true)
        fun expected(gimbal: Boolean, zoom: Boolean, focus: Boolean, iris: Boolean, timecode: Boolean) = base.copy(
            gimbal = gimbal, headTracking = gimbal, zoom = zoom, focus = focus, iris = iris, timecode = timecode, audio = true,
        )
        val bodies = listOf(
            Triple(body("Osmo Pocket 4 Pro", "pocket"), expected(true, true, true, false, true), SupportStatus.SUPPORTED),
            Triple(body("Osmo Pocket 3", "pocket"), expected(true, true, true, false, true), SupportStatus.SUPPORTED),
            Triple(body("Osmo Action 6", "other", aperture = true), expected(false, false, false, true, true), SupportStatus.SUPPORTED),
            Triple(body("Osmo Nano", "nano"), expected(false, false, false, false, false), SupportStatus.UNSUPPORTED),
        )
        for ((model, layout, timecode) in bodies) {
            val port = FakePort()
            port.state = port.state.copy(model = model)
            val seam = adapter(port)
            assertEquals(layout, seam.layout(base), model.name)
            assertEquals(timecode, seam.current.capabilities.timecode, model.name)
            assertEquals(SupportStatus.SUPPORTED, seam.current.capabilities.audioLevels, model.name)
            assertEquals(layout.gimbal, model.motion != null, model.name)
        }
        // No camera: nothing is claimed, so the layout is the base.
        val seam = adapter(FakePort())
        assertEquals(base, seam.layout(base))
        assertEquals(SupportStatus.UNKNOWN, seam.current.capabilities.timecode)
        assertEquals(SupportStatus.UNKNOWN, seam.current.capabilities.audioLevels)
    }

    @Test
    fun pocketGimbalReportsPoseInsideItsReach() {
        assertEquals(SupportStatus.SUPPORTED, pocketGimbal.pose)
        assertEquals(setOf(MotionAxis.PAN, MotionAxis.TILT, MotionAxis.ZOOM), pocketGimbal.axes)
        assertNull(pocketGimbal.target(MotionWaypoint(226.0, 0.0, 1.0)))
        assertNotNull(pocketGimbal.target(MotionWaypoint(225.0, 70.0, 1.0)))
    }

    @Test
    fun timecodeAndAudioLevelsAreCameraReportedOrUnknown() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        assertEquals(ObservedValue.unknown, seam.current.timecode)
        assertEquals(ObservedValue.unknown, seam.current.audioLevels, "no report is unknown, never silence")
        val reported = CameraStatus(
            timecode = "05:22:47:18", audioMetersLeft = -18.0, audioPeakLeft = -12.0,
            audioMetersRight = -20.0, audioPeakRight = -14.0, audioMetersReported = true,
        )
        port.state = port.state.copy(timecode = reported.timecode, audioLevels = DjiCameraSessionAdapter.audioLevels(reported))
        val snapshot = seam.current
        assertEquals(CameraTimecode(5, 22, 47, 18), snapshot.timecode.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, snapshot.timecode.origin)
        assertEquals(AudioLevels(AudioLevels.Channel(-18.0, -12.0), AudioLevels.Channel(-20.0, -14.0)), snapshot.audioLevels.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, snapshot.audioLevels.origin)
        port.state = port.state.copy(timecode = "--:--")
        assertEquals(ObservedValue.unknown, seam.current.timecode)
        // The status JSON the session round-trips through the facade keeps "not reported" apart from silence.
        assertNull(DjiCameraSessionAdapter.audioLevels(CameraStatus.fromJson(CameraStatus().toJson())))
        assertEquals(
            DjiCameraSessionAdapter.audioLevels(reported),
            DjiCameraSessionAdapter.audioLevels(CameraStatus.fromJson(reported.toJson())),
        )
    }

    @Test
    fun wireTimeoutEndsADroppedRequestAsUnknown() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        val receipt = seam.setIsoIndex(0x06)
        testScheduler.advanceTimeBy(seam.wireTimeout + 1.seconds)
        assertEquals(CommandStage.OutcomeUnknown, seam.receipt(receipt.operation)?.stage)
    }

    /** Body flags as the facade sends them (Swift `CameraModel`). */
    private fun body(name: String, family: String, aperture: Boolean = false): CameraModel {
        val pocket = family == "pocket"
        return CameraModel(
            name, family = family, hasGimbal = pocket, supportsZoom = pocket, supportsFocusMode = pocket,
            supportsTapFocus = pocket, supportsAperture = aperture,
        )
    }

    private fun TestScope.adapter(port: FakePort) =
        DjiCameraSessionAdapter(port, backgroundScope) { MonotonicInstant(testScheduler.currentTime.milliseconds) }

    private fun validIntent(key: SettingKey, snapshot: CameraSnapshot): CameraCommandIntent? =
        when (key) {
            SettingKey.RECORDING ->
                if (snapshot.recording.value == RecordingState.RECORDING) {
                    CameraCommandIntent.StopRecording
                } else {
                    CameraCommandIntent.StartRecording
                }
            SettingKey.ISO -> {
                val current = snapshot.value(key).value
                snapshot.capabilities[key]?.domain?.choices?.firstOrNull { it != current }?.let {
                    CameraCommandIntent.Set(it)
                }
            }
            SettingKey.WHITE_BALANCE -> CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(4_300)))
            SettingKey.WHITE_BALANCE_TINT -> CameraCommandIntent.Set(SettingValue.WhiteBalanceTint(12.0))
            // A newly declared key needs a test value here, or this test cannot vouch for it.
            else -> null
        }

    /** A linked Pocket in Video reporting ISO 400, Auto WB and the given record state. */
    private class FakePort(recording: Boolean? = false) : PocketControlPort {
        var state =
            PocketControlState(
                linkReady = true,
                phase = ConnectionPhase.LIVE,
                shootingMode = CameraCommands.SHOOT_VIDEO,
                isoChoices = listOf(0x00, 0x03, 0x04, 0x05, 0x06, 0x07),
                isoIndex = 0x05,
                whiteBalance = ReportedWhiteBalance(CameraCommands.WB_AUTO, 0, 0),
                recording = recording,
            )
        val fired = mutableListOf<String>()
        var note: String? = null
        private var stage: ((ControlWireEvent) -> Unit)? = null

        fun answer(event: ControlWireEvent) {
            stage?.invoke(event)
        }

        private fun fire(name: String, onStage: ((ControlWireEvent) -> Unit)?) {
            fired += name
            stage = onStage
            onStage?.invoke(ControlWireEvent.SENT)
        }

        override fun controlState() = state

        override fun setIsoIndex(index: Int, onStage: ((ControlWireEvent) -> Unit)?) = fire("iso $index", onStage)

        override fun setWhiteBalanceAuto(tint: Int?, onStage: ((ControlWireEvent) -> Unit)?) =
            fire("wb auto $tint", onStage)

        override fun setWhiteBalance(kelvin: Int, tint: Int, onStage: ((ControlWireEvent) -> Unit)?) =
            fire("wb $kelvin $tint", onStage)

        override fun setRecording(start: Boolean, onStage: ((ControlWireEvent) -> Unit)?) =
            fire("record $start", onStage)

        override fun takePhoto() {
            fired += "photo"
        }

        override fun noteControlRejection(note: String) {
            this.note = note
        }
    }
}
