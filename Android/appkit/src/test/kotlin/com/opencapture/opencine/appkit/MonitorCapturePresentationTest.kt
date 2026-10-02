package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.CommandStage
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
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** SIMULATED descriptor and confirmation scenarios; Swift mirrors the same names. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorCapturePresentationTest {
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

    @Test fun explicitTargetApprovalNeverInvertsWhenTheCameraStartsMeanwhile() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val approval = assertNotNull(control.recordEditor(MonitorControlModel.RecordConfirmationPolicy.EXPLICIT_TARGET))
        control.record(true); runCurrent()
        camera.advance(3.seconds); runCurrent()
        assertTrue(control.canCommitRecord(approval))
        assertTrue(control.commitRecord(approval)); runCurrent()
        assertFalse(control.state.value.recordPending)
        assertEquals(listOf("record-start"), camera.wire)
        val stop = assertNotNull(control.recordEditor(MonitorControlModel.RecordConfirmationPolicy.EXPLICIT_TARGET))
        camera.setAuthority(ControlAuthority.ReadOnly); runCurrent()
        assertFalse(control.canCommitRecord(stop))
        assertFalse(control.commitRecord(stop))
        assertEquals(listOf("record-start"), camera.wire)
    }

    @Test fun explicitApprovalRetiresWithUnknownModeAndReplacement() = runTest {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val approval = assertNotNull(control.recordEditor(MonitorControlModel.RecordConfirmationPolicy.EXPLICIT_TARGET))
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
