package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.CameraCapability

import com.opencapture.opencine.core.CameraCommand
import kotlin.test.assertNotNull
import com.opencapture.opencine.media.storageReadout
import com.opencapture.opencine.media.recordingTimeLabel
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CameraTimecodeReading
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.insta360.shell.ConnectionPhase as LinkPhase
import com.opencapture.opencine.motion.MotionAxis
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.nanoseconds
import kotlin.time.Duration.Companion.seconds

/**
 * A Luna camera behind the session's link: it applies the real SET bodies the session builds and
 * answers readbacks in the real reply encodings. Port of the iOS `LunaCameraSessionTests`.
 */
internal class FakeLuna(
    private val scope: CoroutineScope,
    private val now: () -> MonotonicInstant = { MonotonicInstant(System.nanoTime().nanoseconds) },
) {
    private val lock = Any()
    var program = 0L
    var iso = 0L
    var shutterSeconds = 0.0
    /** The camera reads its exposure back through single precision, as a real Luna can. */
    var reportsSinglePrecisionShutter = false
    var kelvin = 5600L
    var colorMode: Long? = null
    var zoom = 1.0
    var afMode = 1L
    /** Capture state (cmd 15); null sends no reply at all. */
    var captureState: Long? = 0
    /** The camera acknowledges SETs and record commands but stores nothing. */
    @Volatile var ignoresWrites = false
    /** A stored value changes this long after its SET is acknowledged. */
    @Volatile var applyDelay: Duration = Duration.ZERO
    @Volatile var silent = false
    @Volatile var refuses = false
    val sent = mutableListOf<LunaControl.Request>()
    private var lastApply: Job? = null
    lateinit var session: LunaCameraSession

    fun makeSession(settle: Duration = 5.seconds,
        backendCapabilities: () -> Set<CameraCapability>? = { null }): LunaCameraSession {
        session = LunaCameraSession(
            send = ::receive, functionMode = { LunaControl.FUNCTION_MODE_VIDEO },
            readSettings = { reportSettings() }, readCapture = { reportCapture() }, scope = scope,
            timing = LunaCameraSession.Timing(SettingKey.entries.associateWith { settle }, 40.milliseconds),
            now = now, backendCapabilities = backendCapabilities,
        )
        return session
    }

    /** A live session that has heard every report once. */
    fun connectedSession(settle: Duration = 5.seconds, serial: String = "LUNA-TEST",
        backendCapabilities: () -> Set<CameraCapability>? = { null }): LunaCameraSession {
        makeSession(settle, backendCapabilities)
        session.linkChanged(LinkPhase.LIVE, serial)
        reportDevice(); reportSettings(); reportCapture()
        return session
    }

    suspend fun receive(request: LunaControl.Request): ByteArray {
        synchronized(lock) { sent += request }
        if (refuses) throw LunaRefused(request.code)
        if (ignoresWrites) return ByteArray(0)
        if (applyDelay == Duration.ZERO) {
            apply(request)
        } else {
            // One control socket: the camera applies SETs in the order they arrived.
            val (wait, previous) = synchronized(lock) { applyDelay to lastApply }
            synchronized(lock) { lastApply = scope.launch { previous?.join(); delay(wait); apply(request) } }
        }
        return ByteArray(0)
    }

    private fun apply(request: LunaControl.Request) {
        synchronized(lock) {
            when (request.code) {
                LunaControl.SET_PHOTOGRAPHY_OPTIONS -> {
                    val set = LunaPhotographySettings.parse(request.body)
                    if (21 in set.types) set.videoExposure?.let { program = it.program; iso = it.iso; shutterSeconds = it.shutterSeconds }
                    if (39 in set.types) kelvin = set.whiteBalanceKelvin ?: 0
                    if (53 in set.types) set.zoom?.let { zoom = it }
                    if (93 in set.types) set.afMode?.let { afMode = it }
                }
                4 -> captureState = 1
                5 -> captureState = 0
            }
            Unit
        }
    }

    fun sentCount() = synchronized(lock) { sent.size }
    fun lastSent() = synchronized(lock) { sent.last() }

    private fun double(field: Int, value: Double) =
        LunaWire.varint(((field shl 3) or 1).toLong()) + ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putDouble(value).array()

    fun reportSettings() {
        if (silent) return
        val body = synchronized(lock) {
            val types = mutableListOf(21, 39, 53, 93)
            var exposure = LunaWire.integer(1, program) + LunaWire.integer(2, iso)
            if (shutterSeconds > 0) exposure += double(3,
                if (reportsSinglePrecisionShutter) shutterSeconds.toFloat().toDouble() else shutterSeconds)
            var nested = LunaWire.blob(21, exposure) + LunaWire.integer(39, kelvin)
            nested += double(53, zoom) + LunaWire.integer(93, afMode)
            colorMode?.let { types += 35; nested += LunaWire.integer(35, it) }
            val packed = types.fold(ByteArray(0)) { acc, t -> acc + LunaWire.varint(t.toLong()) }
            LunaWire.blob(1, packed) + LunaWire.blob(2, nested) + LunaWire.integer(3, LunaControl.FUNCTION_MODE_VIDEO.toLong())
        }
        session.ingest(LunaPhotographySettings.parse(body))
    }

    fun reportCapture() {
        if (silent) return
        val state = synchronized(lock) { captureState } ?: return
        session.ingest(LunaCaptureStatus.fromResponse(LunaWire.blob(1, LunaWire.integer(1, state))))
    }

    /** Video mode, no battery or storage fields. */
    fun reportDevice() {
        session.ingest(LunaDeviceStatus.parse(LunaWire.blob(2, LunaWire.integer(40, 100) + LunaWire.integer(41, 0))))
    }
}

class LunaCameraSessionTest {
    private fun reportCadence(raw: Long?, session: LunaCameraSession) {
        session.ingest(LunaPhotographySettings(types = listOf(31),
            functionMode = LunaControl.FUNCTION_MODE_VIDEO, recordResolution = raw))
    }

    /** Owner 2026-10-20, Luna Ultra 8K30, shutter priority, Angle 180: SHUTTER read "0.0108°". */
    @Test fun anInexactReadbackIsTheSpeedAndItsAngle() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        camera.reportsSinglePrecisionShutter = true
        camera.program = 2
        camera.shutterSeconds = 1.0 / 60
        val session = camera.connectedSession()
        reportCadence(24, session) // 4K30
        assertEquals(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 60))), session.snapshots.value.value(SettingKey.SHUTTER).value)
        session.configureShutter(com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
        assertEquals(SettingValue.Shutter(ShutterValue.Angle(180.0)), session.snapshots.value.value(SettingKey.SHUTTER).value)
    }

    /** 180 degrees sends the Luna wheel's nearest 1/N per rate and confirms against an inexact readback. */
    @Test fun angleSendsTheNearestWheelSpeedPerRate() = runTest {
        // Raw format ids: 4K24, 4K25, 4K30, 4K60, 4K120.
        for ((raw, fps, denom) in listOf(Triple(49L, 24.0, 50), Triple(48L, 25.0, 50), Triple(24L, 30.0, 60),
            Triple(23L, 60.0, 125), Triple(214L, 120.0, 250))) {
            val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
            camera.reportsSinglePrecisionShutter = true
            camera.program = 3
            camera.iso = 400
            camera.shutterSeconds = 1.0 / 1000
            val session = camera.connectedSession()
            reportCadence(raw, session)
            session.configureShutter(com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
            val (_, outcome) = session.run(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Angle(180.0))))
            assertEquals(CommandStage.Confirmed, outcome.stage, "$fps fps")
            val exposure = requireNotNull(LunaPhotographySettings.parse(camera.sent.last().body).videoExposure)
            assertEquals(1.0 / denom, exposure.shutterSeconds, 1e-12, "$fps fps")
            val angle = (session.snapshots.value.value(SettingKey.SHUTTER).value as SettingValue.Shutter).value as ShutterValue.Angle
            assertEquals(360 * fps / denom, angle.degrees, 1e-9, "$fps fps")
        }
    }

    @Test fun emulatedAngleConfirmsTheQuantizedNativeReadback() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        camera.program = 3
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        val session = camera.connectedSession()
        reportCadence(48, session)
        session.configureShutter(com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
        assertEquals(com.opencapture.opencine.core.SettingSemantics.Implementation.EMULATED,
            session.snapshots.value.capabilities[SettingKey.SHUTTER]?.semantics?.implementation)
        assertEquals(SettingValue.Shutter(ShutterValue.Angle(180.0)), session.snapshots.value.value(SettingKey.SHUTTER).value)
        val (_, outcome) = session.run(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Angle(144.0))))
        assertEquals(CommandStage.Confirmed, outcome.stage)
        val exposure = requireNotNull(LunaPhotographySettings.parse(camera.sent.last().body).videoExposure)
        assertEquals(1.0 / 60, exposure.shutterSeconds, 1e-9)
        assertEquals(SettingValue.Shutter(ShutterValue.Angle(150.0)), session.snapshots.value.value(SettingKey.SHUTTER).value)
        assertEquals(ObservationOrigin.PROTOCOL_DERIVED, session.snapshots.value.value(SettingKey.SHUTTER).origin)
    }

    @Test fun angleEmulationNeedsReportedCadenceAndPreservesNativeIsoComposition() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        camera.program = 3
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        val session = camera.connectedSession()
        session.configureShutter(com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
        assertNull(session.snapshots.value.value(SettingKey.SHUTTER).value)
        val rejected = session.submit(CameraCommand(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Angle(180.0))),
            CommandPreconditions(session.snapshots.value)))
        assertTrue(rejected.stage is CommandStage.Rejected)
        assertTrue(camera.sent.isEmpty())
        val (_, outcome) = session.run(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(800))))
        assertEquals(CommandStage.Confirmed, outcome.stage)
        val exposure = requireNotNull(LunaPhotographySettings.parse(camera.sent.last().body).videoExposure)
        assertEquals(800L, exposure.iso)
        assertEquals(1.0 / 50, exposure.shutterSeconds, 1e-9)
        session.configureShutter(com.opencapture.opencine.media.HostShutterPresentation.CAMERA_VALUE)
        assertEquals(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 50))), session.snapshots.value.value(SettingKey.SHUTTER).value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, session.snapshots.value.value(SettingKey.SHUTTER).origin)
    }

    @Test fun cadenceChangeRetiresPreparedAngleCommands() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        camera.program = 3
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        val session = camera.connectedSession()
        reportCadence(48, session)
        session.configureShutter(com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
        val command = CameraCommand(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Angle(180.0))),
            CommandPreconditions(session.snapshots.value))
        reportCadence(24, session)
        assertEquals(CommandStage.Rejected(CommandRejection.StaleCapabilities), session.submit(command).stage)
        assertTrue(camera.sent.isEmpty())
        reportCadence(null, session)
        assertNull(session.snapshots.value.value(SettingKey.SHUTTER).value)
    }

    /**
     * II-061/069/070, IA-115..119: angle is a presentation. The host still writes the camera's own
     * durations (an angle pick, Manual from Auto, AE-L) and Auto, and the first manual shutter may
     * leave Auto, as before the shared session.
     */
    @Test fun emulatedAngleStillAdmitsNativeDurationsAutoAndLeavingAuto() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        camera.program = 0
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        val session = camera.connectedSession()
        reportCadence(48, session)
        session.configureShutter(com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
        assertEquals(com.opencapture.opencine.core.Availability.Available,
            session.snapshots.value.capabilities[SettingKey.SHUTTER]?.availability)
        val (_, manual) = session.run(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 50)))))
        assertEquals(CommandStage.Confirmed, manual.stage, "Manual from Auto in angle mode")
        assertEquals(1.0 / 50, requireNotNull(LunaPhotographySettings.parse(camera.sent.last().body).videoExposure).shutterSeconds, 1e-9)
        val (_, faster) = session.run(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 100)))))
        assertEquals(CommandStage.Confirmed, faster.stage, "an angle pick sent as its 1/N")
        val (_, auto) = session.run(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Auto)))
        assertEquals(CommandStage.Confirmed, auto.stage, "Auto exposure from angle mode")
        val (_, angle) = session.run(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Angle(180.0))))
        assertEquals(CommandStage.Confirmed, angle.stage, "an angle from Auto composes 1/N from the cadence")
        assertEquals(1.0 / 50, requireNotNull(LunaPhotographySettings.parse(camera.sent.last().body).videoExposure).shutterSeconds, 1e-9)
    }

    private fun reportPhotoMode(session: LunaCameraSession) {
        session.ingest(LunaDeviceStatus.parse(LunaWire.blob(2, LunaWire.integer(40, 0) + LunaWire.integer(41, 100))))
    }

    private fun offersAngles(session: LunaCameraSession): Boolean =
        session.snapshots.value.capabilities[SettingKey.SHUTTER]?.domain?.choices.orEmpty()
            .any { it is SettingValue.Shutter && it.value is ShutterValue.Angle }

    /** CodeRabbit on #114: photo exposure never composes an angle, so photo offers durations only. Swift twin. */
    @Test fun emulatedAngleOffersNoAnglesInPhotoMode() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        camera.program = 3
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        val session = camera.connectedSession()
        reportCadence(48, session)
        session.configureShutter(com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
        assertTrue(offersAngles(session), "video with a cadence offers angles")
        reportPhotoMode(session)
        assertFalse(offersAngles(session), "photo mode offered an angle it cannot write")
        assertEquals(com.opencapture.opencine.core.Availability.Available,
            session.snapshots.value.capabilities[SettingKey.SHUTTER]?.availability)
    }

    /** CodeRabbit on #114: an unknown cadence withholds only the angles; durations stay writable. Swift twin. */
    @Test fun unknownCadenceWithholdsOnlyTheAngles() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        camera.program = 3
        camera.iso = 400
        camera.shutterSeconds = 1.0 / 50
        val session = camera.connectedSession()
        session.configureShutter(com.opencapture.opencine.media.HostShutterPresentation.EMULATED_ANGLE)
        assertFalse(offersAngles(session), "an angle offered without a cadence to compose it")
        assertEquals(com.opencapture.opencine.core.Availability.Available,
            session.snapshots.value.capabilities[SettingKey.SHUTTER]?.availability)
        val (_, outcome) = session.run(CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 100)))))
        assertEquals(CommandStage.Confirmed, outcome.stage)
        assertEquals(1.0 / 100, requireNotNull(LunaPhotographySettings.parse(camera.sent.last().body).videoExposure).shutterSeconds, 1e-9)
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @AfterTest fun tearDown() = scope.cancel()

    private suspend fun LunaCameraSession.run(intent: CameraCommandIntent): Pair<CommandReceipt, CommandReceipt> {
        val command = CameraCommand(intent, CommandPreconditions(snapshots.value))
        val submitted = submit(command)
        return submitted to (outcome(command.operation) ?: submitted)
    }

    /**
     * The old hole: `CameraControls` defaults returned false for recording, exposure and white
     * balance. Every writable capability the session describes must reach the camera and
     * confirm; a descriptor without an implementation fails here.
     */
    @Test fun everyAdvertisedWritableCapabilityReachesTheCamera() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        session.configureLens(1.0..4.0)
        val described = session.snapshots.value.capabilities.descriptors.values.filter { it.access == SettingAccess.READ_WRITE }
        assertTrue(
            described.map { it.key }.containsAll(listOf(SettingKey.ISO, SettingKey.SHUTTER, SettingKey.WHITE_BALANCE, SettingKey.RECORDING)),
            "the CORE-02 slice must be advertised",
        )
        for (descriptor in described) {
            assertEquals(com.opencapture.opencine.core.Availability.Available, descriptor.availability, "${descriptor.key}")
            val intent = if (descriptor.key == SettingKey.RECORDING) {
                CameraCommandIntent.StartRecording
            } else if (descriptor.key == SettingKey.ZOOM) {
                CameraCommandIntent.Set(SettingValue.Zoom(descriptor.domain!!.range!!.endInclusive))
            } else {
                val reported = session.snapshots.value.value(descriptor.key).value
                CameraCommandIntent.Set(descriptor.domain?.choices?.lastOrNull { it != reported } ?: fail("${descriptor.key} has no value"))
            }
            val before = camera.sentCount()
            val (_, outcome) = session.run(intent)
            assertEquals(CommandStage.Confirmed, outcome.stage, "${descriptor.key}")
            assertEquals(before + 1, camera.sentCount(), "${descriptor.key} never reached the camera")
        }
    }

    @Test fun acceptedWriteThatDoesNotStickIsNotApplied() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession(settle = 600.milliseconds)
        camera.ignoresWrites = true
        val (submitted, outcome) = session.run(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(800))))
        assertEquals(CommandStage.AwaitingObservation, submitted.stage, "acknowledged is not confirmed")
        assertEquals(CommandStage.Failed(CommandFailure.NOT_APPLIED), outcome.stage)
        assertEquals(SettingValue.Iso(ISOValue.Auto), session.snapshots.value.value(SettingKey.ISO).value)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun slowSettleStaysPendingAndConfirmsFromReadback() = runTest {
        val camera = FakeLuna(backgroundScope) { MonotonicInstant(testScheduler.currentTime.milliseconds) }
        val session = camera.connectedSession()
        camera.applyDelay = 300.milliseconds
        val command = CameraCommand(
            CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200))),
            CommandPreconditions(session.snapshots.value),
        )
        assertEquals(CommandStage.AwaitingObservation, session.submit(command).stage)
        assertEquals(
            SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600)), session.snapshots.value.value(SettingKey.WHITE_BALANCE).value,
            "a request is never written into the reported snapshot",
        )
        assertEquals(CommandStage.Confirmed, session.outcome(command.operation)?.stage)
        val wb = session.snapshots.value.value(SettingKey.WHITE_BALANCE)
        assertEquals(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200)), wb.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, wb.origin)
    }

    @Test fun noReadbackTimesOut() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession(settle = 600.milliseconds)
        camera.silent = true
        assertEquals(CommandStage.TimedOut, session.run(CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Auto))).second.stage)
    }

    @Test fun cameraRefusalIsARejection() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        camera.refuses = true
        val (_, outcome) = session.run(CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Auto)))
        assertEquals(CommandStage.Rejected(CommandRejection.CameraRefused), outcome.stage)
        assertEquals(ConnectionState.Ready, session.snapshots.value.connection, "a refusal is not a lost link")
    }

    /**
     * Hardware pass 8.4 (Insta + Luna Ultra): the storage tap had no recording time step. The
     * camera reports remaining record time per card (option 99); each usable volume carries its
     * own, camera reported. A full card keeps a known zero; a reply without option 99 keeps the
     * last report. Swift twin `testRemainingRecordTimeReachesEachCardVolume`.
     */
    @Test fun remainingRecordTimeReachesEachCardVolume() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        fun card(state: Long, free: Long, total: Long, location: Long) = LunaWire.integer(1, state) +
            LunaWire.integer(2, free) + LunaWire.integer(3, total) + LunaWire.integer(4, location)
        val nested = LunaWire.integer(40, 100) + LunaWire.integer(41, 0) +
            LunaWire.blob(176, card(0, 99_000_000_000, 125_000_000_000, 2)) +
            LunaWire.blob(176, card(0, 1_000_000, 64_000_000_000, 3))
        session.ingest(LunaDeviceStatus.parse(LunaWire.blob(2, nested)))
        assertNull(session.snapshots.value.storage.recordingTimeLabel, "no option 99 yet: unknown")

        fun remaining(vararg entries: Pair<Long, Long>) = LunaPhotographySettings.parse(
            LunaWire.blob(1, LunaWire.varint(99)) +
                LunaWire.blob(2, entries.fold(ByteArray(0)) { acc, (seconds, location) ->
                    acc + LunaWire.blob(99, LunaWire.integer(1, seconds) + LunaWire.integer(2, location))
                }) + LunaWire.integer(3, LunaControl.FUNCTION_MODE_VIDEO.toLong()))
        session.ingest(remaining(3001L to 2L, 0L to 3L))
        val volumes = assertNotNull(session.snapshots.value.storage.value)
        val inner = volumes.first { it.id == "location-2" }
        val sd = volumes.first { it.id == "location-3" }
        assertEquals(3001.seconds, inner.remainingRecordingTime.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, inner.remainingRecordingTime.origin)
        assertEquals(0.seconds, sd.remainingRecordingTime.value, "a full card is a known zero")
        assertEquals(99_000_000_000, inner.freeBytes.value, "the card readout is kept")
        assertEquals("50 Min", session.snapshots.value.storage.recordingTimeLabel)
        assertEquals("79%", session.snapshots.value.storage.storageReadout?.percent)
        // Hardware pass 8.4: the shared storage cycle now reaches the time on Insta too.
        val storage = session.snapshots.value.storage
        assertEquals(listOf("99GB", "79%", "50 Min"), com.opencapture.opencine.media.StorageReadoutCycle.forms(storage, photo = false))
        assertEquals(listOf("99GB", "79%"), com.opencapture.opencine.media.StorageReadoutCycle.forms(storage, photo = true))

        camera.reportSettings()
        assertEquals("50 Min", session.snapshots.value.storage.recordingTimeLabel, "the settings poll keeps it")
        session.ingest(LunaDeviceStatus.parse(LunaWire.blob(2, nested)))
        assertEquals("50 Min", session.snapshots.value.storage.recordingTimeLabel, "a fresh card report keeps it")
        session.ingest(remaining(0L to 3L))
        assertNull(session.snapshots.value.storage.recordingTimeLabel, "no entry for that card: unknown")
        Unit
    }

    @Test fun unknownStaysUnknown() = runBlocking {
        val camera = FakeLuna(scope)
        camera.captureState = null
        val session = camera.makeSession()
        session.linkChanged(LinkPhase.LIVE, null)
        camera.reportDevice()
        val snapshot = session.snapshots.value
        assertNull(snapshot.recording.value, "no capture report: unknown, not idle")
        assertNull(snapshot.power.battery.value, "no battery report: unknown, not empty")
        assertNull(snapshot.storage.value, "no storage report: unknown, not none")
        assertNull(snapshot.device, "no serial: no invented identity")
        assertNull(snapshot.value(SettingKey.ISO).value)
        camera.captureState = 4
        camera.reportCapture()
        assertNull(session.snapshots.value.recording.value, "a photo capture state says nothing about video")
        camera.captureState = 1
        camera.reportCapture()
        assertEquals(RecordingState.RECORDING, session.snapshots.value.recording.value)
        camera.captureState = 4
        camera.reportCapture()
        assertNull(session.snapshots.value.recording.value, "an unreadable state does not keep a stale one")
        assertNull(LunaReadout.readout(null, null, LunaCaptureStatus(4, 0, 0)).recording, "the readout keeps unknown too")
    }

    @Test fun recordingAndExposureWaitForTheCameraToReportThem() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.makeSession()
        session.linkChanged(LinkPhase.LIVE, null)
        val unavailable = CommandStage.Rejected(CommandRejection.Unavailable(com.opencapture.opencine.core.UnavailableReason.NotReady))
        assertEquals(unavailable, session.run(CameraCommandIntent.StartRecording).second.stage)
        assertEquals(unavailable, session.run(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(400)))).second.stage)
    }

    @Test fun explicitStartWhileRecordingSendsNothing() = runBlocking {
        val camera = FakeLuna(scope)
        camera.captureState = 1
        val session = camera.connectedSession()
        assertEquals(CommandStage.Confirmed, session.run(CameraCommandIntent.StartRecording).second.stage)
        assertEquals(0, camera.sentCount(), "a start while recording must not reach the camera")
        camera.captureState = 0
        camera.reportCapture()
        assertEquals(CommandStage.Confirmed, session.run(CameraCommandIntent.StopRecording).second.stage)
        assertEquals(0, camera.sentCount(), "a stop while idle must not reach the camera")
    }

    @Test fun recordingIsReportedOnlyByTheCamera() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        camera.applyDelay = 150.milliseconds
        val command = CameraCommand(CameraCommandIntent.StartRecording, CommandPreconditions(session.snapshots.value))
        assertEquals(CommandStage.AwaitingObservation, session.submit(command).stage)
        assertEquals(RecordingState.IDLE, session.snapshots.value.recording.value, "ACK is not a recording report")
        assertEquals(CommandStage.Confirmed, session.outcome(command.operation)?.stage)
        assertEquals(RecordingState.RECORDING, session.snapshots.value.recording.value)
        assertEquals(listOf(4), camera.sent.map { it.code })
    }

    /** ISO and shutter share one Luna message: an ISO write keeps a still-pending shutter. */
    @Test fun exposureWriteCarriesThePendingShutter() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        camera.applyDelay = 200.milliseconds
        val shutter = CameraCommand(
            CameraCommandIntent.Set(SettingValue.Shutter(ShutterValue.Duration(Rational(1, 100)))),
            CommandPreconditions(session.snapshots.value),
        )
        session.submit(shutter)
        val iso = CameraCommand(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(400))), CommandPreconditions(session.snapshots.value))
        session.submit(iso)
        val sent = LunaPhotographySettings.parse(camera.lastSent().body).videoExposure ?: fail("no exposure sent")
        assertEquals(3L, sent.program)
        assertEquals(400L, sent.iso)
        assertEquals(0.01, sent.shutterSeconds, 1e-9)
        assertEquals(CommandStage.Confirmed, session.outcome(shutter.operation)?.stage)
        assertEquals(CommandStage.Confirmed, session.outcome(iso.operation)?.stage)
    }

    /**
     * SHELL-01 (Swift `testPublishesMotionTimecodeAndNoAudio`): Luna publishes its gimbal with
     * camera-reported pose, host-derived timecode and no audio levels, so the projection lays out
     * the stick, head tracking and timecode, never a meter.
     */
    @Test fun publishesMotionTimecodeAndNoAudio() {
        val session = FakeLuna(scope).connectedSession()
        val capabilities = session.snapshots.value.capabilities
        assertEquals(TimecodeCapability.supported(TimecodePrecision.Seconds), capabilities.timecodeCapability, "host clock: whole seconds")
        assertEquals(SupportStatus.UNSUPPORTED, capabilities.audioLevels)
        assertEquals(SupportStatus.SUPPORTED, LunaCameraSession.MOTION.pose)
        assertFalse(MotionAxis.ZOOM in LunaCameraSession.MOTION.axes, "moves keep one zoom")
        // Audio off although the base has it (unsupported overrides); no iris (fixed aperture);
        // zoom from Luna's declared stops before the live range arrives (the one control model).
        assertEquals(
            MonitorLayoutCapabilities(gimbal = true, zoom = true, focus = true, headTracking = true, clipDelete = true, timecode = true),
            session.layout(MonitorLayoutCapabilities(audio = true, clipDelete = true)),
        )
        assertNull(session.snapshots.value.timecode.value, "nothing derived yet: unknown")
        session.ingest(CameraTimecodeReading(15, 39, 50))
        assertEquals(50, session.snapshots.value.timecodeReading.value?.seconds)
        assertEquals(ObservationOrigin.CLOCK_DERIVED, session.snapshots.value.timecode.origin, "never a camera counter")
    }

    @Test fun linkChangesInvalidateTimecodeUntilTheReadySourcePublishesAgain() {
        for (phase in listOf(LinkPhase.IDLE, LinkPhase.FAILED, LinkPhase.OPENING_DATALINK)) {
            val session = FakeLuna(scope).connectedSession()
            val reading = CameraTimecodeReading(15, 39, 50)
            session.ingest(reading)
            assertEquals(reading, session.snapshots.value.timecodeReading.value)
            session.linkChanged(LinkPhase.SCANNING)
            assertEquals(reading, session.snapshots.value.timecodeReading.value, "scanning keeps the active source")

            session.linkChanged(phase)
            assertEquals(ObservedValue.unknown, session.snapshots.value.timecodeReading, "$phase retires the clock")
            assertEquals(ObservedValue.unknown, session.snapshots.value.timecode)
            session.ingest(reading)
            assertEquals(ObservedValue.unknown, session.snapshots.value.timecodeReading, "late recovery frames stay retired")

            val epoch = session.snapshots.value.epoch
            session.linkChanged(LinkPhase.LIVE)
            assertEquals(epoch.next(), session.snapshots.value.epoch)
            assertNull(session.snapshots.value.timecodeReading.value, "a new epoch waits for a fresh frame")
            session.ingest(reading)
            assertEquals(reading, session.snapshots.value.timecodeReading.value)
            assertEquals(ObservationOrigin.CLOCK_DERIVED, session.snapshots.value.timecodeReading.origin)
            assertNull(session.snapshots.value.timecode.value, "whole seconds never invent frames")
            session.linkChanged(LinkPhase.LIVE)
            assertEquals(ObservedValue.unknown, session.snapshots.value.timecodeReading, "another LIVE is another epoch")
            session.closeNow(SessionCloseReason.REQUESTED)
            session.ingest(reading)
            assertNull(session.snapshots.value.timecodeReading.value)
        }
    }

    @Test fun recordingProfileIsCameraReportedOrUnknown() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        assertNull(session.recordingProfile.value)
        camera.colorMode = 2
        camera.reportSettings()
        assertEquals("com.opencapture.insta360.luna.profile.i-log", session.recordingProfile.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, session.recordingProfile.origin)
    }

    @Test fun aNewerWriteToTheSameSettingSupersedesTheOlder() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        camera.applyDelay = 10.seconds
        val older = session.submit(
            CameraCommand(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(400))), CommandPreconditions(session.snapshots.value)),
        )
        assertEquals(CommandStage.AwaitingObservation, session.receipt(older.operation)?.stage)
        session.submit(
            CameraCommand(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(1600))), CommandPreconditions(session.snapshots.value)),
        )
        assertEquals(CommandStage.Failed(CommandFailure.SUPERSEDED), session.receipt(older.operation)?.stage)
        session.closeNow(SessionCloseReason.REQUESTED)
    }

    @Test fun linkLossEndsInFlightWritesAsUnknownAndANewLinkIsANewEpoch() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        camera.applyDelay = 10.seconds
        val epoch = session.snapshots.value.epoch
        val command = CameraCommand(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(1600))), CommandPreconditions(session.snapshots.value))
        session.submit(command)
        session.linkChanged(LinkPhase.FAILED)
        assertEquals(CommandStage.OutcomeUnknown, session.outcome(command.operation)?.stage)
        assertTrue(session.snapshots.value.connection is ConnectionState.Recovering)
        session.linkChanged(LinkPhase.LIVE)
        assertEquals(epoch.next(), session.snapshots.value.epoch)
        val stale = CameraCommand(
            CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(200))),
            CommandPreconditions(session.id, epoch, session.snapshots.value.capabilities.revision),
        )
        assertEquals(CommandStage.Rejected(CommandRejection.StaleEpoch), session.submit(stale).stage, "an edit from the old link is refused")
    }

    /**
     * STATE-01 gate (plan 11.2 cases 1, 11, 12): two cameras, each with its own session and link, in
     * one process. Commands, reports, identity and teardown never cross; closing one leaves the
     * other working.
     */
    @Test fun twoSessionsRunConcurrentlyWithoutCrossover() = runBlocking {
        val a = FakeLuna(scope)
        val b = FakeLuna(scope)
        val sa = a.connectedSession(serial = "LUNA-A")
        val sb = b.connectedSession(serial = "LUNA-B")
        assertEquals("LUNA-A", sa.snapshots.value.device?.value)
        assertEquals("LUNA-B", sb.snapshots.value.device?.value)
        assertTrue(sa.id != sb.id)
        a.applyDelay = 200.milliseconds
        b.applyDelay = 300.milliseconds
        val iso = async { sa.run(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(800)))).second }
        val wb = async { sb.run(CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200)))).second }
        assertEquals(CommandStage.Confirmed, iso.await().stage)
        assertEquals(CommandStage.Confirmed, wb.await().stage)
        // Each command reached only its own camera.
        assertEquals(listOf(800L), a.sent.map { LunaPhotographySettings.parse(it.body).videoExposure?.iso })
        assertEquals(listOf(3200L), b.sent.map { LunaPhotographySettings.parse(it.body).whiteBalanceKelvin })
        // Each report updated only its own session.
        assertEquals(SettingValue.Iso(ISOValue.Manual(800)), sa.snapshots.value.value(SettingKey.ISO).value)
        assertEquals(SettingValue.Iso(ISOValue.Auto), sb.snapshots.value.value(SettingKey.ISO).value)
        assertEquals(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600)), sa.snapshots.value.value(SettingKey.WHITE_BALANCE).value)
        assertEquals(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200)), sb.snapshots.value.value(SettingKey.WHITE_BALANCE).value)
        val revisionB = sb.snapshots.value.revision
        a.reportSettings(); a.reportCapture(); a.reportDevice()
        assertEquals(revisionB, sb.snapshots.value.revision, "A's reports never reach B")
        // Teardown of A: B keeps its link, its state and its controls.
        val sentA = a.sentCount()
        sa.close(SessionCloseReason.REQUESTED)
        assertEquals(ConnectionState.Disconnected(SessionCloseReason.REQUESTED), sa.snapshots.value.connection)
        assertEquals(ConnectionState.Ready, sb.snapshots.value.connection)
        assertEquals(CommandStage.Confirmed, sb.run(CameraCommandIntent.StartRecording).second.stage)
        assertEquals(RecordingState.RECORDING, sb.snapshots.value.recording.value)
        assertEquals(RecordingState.IDLE, sa.snapshots.value.recording.value)
        assertEquals(sentA, a.sentCount(), "closing A sent nothing, and B's record went to B")
        assertEquals(CommandStage.Rejected(CommandRejection.SessionClosed), sa.run(CameraCommandIntent.StartRecording).second.stage)
    }

    /**
     * An eager `outcome` awaiter (an Unconfined coroutine resumes the moment the settle
     * completes its waiter, inside the reporting ingest) must observe the feed snapshot the
     * settle confirmed, never the one before it. Manual clock: the settle decision comes from
     * the report, never from elapsed time.
     */
    private suspend fun eagerOutcome(
        scope: CoroutineScope,
        camera: FakeLuna,
        session: LunaCameraSession,
        command: CameraCommand,
        report: () -> Unit,
    ): Pair<CommandReceipt, CameraSnapshot> {
        var observed: CameraSnapshot? = null
        val observer = scope.async(Dispatchers.Unconfined) {
            val receipt = requireNotNull(session.outcome(command.operation))
            observed = session.snapshots.value
            receipt
        }
        report()
        val receipt = observer.await()
        return receipt to requireNotNull(observed) { "the eager observer never ran" }
    }

    @Test fun eagerOutcomeObserverSeesTheIsoTheSettleConfirmed() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        val session = camera.connectedSession()
        val command = CameraCommand(
            CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(800))),
            CommandPreconditions(session.snapshots.value),
        )
        assertEquals(CommandStage.AwaitingObservation, session.submit(command).stage)
        val (receipt, observed) = eagerOutcome(this, camera, session, command) {
            camera.iso = 800
            camera.reportSettings()
        }
        assertEquals(CommandStage.Confirmed, receipt.stage)
        assertEquals(SettingValue.Iso(ISOValue.Manual(800)), observed.value(SettingKey.ISO).value,
            "an eager awaiter must see the reported value the settle confirmed")
    }

    @Test fun eagerOutcomeObserverSeesTheWhiteBalanceTheSettleConfirmed() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        val session = camera.connectedSession()
        val command = CameraCommand(
            CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200))),
            CommandPreconditions(session.snapshots.value),
        )
        assertEquals(CommandStage.AwaitingObservation, session.submit(command).stage)
        val (receipt, observed) = eagerOutcome(this, camera, session, command) {
            camera.kelvin = 3200
            camera.reportSettings()
        }
        assertEquals(CommandStage.Confirmed, receipt.stage)
        assertEquals(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200)), observed.value(SettingKey.WHITE_BALANCE).value,
            "an eager awaiter must see the reported value the settle confirmed")
    }

    @Test fun eagerOutcomeObserverSeesTheRecordingTheCaptureSettled() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        val session = camera.connectedSession()
        val command = CameraCommand(CameraCommandIntent.StartRecording, CommandPreconditions(session.snapshots.value))
        assertEquals(CommandStage.AwaitingObservation, session.submit(command).stage)
        val (receipt, observed) = eagerOutcome(this, camera, session, command) {
            camera.captureState = 1
            camera.reportCapture()
        }
        assertEquals(CommandStage.Confirmed, receipt.stage)
        assertEquals(RecordingState.RECORDING, observed.recording.value,
            "an eager awaiter must see the recording state the settle confirmed")
    }

    /**
     * Settle before publish is load-bearing: when the readback that satisfies a write is
     * published, the write is already finished, so an eager feed observer that answers the
     * reported value with a newer write of the same key must supersede nothing. A publish
     * before settle would hand the observer a write whose command is still in `targets` and
     * turn a camera-matched Confirmed into Failed(SUPERSEDED).
     */
    @Test fun eagerFeedObserverResubmittingTheSameKeyNeverSupersedesAMatchedCommand() = runTest {
        val camera = FakeLuna(this) { MonotonicInstant(Duration.ZERO) }
        val session = camera.connectedSession()
        val first = CameraCommand(
            CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200))),
            CommandPreconditions(session.snapshots.value),
        )
        assertEquals(CommandStage.AwaitingObservation, session.submit(first).stage)
        var observed: CameraSnapshot? = null
        val resubmitted = CompletableDeferred<CommandReceipt>()
        backgroundScope.launch(Dispatchers.Unconfined) {
            session.snapshots.collect { snapshot ->
                if (resubmitted.isCompleted) return@collect
                if (snapshot.value(SettingKey.WHITE_BALANCE).value ==
                    SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200))) {
                    observed = snapshot
                    val second = CameraCommand(
                        CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(6400))),
                        CommandPreconditions(snapshot),
                    )
                    resubmitted.complete(session.submit(second))
                }
            }
        }
        camera.kelvin = 3200
        camera.reportSettings()
        assertEquals(CommandStage.Confirmed, session.outcome(first.operation)?.stage,
            "a camera-matched command stays Confirmed when the same key is written again")
        assertEquals(CommandStage.AwaitingObservation, resubmitted.await().stage)
        assertEquals(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200)), requireNotNull(observed).value(SettingKey.WHITE_BALANCE).value)
        // The newer write still settles on its own readback.
        camera.kelvin = 6400
        camera.reportSettings()
        assertEquals(CommandStage.Confirmed, session.outcome(resubmitted.await().operation)?.stage)
        assertEquals(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(6400)), session.snapshots.value.value(SettingKey.WHITE_BALANCE).value)
    }

    /**
     * Plan 5.2 / STATE-01: the control epoch changes only with the control link. A stream-only
     * restart (the backend's `pauseLive`/`resumeLive`: stop and start live on the open socket, no
     * link phase change) leaves an in-flight write valid and confirmable.
     */
    @Test fun streamRestartKeepsTheControlEpoch() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        camera.applyDelay = 300.milliseconds
        val before = session.snapshots.value
        val command = CameraCommand(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(400))), CommandPreconditions(before))
        assertEquals(CommandStage.AwaitingObservation, session.submit(command).stage)
        camera.receive(LunaControl.stopLive)
        camera.receive(LunaControl.startLive)
        assertEquals(before.epoch, session.snapshots.value.epoch)
        assertEquals(ConnectionState.Ready, session.snapshots.value.connection)
        assertEquals(CommandStage.Confirmed, session.outcome(command.operation)?.stage)
        // An edit built before the restart is still admitted.
        val later = CameraCommand(CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(800))), CommandPreconditions(before))
        assertEquals(CommandStage.Confirmed, (session.submit(later).let { session.outcome(later.operation) ?: it }).stage)
    }

    @Test fun closeNeverSends() = runBlocking {
        val camera = FakeLuna(scope)
        val session = camera.connectedSession()
        session.close(SessionCloseReason.REQUESTED)
        session.close(SessionCloseReason.REQUESTED)
        assertEquals(ConnectionState.Disconnected(SessionCloseReason.REQUESTED), session.snapshots.value.connection)
        assertEquals(CommandStage.Rejected(CommandRejection.SessionClosed), session.run(CameraCommandIntent.StartRecording).second.stage)
        assertEquals(0, camera.sentCount())
    }
}
