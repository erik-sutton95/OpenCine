package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeDevice
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.core.testing.lunaLike
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** SIMULATED descriptor and confirmation scenarios; Swift mirrors the same names. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorCapturePresentationTest {
    /** An unreported value with nothing to edit is inert; a report, an editor or a host action keeps it live. */
    @Test fun unreportedUneditableReadoutsAreInert() {
        val p = MonitorCapturePresentation
        assertTrue(p.readoutIsInert(reported = false, editable = false, quickEnabled = true, hasAction = false))
        assertTrue(p.readoutIsInert(reported = false, editable = true, quickEnabled = false, hasAction = false))
        assertTrue(p.readoutIsInert(reported = false, editable = null, quickEnabled = false, hasAction = false))
        assertFalse(p.readoutIsInert(reported = false, editable = true, quickEnabled = true, hasAction = false))
        assertFalse(p.readoutIsInert(reported = true, editable = false, quickEnabled = false, hasAction = false))
        assertFalse(p.readoutIsInert(reported = false, editable = false, quickEnabled = false, hasAction = true))
        assertFalse(p.readoutIsInert(reported = false, editable = null, quickEnabled = true, hasAction = false))
        val unreported = MonitorCaptureField(SettingKey.ISO, "ISO", null, emptyList(), null)
        assertTrue(p.readoutIsInert(null, unreported, null, quickEnabled = true, hasAction = false))
        val reported = MonitorCaptureField(SettingKey.ISO, "ISO", SettingValue.Iso(ISOValue.Auto), emptyList(), null)
        assertFalse(p.readoutIsInert("Auto", reported, null, quickEnabled = true, hasAction = false))
        assertTrue(p.readoutIsInert("--", null, nativeEnabled = false, quickEnabled = true, hasAction = false))
        assertFalse(p.readoutIsInert("1600", null, nativeEnabled = false, quickEnabled = true, hasAction = false))
    }

    /** A5-09: one frame-rate label for every integration; the NTSC family keeps its decimals. */
    @Test fun frameRateLabelsKeepTheExactRate() {
        val table = listOf(
            Rational(24000, 1001) to "23.98", Rational(24) to "24", Rational(25) to "25",
            Rational(30000, 1001) to "29.97", Rational(60000, 1001) to "59.94",
            Rational(120000, 1001) to "119.88", Rational(50) to "50",
        )
        for ((rate, label) in table) assertEquals(label, MonitorCapturePresentation.label(SettingValue.FrameRate(rate)), "$rate")
        assertEquals("FPS", MonitorCapturePresentation.title(SettingKey.FRAME_RATE))
    }

    @Test fun commonExposureAndFocusLabelsPreserveTypedDomainValues() {
        val values = listOf(
            SettingValue.ExposureCompensation(com.opencapture.opencine.core.Rational(-1, 3)),
            SettingValue.ExposureCompensation(com.opencapture.opencine.core.Rational(0, 1)),
            SettingValue.ExposureCompensation(com.opencapture.opencine.core.Rational(2, 3)),
            SettingValue.FocusMode(com.opencapture.opencine.core.FocusMode.SINGLE),
            SettingValue.FocusMode(com.opencapture.opencine.core.FocusMode.CONTINUOUS),
        )
        val domain = SettingDomain(choices = values)
        val exposure = MonitorCapturePresentation.choices(SettingKey.EXPOSURE_COMPENSATION, domain)
        assertEquals(values.take(3), exposure.map { it.value })
        assertEquals(listOf("−0.3", "0.0", "+0.7"), exposure.map { it.label })
        val focus = MonitorCapturePresentation.choices(SettingKey.FOCUS_MODE, domain)
        assertEquals(values.takeLast(2), focus.map { it.value })
        assertEquals(listOf("AF-S", "AF-C"), focus.map { it.label })
        assertEquals("EV", MonitorCapturePresentation.title(SettingKey.EXPOSURE_COMPENSATION))
        assertEquals("FOCUS", MonitorCapturePresentation.title(SettingKey.FOCUS_MODE))
    }

    @Test fun apertureUsesTheCommonCapturePresentation() {
        assertEquals("IRIS", MonitorCapturePresentation.title(SettingKey.APERTURE))
        assertEquals("f/2.8", MonitorCapturePresentation.label(SettingValue.Aperture(2.8)))
    }

    @Test fun absentReportDoesNotSelectTheFirstDrumDetent() = runTest {
        val camera = FakeCameraSession(FakeCameraSession.lunaLike().behavior,
            FakeDevice(0x01, emptyMap(), recording = null))
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val field = assertNotNull(control.captureField(SettingKey.ISO))
        assertNull(field.selection)
        assertNull(field.label)
        assertTrue(field.choices.isNotEmpty())
        assertNull(control.recordEditor())
        val hud = control.statusPresentation(0)
        assertNull(hud.recording)
        assertNull(hud.elapsedSeconds)
        assertNull(hud.timecode)
        assertEquals("Recording state unknown", hud.recordingAccessibilityLabel)
    }

    @Test fun typedDetentsCoalesceWithoutChangingTheReportedValue() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val field = assertNotNull(control.captureField(SettingKey.ISO))
        for (value in listOf(iso(400), iso(800))) {
            assertTrue(control.commit(field.choices.first { it.value == value }, field))
        }
        assertEquals("800", control.captureField(SettingKey.ISO)?.label)
        assertEquals(iso(200), camera.current.value(SettingKey.ISO).value)
        advanceTimeBy(120); runCurrent()
        assertEquals(listOf("set ${iso(800)}"), camera.wire)
    }

    @Test fun changedDomainRetiresTheOpenCaptureField() = runTest {
        val camera = FakeCameraSession.djiLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val field = assertNotNull(control.captureField(SettingKey.SHUTTER))
        camera.cameraSwitchesMode(0x02); runCurrent()
        assertFalse(control.commit(field.choices.last(), field))
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun domainChangeDuringCoalescingRetiresTheQueuedEdit() = runTest {
        val camera = FakeCameraSession.djiLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val field = assertNotNull(control.captureField(SettingKey.SHUTTER))
        assertTrue(control.commit(field.choices.last(), field))
        camera.cameraSwitchesMode(0x02); runCurrent()
        advanceTimeBy(120); runCurrent()
        assertTrue(control.state.value.pending.isEmpty())
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun readOnlyStillShowsTheReportButCannotCommit() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val field = assertNotNull(control.captureField(SettingKey.ISO))
        camera.setAuthority(ControlAuthority.ReadOnly); runCurrent()
        assertEquals("200", control.captureField(SettingKey.ISO)?.label)
        assertFalse(assertNotNull(control.captureField(SettingKey.ISO)).isEditable)
        assertFalse(control.commit(field.choices.last(), field))
        assertTrue(camera.wire.isEmpty())
    }

    /**
     * R-03: a recomposition reads the same drum, built once per domain. The base rebuilt every Kelvin
     * detent (up to a thousand, with a quadratic membership scan) on each read.
     */
    @Test fun aFieldsDrumIsBuiltOncePerDomain() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        runCurrent()
        val first = assertNotNull(control.captureField(SettingKey.WHITE_BALANCE)).choices
        assertEquals(40, first.size, "Auto plus 39 detents")
        assertSame(first, assertNotNull(control.captureField(SettingKey.WHITE_BALANCE)).choices)
    }

    /** R-03: a thousand-step Kelvin domain keeps the explicit choices first and adds each detent once. */
    @Test fun aThousandStepKelvinDomainKeepsOrderWithoutDuplicates() {
        val explicit = listOf(
            SettingValue.WhiteBalance(WhiteBalanceValue.Auto), SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600)),
            SettingValue.WhiteBalance(WhiteBalanceValue.Preset("Sunny")),
        )
        val values = MonitorCapturePresentation.choices(SettingKey.WHITE_BALANCE,
            SettingDomain(explicit, 1000.0..101_000.0, 100.0)).map { it.value }
        assertEquals(3 + 1000, values.size, "1001 detents, 5600 K already listed")
        assertEquals(values.size, values.toSet().size)
        assertEquals(explicit, values.take(3))
        assertEquals(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(1000)), values[3])
        assertEquals(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(101_000)), values.last())
    }

    /**
     * R-03: the cache keys on everything a drum is built from, the key and the advertised domain (its
     * listed values, range and step). A camera that re-advertises its list over the same range
     * rebuilds the drum, and the shown value is read fresh on every pass, never cached.
     */
    @Test fun aReadvertisedListRebuildsTheDrumAndTheShownValueStaysLive() = runTest {
        val luna = FakeCameraSession.lunaLike()
        val video = assertNotNull(luna.behavior.modes[0x01])
        val presets = video.copy(descriptors = video.descriptors.map {
            if (it.key != SettingKey.WHITE_BALANCE) it
            else SettingDescriptor(SettingKey.WHITE_BALANCE, domain = SettingDomain(
                listOf(SettingValue.WhiteBalance(WhiteBalanceValue.Auto), SettingValue.WhiteBalance(WhiteBalanceValue.Preset("Sunny"))),
                2700.0..6500.0, 100.0))
        })
        val camera = FakeCameraSession(luna.behavior.copy(modes = luna.behavior.modes + (0x02 to presets)), luna.device)
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        runCurrent()
        val field = assertNotNull(control.captureField(SettingKey.WHITE_BALANCE))
        assertEquals(40, field.choices.size)
        assertEquals("4000K", field.label)
        val kelvin = SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5600))
        assertTrue(control.commit(field.choices.first { it.value == kelvin }, field))
        val shown = assertNotNull(control.captureField(SettingKey.WHITE_BALANCE))
        assertEquals("5600K", shown.label)
        assertSame(field.choices, shown.choices)
        camera.cameraSwitchesMode(0x02); runCurrent()
        val readvertised = assertNotNull(control.captureField(SettingKey.WHITE_BALANCE)).choices
        assertEquals(41, readvertised.size)
        assertEquals(listOf("Auto", "Sunny"), readvertised.take(2).map { it.label })
    }

    @Test fun kelvinDetentsHonorAnExplicitCameraStepAndBoundAllocation() {
        val values = MonitorCapturePresentation.choices(SettingKey.WHITE_BALANCE,
            SettingDomain(listOf(SettingValue.WhiteBalance(WhiteBalanceValue.Auto)), 2000.0..2200.0, 50.0))
        assertEquals(listOf("Auto", "2000K", "2050K", "2100K", "2150K", "2200K"), values.map { it.label })
        assertTrue(MonitorCapturePresentation.choices(SettingKey.WHITE_BALANCE,
            SettingDomain(range = 0.0..1_000_000.0, step = 1.0)).isEmpty())
    }

    @Test fun recordAndWaitReturnsTheCameraReceiptAndPreservesExplicitRetries() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val operation = async { control.recordAndWait(true) }
        runCurrent()
        assertEquals(listOf("record-start"), camera.wire)
        assertTrue(control.state.value.recordPending)
        assertFalse(operation.isCompleted)
        camera.advance(3.seconds); runCurrent()
        assertEquals(CommandStage.Confirmed, operation.await()?.stage)
        assertFalse(control.state.value.recordPending)
        val retry = async { control.recordAndWait(true) }
        runCurrent()
        assertEquals(CommandStage.Confirmed, retry.await()?.stage)
        assertEquals(listOf("record-start"), camera.wire)
    }

    @Test fun recordAndWaitDropsTheRetiredCamerasReceipt() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val operation = async { control.recordAndWait(true) }
        runCurrent()
        control.unbind()
        camera.advance(3.seconds); runCurrent()
        assertNull(operation.await())
        assertNull(control.recordAndWait(true))
    }

    @Test fun recordingChangeRetiresTheApprovalWithoutSendingStop() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val approval = assertNotNull(control.recordEditor())
        control.record(true); runCurrent()
        camera.advance(3.seconds); runCurrent()
        assertFalse(control.commitRecord(approval))
        assertEquals(listOf("record-start"), camera.wire)
    }

    @Test fun approvalRetiresWithUnknownModeAndReplacement() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val approval = assertNotNull(control.recordEditor())
        camera.cameraSwitchesMode(0xff); runCurrent()
        assertFalse(control.canCommitRecord(approval))
        assertFalse(control.commitRecord(approval))
        control.bind(camera)
        assertFalse(control.commitRecord(approval))
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun recoveryEpochAndReplacementRetireTheApproval() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val approval = assertNotNull(control.recordEditor())
        val attempt = camera.loseLink(); runCurrent()
        assertNull(control.recordEditor())
        camera.completeAttempt(attempt); runCurrent()
        assertFalse(control.commitRecord(approval))
        val next = assertNotNull(control.recordEditor())
        control.bind(camera)
        assertFalse(control.commitRecord(next))
        assertTrue(camera.wire.isEmpty())
    }
}
