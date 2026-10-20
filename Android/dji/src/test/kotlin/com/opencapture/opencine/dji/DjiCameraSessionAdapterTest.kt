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
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.motion.GimbalWaypoint
import com.opencapture.opencine.motion.MotionAxis

import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.EvComp
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
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
    @Test fun recordingFactsUseReportedDimensionsAndNeverPreviewCodec() = runTest {
        val port = FakePort()
        port.capture = DjiCaptureControlState(CameraStatus(resolutionCode = 0x67, fps = 25,
            colorMode = CameraCommands.COLOR_DLOG2, expoMode = CameraCommands.EXPO_MANUAL), port.state.model)
        val seam = adapter(port)
        val format = seam.current.recordingFormat
        assertEquals(com.opencapture.opencine.core.CameraExposureProgram.MANUAL, seam.current.exposureProgram.value)
        assertEquals(com.opencapture.opencine.core.CameraRecordingFormat.Dimensions.measured(3840, 2880), format.dimensions.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, format.dimensions.origin)
        assertEquals("D-Log2", format.profile.value)
        assertNull(format.codec.value, "The preview codec does not declare the recording codec")
        port.capture = DjiCaptureControlState(CameraStatus(resolutionCode = 0xFF), port.state.model)
        assertEquals(com.opencapture.opencine.core.CameraRecordingObservations.unknown, seam.current.recordingFormat)
        assertNull(seam.current.exposureProgram.value)
        assertTrue(port.fired.isEmpty())
    }

    /** SIMULATED Nano and Pocket reports: the recording profile reads in each body's colour names. */
    @Test fun recordingProfileUsesTheBodyColourNames() = runTest {
        for ((family, expected) in listOf("nano" to "D-Log M 10-bit", "pocket" to "D-Log M")) {
            val port = FakePort()
            val base = CameraModel(name = "SIMULATED $family", family = family)
            val model = base.copy(captureProfile = DjiCaptureCapabilityProfile.make(base))
            port.state = port.state.copy(model = model)
            port.capture = DjiCaptureControlState(CameraStatus(colorMode = CameraCommands.COLOR_DLOG_M), model)
            assertEquals(expected, adapter(port).current.recordingFormat.profile.value, family)
        }
    }

    /** SIMULATED existing captured report: a known true charge flag must reach common power. */
    @Test fun batteryChargingReportsReachCommonPower() = runTest {
        val port = FakePort()
        port.state = port.state.copy(batteryPercent = 68)
        port.capture = DjiCaptureControlState(CameraStatus(charging = true, batteryPercent = 68), port.state.model)
        val seam = adapter(port)
        assertEquals(true, seam.current.power.charging.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, seam.current.power.charging.origin)
        for (reported in listOf(false, true, null)) {
            port.capture = DjiCaptureControlState(CameraStatus(charging = true, batteryPercent = 68,
                chargingObservation = reported, chargingObservationDeclared = true), port.state.model)
            assertEquals(reported, seam.current.power.charging.value)
        }
    }

    @Test fun legacyTimecodeHelpersRetainSupportAndCompleteFrames() {
        val support: SupportStatus = DjiCameraSessionAdapter.timecodeSupport(null)
        assertEquals(SupportStatus.UNKNOWN, support)
        assertEquals(TimecodeCapability.unknown, DjiCameraSessionAdapter.timecodeCapability(null))
        val value = assertNotNull(DjiCameraSessionAdapter.timecode("05:22:47:18"))
        val frames: Int = value.frames
        assertEquals(18, frames)
        assertNull(DjiCameraSessionAdapter.timecode("05:22:47"))
    }

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
    fun captureCapabilitiesUseActualReportsAndReachThePort() = runTest {
        val targets = listOf(
            SettingValue.Shutter(ShutterValue.Duration(Rational(1, 100))) to "shutter 100",
            SettingValue.ExposureCompensation(Rational(2, 3)) to "ev 2",
            SettingValue.FocusMode(com.opencapture.opencine.core.FocusMode.CONTINUOUS) to "focus 2",
            SettingValue.Zoom(2.0) to "zoom 2.0",
        )
        for ((value, call) in targets) {
            val port = capturePort()
            val seam = adapter(port)
            val receipt = seam.request(CameraCommandIntent.Set(value))
            assertEquals(CommandStage.Sent, receipt.stage)
            assertEquals(listOf(call), port.fired)
            port.answer(ControlWireEvent.CONFIRMED)
            assertEquals(CommandStage.AwaitingObservation, seam.receipt(receipt.operation)?.stage)
            assertTrue(seam.current.value(value.key).value != value)
        }
    }

    @Test
    fun optimisticFocusCannotConfirmOrReplaceReportedFocus() = runTest {
        val port = capturePort()
        val seam = adapter(port)
        val receipt = seam.request(CameraCommandIntent.Set(
            SettingValue.FocusMode(com.opencapture.opencine.core.FocusMode.CONTINUOUS)))
        // The legacy HUD changed, but the separate actual capture report did not.
        port.presentation = assertNotNull(port.capture).reported.copy(focusMode = CameraCommands.FOCUS_CONTINUOUS)
        seam.sessionDidChange()
        assertEquals(CommandStage.Sent, seam.receipt(receipt.operation)?.stage)
        assertEquals(SettingValue.FocusMode(com.opencapture.opencine.core.FocusMode.SINGLE),
            seam.current.value(SettingKey.FOCUS_MODE).value)
        val capture = assertNotNull(port.capture)
        port.capture = capture.copy(reported = capture.reported.copy(focusMode = CameraCommands.FOCUS_CONTINUOUS))
        seam.sessionDidChange()
        assertEquals(CommandStage.Confirmed, seam.receipt(receipt.operation)?.stage)
    }

    /** A control model that binds after the session changed starts from it, as on iOS. */
    @Test
    fun lateFollowerStartsFromTheSessionAsItIsNow() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        port.state = port.state.copy(isoIndex = 0x06)
        seam.sessionDidChange() // nobody follows yet: nothing is rebuilt
        val seen = mutableListOf<CameraSnapshot>()
        val follower = launch(start = CoroutineStart.UNDISPATCHED) { seam.snapshots.collect { seen += it } }
        val first = seen.first()
        assertEquals(ConnectionState.Ready, first.connection)
        assertNotNull(first.capabilities[SettingKey.ISO], "The first snapshot describes the camera")
        assertEquals(seam.current.value(SettingKey.ISO), first.value(SettingKey.ISO))
        follower.cancel()
    }

    @Test
    fun actualZoomReportCanConfirmBeforeAnAck() = runTest {
        val port = capturePort()
        val seam = adapter(port)
        val receipt = seam.request(CameraCommandIntent.Set(SettingValue.Zoom(2.0)))
        val capture = assertNotNull(port.capture)
        port.capture = capture.copy(reported = capture.reported.copy(zoomFactor = 2.0))
        seam.sessionDidChange()
        assertEquals(CommandStage.Confirmed, seam.receipt(receipt.operation)?.stage)
        port.answer(ControlWireEvent.REFUSED)
        assertEquals(CommandStage.Confirmed, seam.receipt(receipt.operation)?.stage)
    }

    @Test
    fun changedCaptureDomainRejectsQueuedEdit() = runTest {
        val port = capturePort()
        val seam = adapter(port)
        val command = CameraCommand(CameraCommandIntent.Set(
            SettingValue.Shutter(ShutterValue.Duration(Rational(1, 100)))), CommandPreconditions(seam.current))
        val capture = assertNotNull(port.capture)
        port.capture = capture.copy(reported = capture.reported.copy(availableShutterDenoms = listOf(50)))
        assertEquals(CommandStage.Rejected(CommandRejection.StaleCapabilities), seam.submit(command).stage)
        assertTrue(port.fired.isEmpty())
    }

    @Test
    fun commonShutterNeverChangesExposureModeImplicitly() = runTest {
        val port = capturePort()
        val capture = assertNotNull(port.capture)
        port.capture = capture.copy(reported = capture.reported.copy(expoMode = CameraCommands.EXPO_AUTO))
        val seam = adapter(port)
        assertEquals(CommandStage.Rejected(CommandRejection.Unavailable(
            com.opencapture.opencine.core.UnavailableReason.Mode)),
            seam.request(CameraCommandIntent.Set(SettingValue.Shutter(
                ShutterValue.Duration(Rational(1, 100))))).stage)
        assertTrue(port.fired.isEmpty())
    }

    @Test
    fun captureUnknownsStayNilAndMechanicalIrisIsReadOnly() = runTest {
        val port = capturePort()
        val model = CameraModel(name = "Osmo Action 6", family = "other",
            supportsFocusMode = false, supportsZoom = false, hasGimbal = false, supportsAperture = true)
        port.state = port.state.copy(model = model)
        port.capture = DjiCaptureControlState(CameraStatus(), model)
        val seam = adapter(port)
        for (key in listOf(SettingKey.SHUTTER, SettingKey.EXPOSURE_COMPENSATION,
            SettingKey.FOCUS_MODE, SettingKey.ZOOM, SettingKey.APERTURE)) {
            assertNull(seam.current.value(key).value)
        }
        port.capture = DjiCaptureControlState(CameraStatus(irisHundredths = 280), model)
        assertEquals(SettingValue.Aperture(2.8), seam.current.value(SettingKey.APERTURE).value)
        assertEquals(CommandStage.Rejected(CommandRejection.ReadOnly),
            seam.request(CameraCommandIntent.Set(SettingValue.Aperture(2.0))).stage)
        assertTrue(port.fired.isEmpty())
    }

    /** A5-09: the recording rate is a typed read-only Rational from the wire index, never written. */
    @Test
    fun recordingFrameRateIsAReadOnlyRational() = runTest {
        val port = capturePort()
        val seam = adapter(port)
        assertEquals(SettingAccess.READ_ONLY, seam.current.capabilities[SettingKey.FRAME_RATE]?.access)
        assertNull(seam.current.value(SettingKey.FRAME_RATE).value, "no report is unknown")
        port.capture = port.capture?.let { it.copy(reported = it.reported.copy(fps = 25)) }
        assertEquals(SettingValue.FrameRate(Rational(25)), seam.current.value(SettingKey.FRAME_RATE).value)
        assertEquals(CommandStage.Rejected(CommandRejection.ReadOnly),
            seam.request(CameraCommandIntent.Set(SettingValue.FrameRate(Rational(24)))).stage)
        assertTrue(port.fired.isEmpty())
    }

    /**
     * Behavior audit PAA-210 / PIA-211: Pocket 3 publishes no `camcap_shutter`. The standalone apps
     * offered the documented video ladder (with the live 1/N merged in) and sent any of it.
     */
    @Test
    fun emptyShutterCapOffersTheDocumentedLadderAndWrites() = runTest {
        val port = capturePort()
        val capture = assertNotNull(port.capture)
        port.capture = capture.copy(reported = capture.reported.copy(availableShutterDenoms = emptyList(),
            shootingMode = CameraCommands.SHOOT_VIDEO, fps = 25))
        val seam = adapter(port)
        val shutter = assertNotNull(seam.current.capabilities[SettingKey.SHUTTER])
        assertEquals(SettingAccess.READ_WRITE, shutter.access)
        assertEquals(CameraCommands.shutterWheelDenoms(emptyList(), 50).map {
            SettingValue.Shutter(ShutterValue.Duration(Rational(1, it)))
        }, shutter.domain?.choices)
        assertTrue(assertNotNull(port.capture).admitsShutterWrite(100))
        assertEquals(CommandStage.Sent, seam.request(CameraCommandIntent.Set(
            SettingValue.Shutter(ShutterValue.Duration(Rational(1, 100))))).stage)
        assertEquals(listOf("shutter 100"), port.fired)
        // The Angle preference maps onto the same ladder (180 degrees at 25p is 1/50).
        port.capture = assertNotNull(port.capture).copy(
            shutterPresentation = com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
        assertEquals(CommandStage.Sent, adapter(port).request(CameraCommandIntent.Set(
            SettingValue.Shutter(ShutterValue.Angle(180.0)))).stage)
        assertEquals("angle 180.0 1/50", port.fired.last())
    }

    /**
     * The Pocket path pins the same rule as the Luna: the wire carries whole 1/N, 180 degrees sends
     * the ladder's nearest speed per rate and the projected angle is what it really makes. Swift twin.
     */
    @Test
    fun angleSendsTheNearestLadderSpeedPerRate() = runTest {
        for ((fps, denom) in listOf(24 to 48, 25 to 50, 30 to 60, 60 to 120, 120 to 250)) {
            val port = capturePort()
            val capture = assertNotNull(port.capture)
            port.capture = capture.copy(reported = capture.reported.copy(availableShutterDenoms = emptyList(),
                shootingMode = CameraCommands.SHOOT_VIDEO, fps = fps),
                shutterPresentation = com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
            assertEquals(CommandStage.Sent, adapter(port).request(CameraCommandIntent.Set(
                SettingValue.Shutter(ShutterValue.Angle(180.0)))).stage, "$fps fps")
            assertEquals("angle 180.0 1/$denom", port.fired.last(), "$fps fps")
            val held = assertNotNull(port.capture)
            port.capture = held.copy(reported = held.reported.copy(shutterDenom = denom))
            val shown = (adapter(port).current.value(SettingKey.SHUTTER).value as SettingValue.Shutter).value as ShutterValue.Angle
            assertEquals(360.0 * fps / denom, shown.degrees, 1e-9, "$fps fps")
        }
    }

    /**
     * Behavior audit PAA-211: the Angle preference is a video presentation. In Photo the standalone
     * apps forced the Speed tab and a 1/N readout, so the common shutter stays a duration.
     */
    @Test
    fun photoModeKeepsShutterDurationsUnderTheAnglePreference() = runTest {
        val port = capturePort()
        val capture = assertNotNull(port.capture)
        port.capture = capture.copy(
            reported = capture.reported.copy(shootingMode = CameraCommands.SHOOT_PHOTO, fps = 25),
            shutterPresentation = com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
        val seam = adapter(port)
        val shutter = assertNotNull(seam.current.capabilities[SettingKey.SHUTTER])
        assertEquals(com.opencapture.opencine.core.Availability.Available, shutter.availability)
        assertEquals(listOf(50, 100).map { SettingValue.Shutter(ShutterValue.Duration(Rational(1, it))) },
            shutter.domain?.choices)
        assertEquals(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 50))),
            seam.current.value(SettingKey.SHUTTER).value)
        assertEquals(CommandStage.Sent, seam.request(CameraCommandIntent.Set(
            SettingValue.Shutter(ShutterValue.Duration(Rational(1, 100))))).stage)
        assertEquals(listOf("shutter 100"), port.fired)
    }

    private fun capturePort(): FakePort {
        val port = FakePort()
        val model = djiBodyProfile("Osmo Pocket 3")
        port.state = port.state.copy(model = model)
        port.capture = DjiCaptureControlState(CameraStatus(
            expoMode = CameraCommands.EXPO_MANUAL, shutterDenom = 50,
            availableShutterDenoms = listOf(50, 100), evComp = EvComp.ZERO.rawValue,
            focusMode = CameraCommands.FOCUS_SINGLE, zoomFactor = 1.0,
        ), model)
        return port
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
        val seconds = TimecodeCapability.supported(TimecodePrecision.Seconds)
        val bodies = listOf(
            Triple(body("Osmo Pocket 4 Pro", "pocket"), expected(true, true, true, false, true), seconds),
            Triple(body("Osmo Pocket 3", "pocket"), expected(true, true, true, false, true), seconds),
            Triple(body("Osmo Action 6", "other", aperture = true), expected(false, false, false, true, true), seconds),
            Triple(body("Osmo Nano", "nano"), expected(false, false, false, false, false), TimecodeCapability.unsupported),
        )
        for ((model, layout, timecode) in bodies) {
            val port = FakePort()
            port.state = port.state.copy(model = model)
            val seam = adapter(port)
            assertEquals(layout, seam.layout(base), model.name)
            assertEquals(timecode, seam.current.capabilities.timecodeCapability, model.name)
            assertEquals(SupportStatus.SUPPORTED, seam.current.capabilities.audioLevels, model.name)
            assertEquals(layout.gimbal, model.motion != null, model.name)
        }
        // No camera: nothing is claimed, so the layout is the base.
        val seam = adapter(FakePort())
        assertEquals(base, seam.layout(base))
        assertEquals(TimecodeCapability.unknown, seam.current.capabilities.timecodeCapability)
        assertEquals(SupportStatus.UNKNOWN, seam.current.capabilities.audioLevels)
    }

    @Test
    fun pocketGimbalReportsPoseInsideItsReach() {
        assertEquals(SupportStatus.SUPPORTED, pocketGimbal.pose)
        assertEquals(setOf(MotionAxis.PAN, MotionAxis.TILT, MotionAxis.ZOOM), pocketGimbal.axes)
        assertNull(pocketGimbal.target(GimbalWaypoint(226.0, 0.0, 1.0)))
        assertNotNull(pocketGimbal.target(GimbalWaypoint(225.0, 70.0, 1.0)))
    }

    @Test
    fun timecodeAndAudioLevelsAreCameraReportedOrUnknown() = runTest {
        val port = FakePort()
        val seam = adapter(port)
        assertEquals(ObservedValue.unknown, seam.current.timecode)
        assertEquals(ObservedValue.unknown, seam.current.audioLevels, "no report is unknown, never silence")
        val reported = CameraStatus(
            audioMetersLeft = -18.0, audioPeakLeft = -12.0,
            audioMetersRight = -20.0, audioPeakRight = -14.0, audioMetersReported = true,
        ).withTimecodeValue(CameraTimecode(5, 22, 47, 18))
        port.state = port.state.copy(timecode = reported.timecodeValue, audioLevels = DjiCameraSessionAdapter.audioLevels(reported))
        val snapshot = seam.current
        assertEquals(CameraTimecode(5, 22, 47, 18), snapshot.timecode.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, snapshot.timecode.origin)
        assertEquals(AudioLevels(AudioLevels.Channel(-18.0, -12.0), AudioLevels.Channel(-20.0, -14.0)), snapshot.audioLevels.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, snapshot.audioLevels.origin)
        port.state = port.state.copy(timecode = null)
        assertEquals(ObservedValue.unknown, seam.current.timecode)
        // The facade JSON carries the decoded fields, never a display string to re-parse.
        assertEquals(CameraTimecode(5, 22, 47, 18), CameraStatus.fromJson(reported.toJson()).timecodeValue)
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
    internal class FakePort(recording: Boolean? = false) : PocketControlPort {
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
        var capture: DjiCaptureControlState? = null
        var presentation: CameraStatus = CameraStatus()
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

        override fun captureControlState() = capture
        override fun writeShutter(denominator: Int, onStage: (ControlWireEvent) -> Unit) =
            fire("shutter $denominator", onStage)
        override fun writeHostShutterAngle(degrees: Double, denominator: Int, admission: DjiCommandAdmission?,
            onStage: (ControlWireEvent) -> Unit) = fire("angle $degrees 1/$denominator", onStage)
        override fun writeExposureCompensation(value: EvComp, onStage: (ControlWireEvent) -> Unit) =
            fire("ev ${value.thirds}", onStage)
        override fun writeFocusMode(continuous: Boolean, onStage: (ControlWireEvent) -> Unit) =
            fire("focus ${if (continuous) 2 else 1}", onStage)
        override fun writeZoom(ratio: Double, onStage: (ControlWireEvent) -> Unit) =
            fire("zoom $ratio", onStage)

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
