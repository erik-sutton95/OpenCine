package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraRecordingFormat
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.FocusMode
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.SupportStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import com.opencapture.opencine.insta360.shell.ConnectionPhase as LinkPhase

/** Same manual-clock scenarios as Swift LunaLensControlTests; no real delays or camera. */
private class LensHarness(scope: CoroutineScope) {
    val sent = mutableListOf<LunaControl.Request>()
    var clock = Duration.ZERO
    val session = LunaCameraSession(
        send = { sent += it; ByteArray(0) }, functionMode = { 7 },
        readSettings = {}, readCapture = {}, scope = scope,
        now = { MonotonicInstant(clock) },
    ).also { it.linkChanged(LinkPhase.LIVE, "SIMULATED-LENS") }
    val current get() = session.snapshots.value
    fun command(value: SettingValue) = CameraCommand(CameraCommandIntent.Set(value), CommandPreconditions(current))
    fun report(types: List<Int> = listOf(53, 93), zoom: Double? = null, focus: Long? = null, bank: Int = 7) {
        session.ingest(LunaPhotographySettings(types = types, functionMode = bank, zoom = zoom, afMode = focus))
    }
}

class LunaLensControlTest {
    @Test fun commonExposureUnknownProgramWithdrawsTheOldReport() = runTest {
        val h = LensHarness(backgroundScope)
        val known = LunaPhotographySettings(types = listOf(21), functionMode = 7,
            videoExposure = LunaExposure(3, 400, 0.02))
        h.session.ingest(known)
        assertEquals(SettingValue.Iso(com.opencapture.opencine.core.ISOValue.Manual(400)), h.current.value(SettingKey.ISO).value)
        h.session.ingest(known.copy(videoExposure = LunaExposure(999_999, 400, 0.02)))
        assertNull(h.current.value(SettingKey.ISO).value, "An unknown program does not declare automatic ISO")
        assertNull(h.current.value(SettingKey.SHUTTER).value, "An unknown program does not declare automatic shutter")
        val notReady = com.opencapture.opencine.core.Availability.Unavailable(com.opencapture.opencine.core.UnavailableReason.NotReady)
        assertEquals(notReady, h.current.capabilities.descriptors[SettingKey.ISO]?.availability, "A withdrawn ISO cannot accept a combined exposure write")
        assertEquals(notReady, h.current.capabilities.descriptors[SettingKey.SHUTTER]?.availability)
        assertTrue(h.sent.isEmpty())
    }

    @Test fun commonExposureExplicitAbsentReportWithdrawsTheOldValues() = runTest {
        val h = LensHarness(backgroundScope)
        val known = LunaPhotographySettings(types = listOf(21), functionMode = 7,
            videoExposure = LunaExposure(3, 400, 0.02))
        h.session.ingest(known)
        assertEquals(SettingValue.Shutter(com.opencapture.opencine.core.ShutterValue.Duration(Rational(1, 50))), h.current.value(SettingKey.SHUTTER).value)
        h.session.ingest(known.copy(videoExposure = null))
        assertNull(h.current.value(SettingKey.ISO).value)
        assertNull(h.current.value(SettingKey.SHUTTER).value)
        val notReady = com.opencapture.opencine.core.Availability.Unavailable(com.opencapture.opencine.core.UnavailableReason.NotReady)
        assertEquals(notReady, h.current.capabilities.descriptors[SettingKey.ISO]?.availability, "A withdrawn ISO cannot accept a combined exposure write")
        assertEquals(notReady, h.current.capabilities.descriptors[SettingKey.SHUTTER]?.availability)
        assertTrue(h.sent.isEmpty())
    }

    @Test fun commonExposurePreservesAReportedDurationLongerThanOneSecond() = runTest {
        val h = LensHarness(backgroundScope)
        h.session.ingest(LunaPhotographySettings(types = listOf(21), functionMode = 7,
            videoExposure = LunaExposure(3, 400, 2.0)))
        assertEquals(SettingValue.Shutter(com.opencapture.opencine.core.ShutterValue.Duration(Rational(2))), h.current.value(SettingKey.SHUTTER).value)
        assertTrue(h.sent.isEmpty())
    }

    /** An explicitly requested unsupported format withdraws its old common cadence. */
    @Test fun explicitUnknownRecordingFormatClearsTheOldCommonRate() = runTest {
        val h = LensHarness(backgroundScope)
        h.session.ingest(LunaPhotographySettings(types = listOf(31), functionMode = 7, recordResolution = 48L))
        assertEquals(SettingValue.FrameRate(Rational(25)), h.current.value(SettingKey.FRAME_RATE).value)
        h.session.ingest(LunaPhotographySettings(types = listOf(31), functionMode = 7, recordResolution = 999_999L))
        assertNull(h.current.value(SettingKey.FRAME_RATE).value, "An unsupported report cannot retain the old recording cadence")
        assertNull(h.current.recordingFormat.dimensions.value)
        assertNull(h.current.value(SettingKey.FRAME_RATE).observedAt)
        h.session.ingest(LunaPhotographySettings(types = listOf(31), functionMode = 7, recordResolution = 48L))
        val known = h.current.value(SettingKey.FRAME_RATE)
        assertTrue(known.observedAt != null)
        h.session.ingest(LunaPhotographySettings(types = listOf(39), functionMode = 7, whiteBalanceKelvin = 5600L))
        assertEquals(known, h.current.value(SettingKey.FRAME_RATE), "An unrelated partial reply retains the cadence and timestamp")
        h.session.ingest(LunaPhotographySettings(types = listOf(31), functionMode = 7))
        assertNull(h.current.value(SettingKey.FRAME_RATE).value)
        assertNull(h.current.value(SettingKey.FRAME_RATE).observedAt)
        assertTrue(h.sent.isEmpty(), "Reading recording facts never sends a command")
    }

    @Test fun explicitUnknownRecordingProfileClearsTheOldCommonProfile() = runTest {
        val h = LensHarness(backgroundScope)
        h.session.ingest(LunaPhotographySettings(types = listOf(35), functionMode = 7, colorMode = 2L))
        kotlin.test.assertNotNull(h.session.recordingProfile.value)
        h.session.ingest(LunaPhotographySettings(types = listOf(35), functionMode = 7, colorMode = 999_999L))
        assertNull(h.session.recordingProfile.value, "An unsupported report cannot retain the old recording profile")
        assertNull(h.current.recordingFormat.profile.value)
        assertTrue(h.sent.isEmpty(), "Reading recording facts never sends a command")
    }

    @Test fun recordingFactsKeepIndependentProvenanceAndNeverAssumePreviewCodec() = runTest {
        val h = LensHarness(backgroundScope)
        h.session.ingest(LunaPhotographySettings(types = listOf(35), functionMode = 7, colorMode = 2L))
        val profile = h.current.recordingFormat.profile
        assertEquals("I-Log", profile.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, profile.origin)
        h.clock += 1.seconds
        h.session.ingest(LunaPhotographySettings(types = listOf(31), functionMode = 7, recordResolution = 48L))
        assertEquals(CameraRecordingFormat.Dimensions.measured(3840, 2160), h.current.recordingFormat.dimensions.value)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, h.current.recordingFormat.dimensions.origin)
        assertEquals(MonotonicInstant(h.clock), h.current.recordingFormat.dimensions.observedAt)
        assertEquals(profile, h.current.recordingFormat.profile, "A dimension report cannot restamp the retained profile")
        assertNull(h.current.recordingFormat.codec.value, "HEVC preview is not a recording-codec report")
        val dimensions = h.current.recordingFormat.dimensions
        h.session.ingest(LunaPhotographySettings(types = listOf(31), functionMode = 1, recordResolution = 49L))
        assertEquals(dimensions, h.current.recordingFormat.dimensions)
        h.session.closeNow(SessionCloseReason.REPLACED)
        h.session.ingest(LunaPhotographySettings(types = listOf(31), functionMode = 7, recordResolution = 49L))
        assertEquals(dimensions, h.current.recordingFormat.dimensions)
        assertTrue(h.sent.isEmpty())
    }

    /** A5-09: option 31's schema rate is a typed read-only Rational, never rounded or written. */
    @Test fun recordRateIsAReadOnlyRationalFromTheResolutionOption() = runTest {
        val h = LensHarness(backgroundScope)
        assertEquals(SettingAccess.READ_ONLY, h.current.capabilities[SettingKey.FRAME_RATE]?.access)
        assertNull(h.current.value(SettingKey.FRAME_RATE).value, "no report is unknown")
        h.session.ingest(LunaPhotographySettings(types = listOf(31), functionMode = 7, recordResolution = 48L)) // 4K25
        assertEquals(SettingValue.FrameRate(Rational(25)), h.current.value(SettingKey.FRAME_RATE).value)
        assertEquals(
            CommandStage.Rejected(CommandRejection.ReadOnly),
            h.session.submit(h.command(SettingValue.FrameRate(Rational(24)))).stage,
        )
    }

    @Test fun lensDescriptorsRequireConfiguredZoomAndNeverInventReports() = runTest {
        val h = LensHarness(backgroundScope)
        assertEquals(SupportStatus.UNKNOWN, h.current.capabilities.support(SettingKey.ZOOM))
        assertEquals(
            listOf(SettingValue.FocusMode(FocusMode.SINGLE), SettingValue.FocusMode(FocusMode.CONTINUOUS)),
            h.current.capabilities[SettingKey.FOCUS_MODE]?.domain?.choices,
        )
        assertNull(h.current.value(SettingKey.ZOOM).value)
        assertNull(h.current.value(SettingKey.FOCUS_MODE).value)
        h.session.configureLens(1.0..4.0)
        assertEquals(1.0..4.0, h.current.capabilities[SettingKey.ZOOM]?.domain?.range)
        assertTrue(h.session.layout().zoom)
        assertTrue(h.session.layout().focus)
        assertNull(h.current.value(SettingKey.ZOOM).value)
    }

    @Test fun lensAcknowledgementWaitsForRampedReadbackAndResubmissionIsIdempotent() = runTest {
        val h = LensHarness(backgroundScope)
        h.session.configureLens(1.0..4.0)
        h.report(zoom = 1.0, focus = 1)
        val zoom = h.command(SettingValue.Zoom(3.0))
        assertEquals(CommandStage.AwaitingObservation, h.session.submit(zoom).stage)
        assertEquals(SettingValue.Zoom(1.0), h.current.value(SettingKey.ZOOM).value)
        assertEquals(3.0, LunaPhotographySettings.parse(h.sent.last().body).zoom)
        h.clock += 100.milliseconds
        h.report(types = listOf(53), zoom = 2.5)
        assertEquals(CommandStage.AwaitingObservation, h.session.receipt(zoom.operation)?.stage)
        h.report(types = listOf(53), zoom = 2.97)
        assertEquals(CommandStage.Confirmed, h.session.receipt(zoom.operation)?.stage)
        assertEquals(ObservationOrigin.CAMERA_REPORTED, h.current.value(SettingKey.ZOOM).origin)
        assertEquals(CommandStage.Confirmed, h.session.submit(zoom).stage)
        assertEquals(1, h.sent.size)
        val focus = h.command(SettingValue.FocusMode(FocusMode.CONTINUOUS))
        assertEquals(CommandStage.AwaitingObservation, h.session.submit(focus).stage)
        assertEquals(3L, LunaPhotographySettings.parse(h.sent.last().body).afMode)
        h.report(types = listOf(93), focus = 3)
        assertEquals(CommandStage.Confirmed, h.session.receipt(focus.operation)?.stage)
    }

    @Test fun partialAndForeignBankReportsPreserveLensWhileMissingOrVendorValuesAreUnknown() = runTest {
        val h = LensHarness(backgroundScope)
        h.session.configureLens(1.0..4.0)
        h.report(zoom = 2.0, focus = 1)
        h.report(types = listOf(39))
        h.report(zoom = 3.0, focus = 3, bank = 1)
        assertEquals(SettingValue.Zoom(2.0), h.current.value(SettingKey.ZOOM).value)
        assertEquals(SettingValue.FocusMode(FocusMode.SINGLE), h.current.value(SettingKey.FOCUS_MODE).value)
        h.report(types = listOf(93), focus = 6)
        assertNull(h.current.value(SettingKey.FOCUS_MODE).value, "Product Showcase is not AF-C")
        for (invalid in listOf(0.0, -1.0, 16.0, Double.POSITIVE_INFINITY, Double.NaN)) {
            h.report(types = listOf(53), zoom = invalid)
            assertNull(h.current.value(SettingKey.ZOOM).value)
        }
        h.report(zoom = 2.0, focus = 3)
        h.report()
        assertNull(h.current.value(SettingKey.ZOOM).value)
        assertNull(h.current.value(SettingKey.FOCUS_MODE).value)
    }

    @Test fun lensAdmissionRejectsOutOfDomainAndStaleConfiguration() = runTest {
        val h = LensHarness(backgroundScope)
        h.session.configureLens(1.0..4.0)
        assertEquals(CommandStage.Rejected(CommandRejection.OutOfDomain), h.session.submit(h.command(SettingValue.Zoom(5.0))).stage)
        assertEquals(CommandStage.Rejected(CommandRejection.OutOfDomain), h.session.submit(h.command(SettingValue.FocusMode(FocusMode.MANUAL))).stage)
        val old = h.command(SettingValue.Zoom(3.0))
        h.session.configureLens(1.0..2.0)
        assertEquals(CommandStage.Rejected(CommandRejection.StaleCapabilities), h.session.submit(old).stage)
        h.session.configureLens(0.0..15.0)
        assertEquals(SupportStatus.UNKNOWN, h.current.capabilities.support(SettingKey.ZOOM))
        assertTrue(h.sent.isEmpty())
    }

    @Test fun newestLensTargetWinsAndClosedSessionIgnoresLateReports() = runTest {
        val h = LensHarness(backgroundScope)
        h.session.configureLens(1.0..4.0)
        val older = h.command(SettingValue.Zoom(2.0))
        h.session.submit(older)
        val newer = h.command(SettingValue.Zoom(3.0))
        h.session.submit(newer)
        assertEquals(CommandStage.Failed(CommandFailure.SUPERSEDED), h.session.receipt(older.operation)?.stage)
        h.report(types = listOf(53), zoom = 2.0)
        assertEquals(CommandStage.AwaitingObservation, h.session.receipt(newer.operation)?.stage)
        h.session.closeNow(SessionCloseReason.REPLACED)
        h.report(types = listOf(53), zoom = 3.0)
        assertEquals(CommandStage.OutcomeUnknown, h.session.receipt(newer.operation)?.stage)
        assertEquals(SettingValue.Zoom(2.0), h.current.value(SettingKey.ZOOM).value)
        assertEquals(CommandStage.Rejected(CommandRejection.SessionClosed), h.session.submit(h.command(SettingValue.Zoom(4.0))).stage)
        assertEquals(2, h.sent.size)
    }

    @Test fun lensDeadlineDistinguishesDisagreementFromNoObservation() = runTest {
        val h = LensHarness(backgroundScope)
        h.session.configureLens(1.0..4.0)
        val zoom = h.command(SettingValue.Zoom(3.0))
        val focus = h.command(SettingValue.FocusMode(FocusMode.CONTINUOUS))
        h.session.submit(zoom)
        h.session.submit(focus)
        h.clock += 5.seconds
        h.report(types = listOf(53), zoom = 2.0)
        assertEquals(CommandStage.Failed(CommandFailure.NOT_APPLIED), h.session.receipt(zoom.operation)?.stage)
        assertEquals(CommandStage.TimedOut, h.session.receipt(focus.operation)?.stage)
    }
}
