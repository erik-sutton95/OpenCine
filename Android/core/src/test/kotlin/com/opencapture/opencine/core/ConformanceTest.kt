package com.opencapture.opencine.core

import com.opencapture.opencine.core.CameraCommandIntent.FocusPoint
import com.opencapture.opencine.core.CameraCommandIntent.Set
import com.opencapture.opencine.core.CameraCommandIntent.StartRecording
import com.opencapture.opencine.core.CameraCommandIntent.StopRecording
import com.opencapture.opencine.core.CommandStage.Accepted
import com.opencapture.opencine.core.CommandStage.Admitted
import com.opencapture.opencine.core.CommandStage.AwaitingObservation
import com.opencapture.opencine.core.CommandStage.Confirmed
import com.opencapture.opencine.core.CommandStage.Created
import com.opencapture.opencine.core.CommandStage.Failed
import com.opencapture.opencine.core.CommandStage.Rejected
import com.opencapture.opencine.core.CommandStage.Sent
import com.opencapture.opencine.core.CommandStage.TimedOut
import com.opencapture.opencine.core.ObservationOrigin.CAMERA_REPORTED
import com.opencapture.opencine.core.SettingKey.APERTURE
import com.opencapture.opencine.core.SettingKey.FRAME_RATE
import com.opencapture.opencine.core.SettingKey.ISO
import com.opencapture.opencine.core.SettingKey.WHITE_BALANCE
import com.opencapture.opencine.core.testing.FakeCameraBehavior.RecordWire
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeIntegration
import com.opencapture.opencine.core.testing.FakePictureSource
import com.opencapture.opencine.core.testing.nikonLike
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlin.test.Ignore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

private fun iso(value: Int) = SettingValue.Iso(ISOValue.Manual(value))
private fun kelvin(value: Int) = SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(value))
private fun fps(rate: Int) = SettingValue.FrameRate(Rational(rate))

/**
 * Plan section 11.2 cross-integration conformance scenarios, numbered as in the plan and named
 * as in the Swift `Conformance` suite. Scenarios that need native code, media analysis or
 * discovery are ignored with the reason.
 */
class ConformanceTest {
    @Test
    fun `01 close is idempotent, stops nothing and leaves other sessions alone`() = forEachFixture { fixture ->
        val a = reportedCamera(fixture)
        val b = reportedCamera(fixture)
        a.submit(StartRecording)
        a.advance(10.seconds)
        assertEquals(RecordingState.RECORDING, a.current.recording.value)
        val wireBeforeClose = a.wire
        val seen = mutableListOf<CameraSnapshot>()
        val collector = launch(start = CoroutineStart.UNDISPATCHED) { a.snapshots.collect { seen += it } }

        a.close(SessionCloseReason.REQUESTED)
        a.closeNow(SessionCloseReason.REQUESTED)
        yield()
        collector.cancelAndJoin()

        val final = a.snapshots.value
        assertEquals(ConnectionState.Disconnected(SessionCloseReason.REQUESTED), final.connection)
        assertEquals(final, seen.last())
        assertEquals(wireBeforeClose, a.wire)
        assertEquals(true, a.device.recording)
        assertEquals(Rejected(CommandRejection.SessionClosed), a.submit(StartRecording).stage)
        // The final snapshot stays final: later camera reports and time publish nothing.
        a.cameraReportsStatus()
        a.advance(10.seconds)
        assertEquals(final, a.snapshots.value)

        assertEquals(ConnectionState.Ready, b.current.connection)
        val change = assertNotNull(someChange(b.current))
        val receipt = b.submit(Set(change))
        b.advance(10.seconds)
        assertEquals(Confirmed, b.outcome(receipt.operation)?.stage)
    }

    @Test
    fun `02 a late callback from attempt A cannot update attempt B`() = forEachFixture { fixture ->
        val camera = reportedCamera(fixture)
        val attemptA = camera.loseLink()
        val attemptB = camera.beginAttempt()
        camera.completeAttempt(attemptA)
        assertEquals(ConnectionState.Recovering(attemptB), camera.current.connection)
        val revision = camera.current.revision
        camera.cameraReportsStatus(from = attemptA)
        assertEquals(revision, camera.current.revision)

        camera.completeAttempt(attemptB)
        assertEquals(ConnectionState.Ready, camera.current.connection)
        assertEquals(ControlEpoch(2), camera.current.epoch)
    }

    @Test
    fun `03 unknown recording, power, storage, timecode and audio levels remain unknown`() = forEachFixture { fixture ->
        val camera = fixture.make()
        val fresh = camera.current
        assertEquals(ObservedValue.unknown, fresh.recording)
        assertEquals(PowerStatus.unknown, fresh.power)
        assertEquals(ObservedValue.unknown, fresh.storage)
        assertEquals(ObservedValue.unknown, fresh.timecode)
        assertEquals(ObservedValue.unknown, fresh.audioLevels)
        assertEquals(SupportStatus.UNKNOWN, fresh.capabilities.timecode)
        assertEquals(SupportStatus.UNKNOWN, fresh.capabilities.audioLevels)
        assertEquals(ObservedValue.unknown, fresh.mode)
        assertTrue(fresh.settings.isEmpty())
        assertTrue(SettingKey.entries.all { fresh.capabilities.support(it) == SupportStatus.UNKNOWN })
        assertEquals(Rejected(CommandRejection.SupportUnknown), camera.submit(StartRecording).stage)

        camera.cameraReportsStatus()
        val reported = camera.current
        val device = camera.device
        assertEquals(ObservedValue.unknown, reported.power.charging)
        assertEquals(ObservedValue.unknown, reported.power.externalPower)
        assertEquals(device.batteryPercent != null, reported.power.battery.isKnown)
        assertEquals(device.freeBytes != null, reported.storage.isKnown)
        assertEquals(CAMERA_REPORTED, reported.recording.origin)
        // An observation is reported only where it is supported; a derived time says so.
        val capabilities = reported.capabilities
        assertTrue(capabilities.timecode != SupportStatus.UNKNOWN && capabilities.audioLevels != SupportStatus.UNKNOWN)
        assertEquals(capabilities.timecode == SupportStatus.SUPPORTED && device.timecodeReading != null, reported.timecodeReading.isKnown)
        assertEquals(capabilities.audioLevels == SupportStatus.SUPPORTED && device.audioLevels != null, reported.audioLevels.isKnown)
        assertTrue(!reported.timecodeReading.isKnown || reported.timecode.origin in setOf(CAMERA_REPORTED, ObservationOrigin.CLOCK_DERIVED))
        assertTrue(!reported.audioLevels.isKnown || reported.audioLevels.origin == CAMERA_REPORTED)
    }

    @Test
    fun `04 values and domains follow the reported mode`() = scenario {
        val camera = reportedCamera(Fixture.DJI_LIKE)
        val video = camera.current
        assertEquals(CaptureMode.Role.VIDEO, video.mode.value?.role)
        assertEquals(true, video.capabilities[FRAME_RATE]?.accepts(fps(24)))

        camera.cameraSwitchesMode(0x02)
        val slow = camera.current
        assertTrue(slow.capabilities.revision > video.capabilities.revision)
        assertEquals(false, slow.capabilities[FRAME_RATE]?.accepts(fps(24)))
        assertEquals(fps(120), slow.value(FRAME_RATE).value)
        assertEquals(Rejected(CommandRejection.OutOfDomain), camera.submit(Set(fps(24))).stage)

        camera.cameraSwitchesMode(0x05)
        val photo = camera.current
        assertEquals(CaptureMode.Role.PHOTO, photo.mode.value?.role)
        assertEquals(SupportStatus.UNSUPPORTED, photo.capabilities.support(FRAME_RATE))
        assertEquals(ObservedValue.unknown, photo.value(FRAME_RATE))
        assertEquals(
            Rejected(CommandRejection.Unavailable(UnavailableReason.Mode)),
            camera.submit(StartRecording).stage,
        )

        camera.cameraSwitchesMode(0x7F)
        val unmapped = camera.current
        assertEquals(CaptureMode.Role.OTHER, unmapped.mode.value?.role)
        assertEquals(SupportStatus.UNKNOWN, unmapped.capabilities.support(ISO))
        assertEquals(Rejected(CommandRejection.SupportUnknown), camera.submit(Set(iso(800))).stage)
        assertTrue(camera.wire.isEmpty())
    }

    @Test
    fun `05 a read-only setting never becomes writable because a view asked`() = scenario {
        val camera = reportedCamera(Fixture.LUNA_LIKE)
        val capabilities = camera.current.capabilities
        assertEquals(SettingAccess.READ_ONLY, capabilities[APERTURE]?.access)
        assertEquals(SettingValue.Aperture(2.0), camera.current.value(APERTURE).value)
        assertEquals(Rejected(CommandRejection.ReadOnly), camera.submit(Set(SettingValue.Aperture(2.0))).stage)
        assertEquals(capabilities, camera.current.capabilities)
        assertTrue(camera.wire.isEmpty())
        assertFalse(MonitorLayoutCapabilities(capabilities).iris)
    }

    @Test
    fun `06 accepted stays pending until readback`() = forEachFixture { fixture ->
        val camera = reportedCamera(fixture)
        val before = camera.current
        val change = assertNotNull(someChange(before))
        val receipt = camera.submit(Set(change))
        assertEquals(AwaitingObservation, receipt.stage)
        assertEquals(before.value(change.key), camera.current.value(change.key))

        camera.advance(camera.behavior.reportDelay - 1.milliseconds)
        assertEquals(AwaitingObservation, camera.stages(receipt.operation).last())

        camera.advance(10.seconds)
        assertEquals(Confirmed, camera.outcome(receipt.operation)?.stage)
        assertEquals(
            listOf(Created, Admitted, Sent, Accepted, AwaitingObservation, Confirmed),
            camera.stages(receipt.operation),
        )
        val observed = camera.current.value(change.key)
        assertEquals(change, observed.value)
        assertEquals(CAMERA_REPORTED, observed.origin)
    }

    @Test
    fun `06 rejection and timeout stay distinguishable`() = forEachFixture { fixture ->
        val camera = reportedCamera(fixture)
        val before = camera.current
        val change = assertNotNull(someChange(before))

        camera.refuseNextCommand()
        assertEquals(Rejected(CommandRejection.CameraRefused), camera.submit(Set(change)).stage)

        camera.silenceReports(true)
        val silent = camera.submit(Set(change))
        camera.advance(30.seconds)
        assertEquals(TimedOut, camera.outcome(silent.operation)?.stage)
        assertEquals(before.value(change.key), camera.current.value(change.key))

        // The camera did act. Its next report shows it; the timed-out receipt stays timed out.
        camera.silenceReports(false)
        camera.cameraReportsStatus()
        assertEquals(change, camera.current.value(change.key).value)
        assertEquals(TimedOut, camera.outcome(silent.operation)?.stage)
    }

    @Test
    fun `06 multi-second settle, and accepted without a stored change`() = scenario {
        val camera = reportedCamera(Fixture.LUNA_LIKE)
        val settled = camera.submit(Set(kelvin(5600)))
        camera.advance(2.seconds)
        assertEquals(AwaitingObservation, camera.stages(settled.operation).last())
        camera.advance(1.seconds)
        assertEquals(Confirmed, camera.outcome(settled.operation)?.stage)

        camera.dropNextWrite()
        val dropped = camera.submit(Set(kelvin(3200)))
        assertEquals(AwaitingObservation, dropped.stage)
        camera.advance(3.seconds)
        assertEquals(Failed(CommandFailure.NOT_APPLIED), camera.outcome(dropped.operation)?.stage)
        assertEquals(kelvin(5600), camera.current.value(WHITE_BALANCE).value)
    }

    @Test
    fun `06 a newer write to the same setting supersedes an unfinished one`() = forEachFixture { fixture ->
        val camera = reportedCamera(fixture)
        val before = camera.current
        val first = assertNotNull(someChange(before))
        val second = assertNotNull(
            before.capabilities[first.key]?.domain?.choices?.firstOrNull {
                it != first && it != before.value(first.key).value
            },
        )
        val older = camera.submit(Set(first))
        val newer = camera.submit(Set(second))
        assertEquals(AwaitingObservation, older.stage)
        assertEquals(Failed(CommandFailure.SUPERSEDED), camera.receipt(older.operation)?.stage)

        camera.advance(10.seconds)
        assertEquals(Failed(CommandFailure.SUPERSEDED), camera.outcome(older.operation)?.stage)
        assertEquals(Confirmed, camera.outcome(newer.operation)?.stage)
        assertEquals(second, camera.current.value(first.key).value)
    }

    @Test
    fun `06 a deadline bounds the wait without inventing state`() = scenario {
        val camera = reportedCamera(Fixture.DJI_LIKE)
        val command = camera.command(Set(iso(1600)), deadline = MonotonicInstant.ZERO + 100.milliseconds)
        camera.submit(command)
        camera.advance(1.seconds)
        assertEquals(TimedOut, camera.outcome(command.operation)?.stage)
        assertEquals(iso(1600), camera.current.value(ISO).value)
        val late = CameraCommand(command.intent, command.preconditions)
        assertEquals(Rejected(CommandRejection.DeadlinePassed), camera.submit(late).stage)
    }

    @Test
    fun `07 a capability change retires stale editor commands`() = forEachFixture { fixture ->
        val camera = reportedCamera(fixture)
        val change = assertNotNull(someChange(camera.current))
        val queued = camera.command(Set(change))
        val original = camera.device.rawMode
        camera.cameraSwitchesMode(0x7F)
        camera.cameraSwitchesMode(original)

        assertEquals(Rejected(CommandRejection.StaleCapabilities), camera.submit(queued).stage)
        assertTrue(camera.wire.isEmpty())
        assertEquals(AwaitingObservation, camera.submit(Set(change)).stage)
    }

    @Test
    fun `08 commands cannot reach another camera, a replacement link or a replaced lease`() = forEachFixture { fixture ->
        val a = reportedCamera(fixture)
        val b = reportedCamera(fixture)
        val change = assertNotNull(someChange(a.current))
        val forA = a.command(Set(change))
        assertEquals(Rejected(CommandRejection.WrongSession), b.submit(forA).stage)

        val attempt = a.loseLink()
        fun retry() = CameraCommand(Set(change), forA.preconditions)
        assertEquals(Rejected(CommandRejection.NotConnected), a.submit(retry()).stage)
        a.completeAttempt(attempt)
        assertEquals(Rejected(CommandRejection.StaleEpoch), a.submit(retry()).stage)

        a.setAuthority(ControlAuthority.Lease(ControlLease()))
        val leased = a.command(Set(change))
        a.setAuthority(ControlAuthority.Lease(ControlLease()))
        assertEquals(Rejected(CommandRejection.NoAuthority), a.submit(leased).stage)
        assertTrue(a.wire.isEmpty())
        assertTrue(b.wire.isEmpty())
    }

    @Test
    fun `09 a picture failure does not fabricate a stopped recording`() = forEachFixture { fixture ->
        val camera = reportedCamera(fixture)
        val picture = FakePictureSource("Live view").apply { start() }
        val entry = MonitorEntryDescriptor(
            name = "A", picture = picture.descriptor, cameraSession = camera.id,
            telemetry = TelemetrySource.CAMERA_SESSION, controlAuthority = ControlAuthority.Owner,
        )
        camera.submit(StartRecording)
        camera.advance(10.seconds)
        assertEquals(RecordingState.RECORDING, camera.current.recording.value)

        picture.fail()
        assertEquals(PictureHealth.FAILED, picture.health)
        assertEquals(RecordingState.RECORDING, camera.current.recording.value)
        assertNull(entry.validationError())

        // A lost control link keeps the last report and its age, not idle.
        camera.loseLink()
        camera.advance(30.seconds)
        val recording = camera.current.recording
        assertEquals(RecordingState.RECORDING, recording.value)
        assertEquals(Freshness.STALE, recording.freshness(camera.now, 5.seconds))
    }

    @Test
    fun `10 camera commands work while another picture source is displayed`() = scenario {
        val camera = FakeCameraSession.nikonLike()
        camera.cameraReportsStatus()
        val liveView = FakePictureSource("Camera").apply { start() }
        var entry = MonitorEntryDescriptor(
            name = "Z", picture = liveView.descriptor, cameraSession = camera.id,
            telemetry = TelemetrySource.CAMERA_SESSION, controlAuthority = ControlAuthority.Owner,
        )
        val before = camera.current

        val hdmi = FakePictureSource("HDMI").apply { start() }
        entry = entry.copy(picture = hdmi.descriptor)
        assertNull(entry.validationError())
        assertEquals(camera.id, entry.cameraSession)
        val after = camera.current
        assertEquals(before.session, after.session)
        assertEquals(before.epoch, after.epoch)

        val isoReceipt = camera.submit(Set(iso(1600)))
        camera.advance(1.seconds)
        assertEquals(Confirmed, camera.outcome(isoReceipt.operation)?.stage)

        // Recording needs the camera's own live view, said with a typed reason.
        assertEquals(
            Rejected(CommandRejection.Unavailable(UnavailableReason.NotReady)),
            camera.submit(StartRecording).stage,
        )
        camera.setLiveViewReady(true)
        val start = camera.submit(StartRecording)
        camera.advance(1.seconds)
        assertEquals(Confirmed, camera.outcome(start.operation)?.stage)
        assertEquals("record-start", camera.wire.last())

        // Acknowledgement-only control: accepted is finished, never "confirmed".
        val focus = camera.submit(FocusPoint(0.5, 0.5))
        assertEquals(Accepted, focus.stage)
        assertTrue(focus.isFinished)
        assertEquals(Rejected(CommandRejection.OutOfDomain), camera.submit(FocusPoint(1.5, 0.5)).stage)
    }

    @Ignore // N/A for CORE-01: no native or JNI code exists here; STATE-01 and CORE-02.
    @Test
    fun `11 session owners receive only their own native events`() = Unit

    @Ignore // N/A for CORE-01: analysis and calibration state belong to MEDIA-01/STATE-01.
    @Test
    fun `12 profile, false-color and EV calibration configurations are isolated`() = Unit

    @Test
    fun `13 lease expiry blocks commands but keeps picture-only access`() = forEachFixture { fixture ->
        val camera = reportedCamera(fixture)
        val lease = ControlLease(expiresAt = camera.now + 10.seconds)
        camera.setAuthority(ControlAuthority.Lease(lease))
        val relay = FakePictureSource("Relay").apply { start() }
        val entry = MonitorEntryDescriptor(
            name = "Relay", picture = relay.descriptor, cameraSession = camera.id,
            telemetry = TelemetrySource.RELAY, controlAuthority = ControlAuthority.Lease(lease),
        )
        assertNull(entry.validationError())

        val change = assertNotNull(someChange(camera.current))
        assertEquals(AwaitingObservation, camera.submit(Set(change)).stage)
        camera.advance(11.seconds)
        assertEquals(Rejected(CommandRejection.AuthorityExpired), camera.submit(Set(change)).stage)

        val viewer = entry.copy(controlAuthority = ControlAuthority.ReadOnly)
        assertNull(viewer.validationError())
        assertEquals(relay.descriptor, viewer.picture)
        assertEquals(PictureHealth.LIVE, relay.health)
    }

    @Test
    fun `14 start and stop retries follow idempotency, never a blind toggle`() = forEachFixture { fixture ->
        val camera = reportedCamera(fixture)
        val start = camera.command(StartRecording)
        camera.submit(start)
        camera.submit(start)
        camera.advance(10.seconds)
        assertEquals(Confirmed, camera.outcome(start.operation)?.stage)
        assertEquals(1, camera.wire.size)

        assertEquals(Confirmed, camera.submit(StartRecording).stage)
        assertEquals(1, camera.wire.size)
        assertEquals(true, camera.device.recording)

        val stop = camera.submit(StopRecording)
        camera.advance(10.seconds)
        assertEquals(Confirmed, camera.outcome(stop.operation)?.stage)
        assertEquals(RecordingState.IDLE, camera.current.recording.value)
        assertEquals(2, camera.wire.size)
    }

    @Test
    fun `14 unknown recording state blocks only toggle wires`() = forEachFixture { fixture ->
        val template = fixture.make()
        val camera = FakeCameraSession(template.behavior, template.device.copy(recording = null))
        camera.cameraReportsStatus()
        camera.setLiveViewReady(true)
        assertEquals(ObservedValue.unknown, camera.current.recording)

        val receipt = camera.submit(StartRecording)
        when (camera.behavior.recordWire) {
            RecordWire.TOGGLE -> {
                assertEquals(Rejected(CommandRejection.RecordingStateUnknown), receipt.stage)
                assertTrue(camera.wire.isEmpty())
            }
            RecordWire.EXPLICIT -> {
                camera.advance(10.seconds)
                assertEquals(Confirmed, camera.outcome(receipt.operation)?.stage)
                assertEquals(listOf("record-start"), camera.wire)
            }
        }
    }

    /** Against the scripted integration; each integration runs it with its own fake transports. */
    @Test
    fun `15 discovery follows passive and active policy`() = scenario {
        val both = FakeIntegration(endpoints = listOf("10.0.0.2", "10.0.0.3"))
        both.discover(DiscoveryMode.PASSIVE).first()
        assertTrue(both.dials.isNotEmpty())
        assertTrue(both.dials.all { it.purpose == FakeIntegration.DialPurpose.PRESENCE })

        both.discover(DiscoveryMode.ACTIVE).first()
        assertEquals(
            listOf("10.0.0.2", "10.0.0.3"),
            both.dials.filter { it.purpose == FakeIntegration.DialPurpose.CAMERA_CONTROL }.map { it.endpoint },
        )
        assertEquals(listOf(DiscoveryMode.PASSIVE, DiscoveryMode.ACTIVE), both.discoveries)

        // An integration that only listens never runs an active discovery.
        val listening = FakeIntegration(discoveryModes = setOf(DiscoveryMode.PASSIVE), endpoints = listOf("10.0.0.2"))
        assertTrue(listening.discover(DiscoveryMode.ACTIVE).toList().isEmpty())
        assertTrue(listening.dials.isEmpty())
    }
}
