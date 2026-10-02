package com.opencapture.opencine.core

import com.opencapture.opencine.core.CameraCommandIntent.Set
import com.opencapture.opencine.core.CameraCommandIntent.StartRecording
import com.opencapture.opencine.core.CommandStage.Confirmed
import com.opencapture.opencine.core.CommandStage.OutcomeUnknown
import com.opencapture.opencine.core.MonotonicInstant.Companion.ZERO
import com.opencapture.opencine.core.ObservationOrigin.CAMERA_REPORTED
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeEntries
import com.opencapture.opencine.core.testing.FakePictureSource
import com.opencapture.opencine.core.testing.nikonLike
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

private fun iso(value: Int) = SettingValue.Iso(ISOValue.Manual(value))
private fun kelvin(value: Int) = SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(value))

/** Swift suite `Values`. */
class ValuesTest {
    @Test
    fun unknownTelemetryIsNeverCoerced() {
        assertNull(ObservedValue.unknown.value)
        assertNotEquals<ObservedValue<Boolean>>(ObservedValue.unknown, ObservedValue(false, CAMERA_REPORTED, ZERO))
        assertNotEquals<ObservedValue<Double>>(ObservedValue.unknown, ObservedValue(0.0, CAMERA_REPORTED, ZERO))
        assertNotEquals<ObservedValue<String>>(ObservedValue.unknown, ObservedValue("", CAMERA_REPORTED, ZERO))
        assertEquals(Freshness.UNKNOWN, ObservedValue.unknown.freshness(ZERO, 1.seconds))

        val snapshot = CameraSnapshot(CameraSessionID())
        assertNull(snapshot.recording.value)
        assertEquals(PowerStatus.unknown, snapshot.power)
        assertNull(snapshot.storage.value)
        assertNull(snapshot.timecode.value)
        assertNull(snapshot.audioLevels.value)
        assertEquals(SupportStatus.UNKNOWN, snapshot.capabilities.timecode)
        assertEquals(SupportStatus.UNKNOWN, snapshot.capabilities.audioLevels)
    }

    @Test
    fun freshnessIsComputedFromAge() {
        val battery = ObservedValue(0.5, CAMERA_REPORTED, ZERO)
        assertEquals(Freshness.FRESH, battery.freshness(ZERO + 1.seconds, 2.seconds))
        assertEquals(Freshness.STALE, battery.freshness(ZERO + 3.seconds, 2.seconds))
        val undated = ObservedValue(0.5, ObservationOrigin.IMAGE_ESTIMATED, null)
        assertEquals(Freshness.UNKNOWN, undated.freshness(ZERO, 2.seconds))
    }

    /** MULTI-03 F1: one process reference, and the same one raw `System.nanoTime()` stamps use. */
    @Test
    fun nowIsOneMonotonicReference() {
        val first = MonotonicInstant.now()
        val raw = System.nanoTime()
        val second = MonotonicInstant.now()
        assertTrue(first <= second && second - first < 1.seconds)
        assertTrue(first.sinceReference.inWholeNanoseconds <= raw && raw <= second.sinceReference.inWholeNanoseconds)
    }

    @Test
    fun rationalsAreNormalized() {
        assertEquals(Rational(1, 50), Rational(2, 100))
        assertEquals(Rational(-1, 3), Rational(1, -3))
        assertEquals(Rational(0), Rational(0, 7))
        assertEquals(1001, Rational(24000, 1001).denominator)
        assertEquals(Rational(1, 50).hashCode(), Rational(2, 100).hashCode())
        assertFailsWith<IllegalArgumentException> { Rational(1, 0) }
    }

    @Test
    fun domainsValidateChoicesRangesAndKeys() {
        val isoDescriptor = SettingDescriptor(
            SettingKey.ISO,
            domain = SettingDomain(listOf(SettingValue.Iso(ISOValue.Auto), iso(400), iso(800))),
        )
        assertTrue(isoDescriptor.accepts(iso(800)))
        assertTrue(isoDescriptor.accepts(SettingValue.Iso(ISOValue.Auto)))
        assertFalse(isoDescriptor.accepts(iso(500)))

        val wb = SettingDescriptor(
            SettingKey.WHITE_BALANCE,
            domain = SettingDomain(listOf(SettingValue.WhiteBalance(WhiteBalanceValue.Auto)), 2000.0..10000.0, 100.0),
        )
        assertTrue(wb.accepts(SettingValue.WhiteBalance(WhiteBalanceValue.Auto)))
        assertTrue(wb.accepts(kelvin(5600)))
        assertFalse(wb.accepts(kelvin(5650)))
        assertFalse(wb.accepts(kelvin(12000)))
        assertFalse(wb.accepts(SettingValue.WhiteBalance(WhiteBalanceValue.Preset("daylight"))))

        // Tint is its own setting: a separate key, range and step; unknown until reported.
        val tint = SettingDescriptor(SettingKey.WHITE_BALANCE_TINT, domain = SettingDomain(range = -100.0..100.0, step = 1.0))
        assertTrue(tint.accepts(SettingValue.WhiteBalanceTint(-12.0)))
        assertFalse(tint.accepts(SettingValue.WhiteBalanceTint(0.5)))
        assertFalse(tint.accepts(SettingValue.WhiteBalanceTint(150.0)))
        assertFalse(wb.accepts(SettingValue.WhiteBalanceTint(0.0)))
        assertEquals(ObservedValue.unknown, CameraSnapshot(CameraSessionID()).value(SettingKey.WHITE_BALANCE_TINT))

        val zoom = SettingDescriptor(SettingKey.ZOOM, domain = SettingDomain(range = 1.0..4.0, step = 0.1))
        assertTrue(zoom.accepts(SettingValue.Zoom(1.5)))
        assertFalse(zoom.accepts(SettingValue.Aperture(1.5)))

        // Duration and angle never stand in for each other.
        val angle = SettingDescriptor(
            SettingKey.SHUTTER,
            domain = SettingDomain(listOf(SettingValue.Shutter(ShutterValue.Angle(180.0)))),
        )
        assertFalse(angle.accepts(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 48)))))
        // Command-only controls have no value domain.
        assertFalse(SettingDescriptor(SettingKey.RECORDING).accepts(SettingValue.Iso(ISOValue.Auto)))
    }

    @Test
    fun provisionalDevicesNeverMerge() {
        val integration = IntegrationID("test.cameras")
        val first = CameraDeviceID.provisional(integration)
        val second = CameraDeviceID.provisional(integration)
        assertNotEquals(first, second)
        assertTrue(first.isProvisional)
        assertNotEquals(CameraDeviceID.durable(first.value, integration), first)
    }

    @Test
    fun receiptsFinishAtTheRightStage() {
        val session = CameraSessionID()
        val readback = CommandReceipt(OperationID(), session, StartRecording, CommandStage.Accepted)
        assertFalse(readback.isFinished)
        assertTrue(readback.copy(stage = OutcomeUnknown).isFinished)
        assertTrue(readback.copy(stage = CommandStage.Failed(CommandFailure.SUPERSEDED)).isFinished)
        val acknowledged = CommandReceipt(
            OperationID(), session, CameraCommandIntent.FocusPoint(0.0, 0.0), CommandStage.Accepted,
            SettingSemantics.Confirmation.ACKNOWLEDGEMENT_ONLY,
        )
        assertTrue(acknowledged.isFinished)
    }
}

/** Swift suite `Entries`. */
class EntriesTest {
    @Test
    fun everyEntryNeedsARole() {
        val session = CameraSessionID()
        val hdmi = FakePictureSource("HDMI").descriptor
        assertNull(FakeEntries.captureOnly(hdmi).validationError())
        assertNull(FakeEntries.controlOnly(session, "Wi-Fi").validationError())
        assertNull(
            MonitorEntryDescriptor(
                name = "Viewer", telemetry = TelemetrySource.RELAY, controlAuthority = ControlAuthority.ReadOnly,
            ).validationError(),
        )

        assertEquals(
            MonitorEntryError.NO_ROLE,
            MonitorEntryDescriptor(name = "Empty", controlAuthority = ControlAuthority.ReadOnly).validationError(),
        )
        assertEquals(
            MonitorEntryError.COMMAND_AUTHORITY_WITHOUT_SESSION,
            MonitorEntryDescriptor(name = "HDMI", picture = hdmi, controlAuthority = ControlAuthority.Owner)
                .validationError(),
        )
        assertEquals(
            MonitorEntryError.SESSION_TELEMETRY_WITHOUT_SESSION,
            MonitorEntryDescriptor(
                name = "HDMI", picture = hdmi, telemetry = TelemetrySource.CAMERA_SESSION,
                controlAuthority = ControlAuthority.ReadOnly,
            ).validationError(),
        )
    }
}

/** Swift suite `LayoutProjection`. */
class LayoutProjectionTest {
    @Test
    fun projectsWritableSectionsAndCarriesTheRest() {
        val base = MonitorLayoutCapabilities(gimbal = true, timecode = true)
        assertEquals(base, MonitorLayoutCapabilities(CapabilitySnapshot(), base))

        val a = MonitorLayoutCapabilities(reportedCamera(Fixture.DJI_LIKE).current.capabilities, base)
        assertTrue(a.zoom && !a.iris && !a.focus && a.gimbal && a.timecode)
        val b = MonitorLayoutCapabilities(reportedCamera(Fixture.NIKON_LIKE).current.capabilities)
        assertTrue(!b.zoom && b.iris && b.focus && !b.gimbal)
        val c = MonitorLayoutCapabilities(reportedCamera(Fixture.LUNA_LIKE).current.capabilities)
        assertTrue(c.zoom && !c.iris && c.focus)
    }

    /** Supported observations show, unsupported ones hide, and unknown support keeps the base. */
    @Test
    fun projectsObservationSupportAndKeepsTheBaseWhileUnknown() {
        val base = MonitorLayoutCapabilities(audio = true, timecode = true)
        assertEquals(base, MonitorLayoutCapabilities(CapabilitySnapshot(), base))
        assertFalse(MonitorLayoutCapabilities(CapabilitySnapshot()).audio)

        val dji = reportedCamera(Fixture.DJI_LIKE)
        val video = MonitorLayoutCapabilities(dji.current.capabilities)
        assertTrue(video.timecode && video.audio)
        dji.cameraSwitchesMode(0x05)
        dji.cameraReportsStatus()
        val photo = MonitorLayoutCapabilities(dji.current.capabilities, base)
        assertTrue(!photo.timecode && !photo.audio)

        val luna = MonitorLayoutCapabilities(reportedCamera(Fixture.LUNA_LIKE).current.capabilities, base)
        assertTrue(luna.timecode && !luna.audio)
    }
}

/** Swift suite `Feeds`. */
class FeedsTest {
    @Test
    fun snapshotFeedKeepsOnlyTheLatestAndOutcomesStayReliable() = scenario {
        val camera = reportedCamera(Fixture.DJI_LIKE)
        val seen = mutableListOf<CameraSnapshot>()
        val collector = launch(start = CoroutineStart.UNDISPATCHED) { camera.snapshots.collect { seen += it } }
        val operations = (0 until 50).map { step ->
            camera.submit(Set(kelvin(2000 + 100 * step))).operation.also { camera.advance(1.seconds) }
        }
        yield()
        collector.cancelAndJoin()
        // The collector was busy for 50 publishes; it then sees only the latest.
        assertEquals(2, seen.size)
        assertEquals(camera.current, seen.last())
        for (operation in operations) assertEquals(Confirmed, camera.outcome(operation)?.stage)
    }

    @Test
    fun droppedFeedsAreReleased() = scenario {
        val camera = reportedCamera(Fixture.DJI_LIKE)
        val consumer = launch(start = CoroutineStart.UNDISPATCHED) { camera.snapshots.collect {} }
        assertEquals(1, camera.subscriberCount)
        consumer.cancelAndJoin()
        camera.setAuthority(ControlAuthority.Owner)
        assertEquals(0, camera.subscriberCount)
        assertEquals(camera.current, camera.snapshots.value)
    }

    @Test
    fun outcomeWaitsResumeAndCancellationNeverAltersTheOperation() = scenario {
        val camera = reportedCamera(Fixture.LUNA_LIKE)
        assertNull(camera.outcome(OperationID()))

        val cancelled = camera.submit(Set(iso(800)))
        val waiter = async(start = CoroutineStart.UNDISPATCHED) { camera.outcome(cancelled.operation) }
        waiter.cancelAndJoin()
        assertTrue(waiter.isCancelled)
        assertEquals(CommandStage.AwaitingObservation, camera.stages(cancelled.operation).last())
        camera.advance(3.seconds)
        assertEquals(Confirmed, camera.outcome(cancelled.operation)?.stage)

        val waited = camera.submit(Set(iso(1600)))
        val patient = async(start = CoroutineStart.UNDISPATCHED) { camera.outcome(waited.operation) }
        camera.advance(3.seconds)
        assertEquals(Confirmed, patient.await()?.stage)

        val pending = camera.submit(Set(iso(3200)))
        assertEquals(CommandStage.AwaitingObservation, camera.receipt(pending.operation)?.stage)
        assertNull(camera.receipt(OperationID()))
        camera.advance(3.seconds)
        assertEquals(Confirmed, camera.receipt(pending.operation)?.stage)

        val interrupted = camera.submit(Set(iso(400)))
        val closing = async(start = CoroutineStart.UNDISPATCHED) { camera.outcome(interrupted.operation) }
        camera.closeNow(SessionCloseReason.REQUESTED)
        assertEquals(OutcomeUnknown, closing.await()?.stage)
    }
}

/** Swift suite `Portability`. */
class PortabilityTest {
    @Test
    fun coreImportsOnlyStdlibAndCoroutinesAndNamesNoManufacturer() {
        val files = File("src/main/kotlin").walk().filter { it.extension == "kt" }.toList()
        assertTrue(files.isNotEmpty())
        val brands = Regex(
            """\b(dji|osmo|nikon|zcine|insta360|insta|luna|pocket|sony|canon|blackmagic|gopro)\b""",
            RegexOption.IGNORE_CASE,
        )
        assertNotNull(brands.find("A Nikon body"))
        assertNull(brands.find("one instance"))
        // No android.*, java.nio buffers or platform media types in portable state. Motion is
        // optional, as in Swift: the core package never imports it.
        val allowed = listOf(
            "import kotlin.", "import kotlinx.coroutines.flow.", "import java.util.UUID", "import com.opencapture.opencine.",
        )
        for (file in files) {
            val text = file.readText()
            for (line in text.lines().filter { it.startsWith("import ") }) {
                assertTrue(allowed.any { line.startsWith(it) }, "${file.name}: $line")
                assertTrue("/motion/" in file.path || ".motion." !in line, "${file.name}: $line")
            }
            assertNull(brands.find(text), "${file.name} names a brand")
        }
    }
}

/**
 * Swift suite `GroupTargets`. Group start/stop planning is MULTI-01's. This shows Core already
 * carries its inputs: one admission rule for eligibility, session identity for deduplication and
 * per-target receipts, for both the strict and the eligible-subset policy.
 */
class GroupTargetsTest {
    private sealed interface Exclusion {
        data object NoControl : Exclusion
        data class Refused(val rejection: CommandRejection) : Exclusion
    }

    @Test
    fun strictAndEligibleSubsetFromAdmission() = scenario {
        val first = reportedCamera(Fixture.DJI_LIKE)
        val second = FakeCameraSession.nikonLike().apply { cameraReportsStatus() }
        val sessions = mapOf(first.id to first, second.id to second)
        val entries = listOf(
            MonitorEntryDescriptor(
                name = "A", picture = FakePictureSource("A").descriptor, cameraSession = first.id,
                telemetry = TelemetrySource.CAMERA_SESSION, controlAuthority = ControlAuthority.Owner,
            ),
            FakeEntries.controlOnly(first.id, "A controls"),
            FakeEntries.controlOnly(second.id, "B"),
            FakeEntries.captureOnly(FakePictureSource("HDMI").descriptor),
        )

        val targets = mutableMapOf<CameraSessionID, CameraCommand>()
        val excluded = mutableMapOf<String, Exclusion>()
        for (entry in entries) {
            val session = entry.cameraSession?.let { sessions[it] }
            if (session == null) {
                excluded[entry.name] = Exclusion.NoControl
                continue
            }
            if (session.id in targets) continue
            val snapshot = session.current
            val command = CameraCommand(StartRecording, CommandPreconditions(snapshot))
            val rejection = snapshot.rejection(command, session.now)
            if (rejection != null) excluded[entry.name] = Exclusion.Refused(rejection) else targets[session.id] = command
        }
        assertEquals(setOf(first.id), targets.keys)
        assertEquals(
            mapOf(
                "B" to Exclusion.Refused(CommandRejection.Unavailable(UnavailableReason.NotReady)),
                "HDMI" to Exclusion.NoControl,
            ),
            excluded,
        )

        val strict = if (excluded.isEmpty()) targets else emptyMap()
        assertTrue(strict.isEmpty())

        for ((id, command) in targets) sessions.getValue(id).submit(command)
        first.advance(5.seconds)
        val command = assertNotNull(targets[first.id])
        assertEquals(Confirmed, first.outcome(command.operation)?.stage)
        assertEquals(listOf("record-toggle"), first.wire)
        assertTrue(second.wire.isEmpty())
    }
}
