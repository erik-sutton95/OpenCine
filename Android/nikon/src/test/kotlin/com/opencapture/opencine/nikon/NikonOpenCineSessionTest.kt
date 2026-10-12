package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.WhiteBalanceValue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * CORE-02: the Nikon slice behind the OpenCine Kotlin `CameraSession`, over a fake of the monitor's
 * session. The fake accepts only what the Swift core would encode.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class NikonOpenCineSessionTest {
    @Test
    fun `movie exposure preserves native labels and only writes the active circuit`() = runTest {
        val properties = movie().copy(
            shutterMode = CameraShutterMode.SPEED,
            shutterSpeed = "2/100", shutterAngle = "180°", iris = "f/2.8",
            controlCapabilities = movie().controlCapabilities.copy(
                shutterValues = listOf("2/100", "1/100", "180°", "1/0", "Bulb"),
                irisValues = listOf("f/2.8", "f/4.0", "f/NaN", "unknown"),
                advertisedIrisValues = listOf("f/2.8", "f/4.0", "f/NaN", "unknown"),
            ),
        )
        val native = FakeNikon(properties)
        val seam = NikonOpenCineSession(native, backgroundScope)
        assertEquals(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 50))), seam.refresh().value(SettingKey.SHUTTER).value)
        assertEquals(SettingValue.Aperture(2.8), seam.refresh().value(SettingKey.APERTURE).value)
        assertEquals(CommandStage.Rejected(CommandRejection.OutOfDomain), seam.request(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Angle(180.0)))).stage)
        assertEquals(CommandStage.Rejected(CommandRejection.OutOfDomain), seam.request(CameraCommandIntent.Set(SettingValue.Aperture(5.6))).stage)
        assertTrue(native.writes.isEmpty())

        assertEquals(CommandStage.Confirmed, seam.request(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 50))))).stage)
        assertEquals(CommandStage.Confirmed, seam.request(CameraCommandIntent.Set(SettingValue.Aperture(4.0))).stage)
        assertEquals(listOf(CameraControl.SHUTTER to "2/100", CameraControl.IRIS to "f/4.0"), native.writes)
        assertEquals(SettingValue.Aperture(2.8), seam.refresh().value(SettingKey.APERTURE).value)
        seam.closeNow(SessionCloseReason.REQUESTED)
    }

    @Test
    fun `mode changes retire exposure edits and locked or unknown circuits cannot write`() = runTest {
        val properties = movie().copy(
            shutterMode = CameraShutterMode.SPEED, shutterSpeed = "1/50", shutterAngle = "180°",
            controlCapabilities = movie().controlCapabilities.copy(shutterValues = listOf("1/50", "1/100", "180°")),
        )
        val native = FakeNikon(properties)
        val seam = NikonOpenCineSession(native, backgroundScope)
        val stale = CameraCommand(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 100)))), CommandPreconditions(seam.refresh()))
        native.cameraProperties.value = properties.copy(shutterMode = CameraShutterMode.ANGLE)
        assertEquals(CommandStage.Rejected(CommandRejection.StaleCapabilities), seam.submit(stale).stage)
        native.cameraProperties.value = native.cameraProperties.value.copy(shutterLocked = true)
        assertEquals(CommandStage.Rejected(CommandRejection.Unavailable(UnavailableReason.Busy)), seam.request(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Angle(180.0)))).stage)
        native.cameraProperties.value = native.cameraProperties.value.copy(captureSelector = "photo")
        assertNull(seam.refresh().value(SettingKey.SHUTTER).value)
        assertEquals(CommandStage.Rejected(CommandRejection.SupportUnknown), seam.request(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Angle(180.0)))).stage)
        assertTrue(native.writes.isEmpty())
        val unknown = properties.copy(shutterMode = null, iris = null)
        assertNull(NikonExposureSettings.reported(unknown)[SettingKey.SHUTTER])
        assertTrue(NikonExposureSettings.descriptors(unknown).isEmpty())
        seam.closeNow(SessionCloseReason.REQUESTED)
    }

    @Test
    fun `legacy lens fallback stays visible without authorizing common aperture writes`() = runTest {
        val properties = movie().copy(
            iris = "f/2.8",
            controlCapabilities = movie().controlCapabilities.copy(irisValues = listOf("f/2.8", "f/4.0")),
        )
        val native = FakeNikon(properties)
        val seam = NikonOpenCineSession(native, backgroundScope)
        assertEquals(SettingValue.Aperture(2.8), seam.refresh().value(SettingKey.APERTURE).value)
        assertTrue(seam.refresh().capabilities[SettingKey.APERTURE]!!.domain!!.choices.isEmpty())
        assertEquals(CommandStage.Rejected(CommandRejection.Unavailable(UnavailableReason.NotReady)),
            seam.request(CameraCommandIntent.Set(SettingValue.Aperture(4.0))).stage)
        assertTrue(native.writes.isEmpty())
        native.cameraProperties.value = properties.copy(controlCapabilities = properties.controlCapabilities.copy(
            advertisedIrisValues = listOf("f/4.0")))
        assertEquals(CommandStage.Rejected(CommandRejection.OutOfDomain),
            seam.request(CameraCommandIntent.Set(SettingValue.Aperture(2.8))).stage)
        assertEquals(CommandStage.Confirmed, seam.request(CameraCommandIntent.Set(SettingValue.Aperture(4.0))).stage)
        assertEquals(listOf(CameraControl.IRIS to "f/4.0"), native.writes)
        seam.closeNow(SessionCloseReason.REQUESTED)
    }

    private class FakeNikon(properties: CameraPropertySnapshot, reported: Boolean? = false) : CameraSession {
        override val state =
            MutableStateFlow<CameraSessionState>(
                CameraSessionState.Connected(CameraIdentity("ZR", "ZR", "3000123")),
            )
        override val recordingState = MutableStateFlow(CameraRecordingState.STANDBY)
        override val reportedRecording = MutableStateFlow(reported)
        override val liveTimecode = MutableStateFlow<CameraTimecode?>(null)
        override val cameraProperties = MutableStateFlow(properties)
        val writes = mutableListOf<Pair<CameraControl, String>>()
        val records = mutableListOf<Boolean>()
        var controlFailure: CameraControlException? = null

        override suspend fun connect() = Unit

        override suspend fun disconnect() = Unit

        override suspend fun setRecording(recording: Boolean) {
            records += recording
        }

        override suspend fun applyControl(control: CameraControl, label: String) {
            // The Swift core's `androidControlWrites` rule: an advertised label, any numeric ISO,
            // a Kelvin label while the body offers Kelvin, or anything before descriptors land.
            val advertised = cameraProperties.value.controlCapabilities.options(control)
            val encodes =
                advertised.isEmpty() ||
                    label in advertised ||
                    (control == CameraControl.ISO && label.toIntOrNull() != null) ||
                    (
                        control == CameraControl.WHITE_BALANCE &&
                            WbPickerPolicy.isKelvinLabel(label) &&
                            advertised.any(WbPickerPolicy::isKelvinLabel)
                    )
            if (!encodes) throw CameraControlException.UnsupportedSelection
            controlFailure?.let { throw it }
            writes += control to label
        }
    }

    /** A ZR in movie mode, exposure M, H.265, with the Swift-authorized domains. */
    private fun movie(codec: String = "H.265 10-bit MOV") =
        CameraPropertySnapshot(
            iso = 800,
            isoAuto = false,
            exposureMode = "M",
            whiteBalanceMode = "Auto",
            whiteBalanceKelvin = 5560,
            codec = codec,
            batteryPercent = 80,
            captureSelector = "video",
            controlCapabilities =
                CameraControlCapabilities(
                    isoValues = listOf("200", "800", "6400", "25600"),
                    whiteBalanceValues = listOf("Auto", "Natural auto", "Sunny", "2500K", "5560K", "10000K"),
                ),
        )

    /**
     * A5-04: the header sequence reaches the common snapshot with frames at the body's movie rate. A
     * per-frame change moves only the timecode and the revision; off, absent, or off the link is
     * unknown, never a frozen counter.
     */
    @Test
    fun headerTimecodePublishesFramesAndNeverFreezes() =
        runTest {
            val camera = FakeNikon(movie().copy(frameRate = 25))
            val seam = NikonOpenCineSession(camera, backgroundScope)
            val idle = seam.snapshots.value
            assertNull(idle.timecode.value)
            assertEquals(TimecodeCapability.supported(TimecodePrecision.Frames(Rational(25))), idle.capabilities.timecode)

            camera.liveTimecode.value = CameraTimecode(1, 2, 3, frames = 17)
            runCurrent()
            val first = seam.snapshots.value
            assertEquals(CameraTimecode(1, 2, 3, frames = 17), first.timecode.value)
            assertEquals(ObservationOrigin.CAMERA_REPORTED, first.timecode.origin)
            camera.liveTimecode.value = CameraTimecode(1, 2, 3, frames = 18)
            runCurrent()
            val advanced = seam.snapshots.value
            assertEquals(CameraTimecode(1, 2, 3, frames = 18), advanced.timecode.value)
            assertEquals(first.revision.next(), advanced.revision)
            assertTrue(advanced.capabilities === first.capabilities)
            assertEquals(first, advanced.copy(revision = first.revision, timecode = first.timecode))

            // The runtime publishes an off header (digits or zeros) and a header-less frame as null.
            camera.liveTimecode.value = null
            runCurrent()
            assertNull(seam.snapshots.value.timecode.value)

            camera.liveTimecode.value = CameraTimecode(1, 2, 3, frames = 19)
            runCurrent()
            camera.state.value = CameraSessionState.Disconnected
            runCurrent()
            assertNull(seam.snapshots.value.timecode.value, "unknown off the link even if the source lags")

            camera.cameraProperties.value = movie().copy(frameRate = 0)
            assertEquals(TimecodeCapability.supported(null), seam.refresh().capabilities.timecode)
            seam.closeNow(SessionCloseReason.REQUESTED)
        }

    /** A5-01: Nikon `BatteryLevel` is a five-step gauge, so the reading declares fifths. */
    @Test
    fun batteryDeclaresFiveSteps() =
        runTest {
            val seam = NikonOpenCineSession(FakeNikon(movie()), backgroundScope)
            val battery = seam.refresh().power.battery
            assertEquals(0.8, battery.value)
            assertEquals(ObservationPrecision.Quantized(0.2), battery.precision)
            seam.closeNow(SessionCloseReason.REQUESTED)
            // The value sits on the body's steps: an undocumented level rounds up, no reading is unknown.
            assertEquals(0.6, NikonOpenCineSession.batteryFraction(58))
            assertEquals(0.2, NikonOpenCineSession.batteryFraction(1))
            assertNull(NikonOpenCineSession.batteryFraction(0))
        }

    @Test
    fun ownedCloseHookRunsOnceWithoutRecordCommands() = runTest {
        val camera = FakeNikon(movie())
        var closes = 0
        val seam = NikonOpenCineSession(camera, backgroundScope, onClose = { closes++ })
        seam.closeNow(SessionCloseReason.REQUESTED)
        seam.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(1, closes)
        assertTrue(camera.records.isEmpty())
        assertTrue(camera.writes.isEmpty())
    }

    @Test
    fun authorityLossRefusesControlsWithoutChangingReports() = runTest {
        val camera = FakeNikon(movie())
        val seam = NikonOpenCineSession(camera, backgroundScope)
        val reported = seam.snapshots.value.value(SettingKey.ISO)
        seam.setHoldsControl(false)
        val command = seam.request(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(6400))))
        assertEquals(CommandStage.Rejected(CommandRejection.NoAuthority), command.stage)
        assertEquals(reported, seam.snapshots.value.value(SettingKey.ISO))
        assertTrue(camera.writes.isEmpty())
        seam.setHoldsControl(true)
        assertEquals(com.opencapture.opencine.core.ControlAuthority.Owner, seam.snapshots.value.authority)
    }

    @Test
    fun everyAdvertisedValueReachesTheNativeCore() =
        runTest {
            val photo = movie().copy(captureSelector = "photo")
            for (properties in listOf(movie(), movie("R3D NE 12-bit R3D"), photo)) {
                val camera = FakeNikon(properties)
                val seam = NikonOpenCineSession(camera, backgroundScope)
                for (descriptor in seam.snapshots.value.capabilities.descriptors.values) {
                    if (descriptor.access != SettingAccess.READ_WRITE) continue
                    val domain = descriptor.domain
                    if (domain == null) {
                        assertEquals(SettingKey.RECORDING, descriptor.key)
                        val start = seam.request(CameraCommandIntent.StartRecording)
                        assertEquals(CommandStage.AwaitingObservation, start.stage)
                        assertEquals(listOf(true), camera.records)
                        continue
                    }
                    assertTrue(domain.choices.isNotEmpty(), "${descriptor.key} advertises an empty domain")
                    val bounds =
                        domain.range?.let { listOf(it.start, it.endInclusive) }.orEmpty().map {
                            SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(it.toInt()))
                        }
                    for (value in domain.choices + bounds) {
                        val receipt = seam.request(CameraCommandIntent.Set(value))
                        if (descriptor.key == SettingKey.ISO && properties === photo) {
                            val photoISO = CommandRejection.Unavailable(UnavailableReason.Mode)
                            assertEquals(CommandStage.Rejected(photoISO), receipt.stage)
                        } else {
                            assertEquals(CommandStage.Confirmed, receipt.stage, "$value never reached the core")
                        }
                    }
                }
            }
            // An advertised value the core cannot take never reports progress.
            val camera = FakeNikon(movie())
            camera.controlFailure = CameraControlException.UnsupportedSelection
            val seam = NikonOpenCineSession(camera, backgroundScope)
            val iso = SettingValue.Iso(ISOValue.Manual(800))
            assertEquals(CommandStage.Failed(CommandFailure.NOT_SENT), seam.request(CameraCommandIntent.Set(iso)).stage)
        }

    @Test
    fun readbackDecidesTheOutcome() =
        runTest {
            val camera = FakeNikon(movie())
            val seam = NikonOpenCineSession(camera, backgroundScope)
            val kelvin = CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5560)))
            assertEquals(CommandStage.Confirmed, seam.request(kelvin).stage)
            assertEquals(CameraControl.WHITE_BALANCE to "5560K", camera.writes.last())

            camera.controlFailure = CameraControlException.ReadbackMismatch
            assertEquals(CommandStage.Failed(CommandFailure.NOT_APPLIED), seam.request(kelvin).stage)
            assertFailsWith<CameraControlException.ReadbackMismatch> {
                seam.applyControl(CameraControl.ISO, "6400")
            }
            camera.controlFailure = CameraControlException.TransportFailed
            assertEquals(CommandStage.OutcomeUnknown, seam.request(kelvin).stage)
            camera.controlFailure = CameraControlException.CommandRejected
            assertEquals(CommandStage.Rejected(CommandRejection.CameraRefused), seam.request(kelvin).stage)

            // Off every domain the core would encode: never sent at all.
            val off = CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(40000)))
            assertEquals(CommandStage.Rejected(CommandRejection.OutOfDomain), seam.request(off).stage)
        }

    @Test
    fun theDomainCoversWhatTheMonitorOffersAndTheCoreEncodes() =
        runTest {
            // Auto parked ISO off the ladder; leaving Auto writes that value back.
            val parked = movie().copy(iso = 51200)
            val seam = NikonOpenCineSession(FakeNikon(parked), backgroundScope)
            val iso = seam.snapshots.value.capabilities[SettingKey.ISO]!!
            assertTrue(iso.accepts(SettingValue.Iso(ISOValue.Manual(51200))))
            // Before descriptors land the picker ladder and presets stay writable, as in the core.
            val bare = movie().copy(controlCapabilities = CameraControlCapabilities())
            val early = NikonOpenCineSession(FakeNikon(bare), backgroundScope).snapshots.value.capabilities
            assertTrue(early[SettingKey.ISO]!!.accepts(SettingValue.Iso(ISOValue.Manual(3200))))
            val earlyWB = early[SettingKey.WHITE_BALANCE]!!
            assertTrue(earlyWB.accepts(SettingValue.WhiteBalance(WhiteBalanceValue.Preset("Shade"))))
            assertTrue(earlyWB.accepts(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5570))))
            // Presets only: no Kelvin is invented.
            val presetsOnly =
                movie().copy(
                    controlCapabilities = CameraControlCapabilities(whiteBalanceValues = listOf("Auto", "Sunny")),
                )
            val wb = NikonOpenCineSession(FakeNikon(presetsOnly), backgroundScope).snapshots.value.capabilities
            val presetWB = wb[SettingKey.WHITE_BALANCE]!!
            assertFalse(presetWB.accepts(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5560))))
        }

    @Test
    fun aReportedExposureWithoutWriteChoicesStaysVisibleAndUnavailable() = runTest {
        val camera = FakeNikon(movie().copy(
            shutterMode = CameraShutterMode.SPEED, shutterSpeed = "1/50", iris = "f/2.8",
            controlCapabilities = CameraControlCapabilities(),
        ))
        val seam = NikonOpenCineSession(camera, backgroundScope)
        assertEquals(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 50))),
            seam.snapshots.value.value(SettingKey.SHUTTER).value)
        assertEquals(SettingValue.Aperture(2.8), seam.snapshots.value.value(SettingKey.APERTURE).value)
        assertEquals(CommandStage.Rejected(CommandRejection.Unavailable(UnavailableReason.NotReady)),
            seam.request(CameraCommandIntent.Set(SettingValue.Aperture(2.8))).stage)
        assertTrue(camera.writes.isEmpty())
    }

    @Test
    fun confirmedTargetIsHonoredAndUnknownStaysUnknown() =
        runTest {
            // The camera already reports the target: nothing reaches the wire.
            val recording = FakeNikon(movie(), reported = true)
            val seam = NikonOpenCineSession(recording, backgroundScope)
            assertEquals(CommandStage.Confirmed, seam.request(CameraCommandIntent.StartRecording).stage)
            assertTrue(recording.records.isEmpty())

            // No live-view header yet: recording is unknown even though the shell says STANDBY,
            // and settings still work with no picture behind them.
            val fresh = FakeNikon(movie(), reported = null)
            val unknown = NikonOpenCineSession(fresh, backgroundScope)
            assertFalse(unknown.snapshots.value.recording.isKnown)
            val iso = CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(6400)))
            assertEquals(CommandStage.Confirmed, unknown.request(iso).stage)
            // Unknown is not idle: the explicit start is sent, and waits for the camera.
            assertEquals(CommandStage.AwaitingObservation, unknown.request(CameraCommandIntent.StartRecording).stage)
            assertEquals(listOf(true), fresh.records)
        }

    @Test
    fun anAcceptedRecordWaitsForTheCameraAndTimesOutWithoutIt() =
        runTest {
            val camera = FakeNikon(movie())
            val seam = NikonOpenCineSession(camera, backgroundScope)
            val start = seam.request(CameraCommandIntent.StartRecording)
            assertEquals(CommandStage.AwaitingObservation, start.stage)
            camera.reportedRecording.value = true
            runCurrent()
            assertEquals(CommandStage.Confirmed, seam.outcome(start.operation)?.stage)
            assertEquals(RecordingState.RECORDING, seam.snapshots.value.recording.value)

            val stop = seam.request(CameraCommandIntent.StopRecording)
            assertEquals(CommandStage.AwaitingObservation, seam.receipt(stop.operation)?.stage, "read without waiting")
            assertNull(seam.receipt(OperationID()))
            advanceTimeBy(6.seconds)
            runCurrent()
            assertEquals(CommandStage.TimedOut, seam.outcome(stop.operation)?.stage)
            assertEquals(RecordingState.RECORDING, seam.snapshots.value.recording.value, "a timeout invents no state")
        }

    @Test
    fun relinkAndCloseStayHonest() =
        runTest {
            val camera = FakeNikon(movie())
            val seam = NikonOpenCineSession(camera, backgroundScope)
            val before = seam.snapshots.value
            camera.state.value = CameraSessionState.Disconnected
            runCurrent()
            camera.state.value = CameraSessionState.Connected(CameraIdentity("ZR", "ZR", "3000123"))
            runCurrent()
            val stale = CameraCommand(CameraCommandIntent.StopRecording, CommandPreconditions(before))
            assertEquals(CommandStage.Rejected(CommandRejection.StaleEpoch), seam.submit(stale).stage)

            val pending = seam.request(CameraCommandIntent.StartRecording)
            seam.close(SessionCloseReason.LINK_LOST)
            assertEquals(CommandStage.OutcomeUnknown, seam.outcome(pending.operation)?.stage)
            assertEquals(ConnectionState.Disconnected(SessionCloseReason.LINK_LOST), seam.snapshots.value.connection)
            val after = seam.request(CameraCommandIntent.StopRecording)
            assertEquals(CommandStage.Rejected(CommandRejection.SessionClosed), after.stage)
            assertNull(seam.outcome(OperationID()))
            assertFailsWith<CameraRecordingException.NotConnected> { seam.setRecording(false) }
        }
}
