package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.AudioLevels
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.core.testing.FakeCameraBehavior
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeDevice
import com.opencapture.opencine.core.testing.FakeMode
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** SIMULATED common monitor contracts. Swift mirrors names and manual scenarios. */
@OptIn(ExperimentalCoroutinesApi::class)
class SharedMonitorControlContractTest {
    @Test fun absentLiveFactsRemainUnknownInsteadOfStandbyOrSilence() = runTest {
        val camera = camera(recording = null)
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val snapshot = assertNotNull(control.state.value.snapshot)
        val status = control.statusPresentation(17)
        assertNull(status.recording)
        assertNull(status.elapsedSeconds)
        assertNull(status.timecode)
        assertEquals("--", status.recordingLabel)
        assertEquals("Recording state unknown", status.recordingAccessibilityLabel)
        assertNull(snapshot.power.battery.value)
        assertNull(snapshot.storage.value)
        assertNull(snapshot.audioLevels.value)
        assertNull(control.recordEditor())
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun measuredEmptyMediaAndSilentAudioRemainKnown() = runTest {
        val silence = AudioLevels(AudioLevels.Channel(-120.0), AudioLevels.Channel(-120.0))
        val camera = camera(recording = false, batteryPercent = 0, freeBytes = 0, audioLevels = silence)
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val snapshot = assertNotNull(control.state.value.snapshot)
        assertEquals(false, control.statusPresentation().recording)
        assertEquals("STBY", control.statusPresentation().recordingLabel)
        assertEquals(0.0, snapshot.power.battery.value)
        assertEquals(0L, snapshot.storage.value?.first()?.freeBytes?.value)
        assertEquals(silence, snapshot.audioLevels.value)
        assertNull(snapshot.audioLevels.value?.left?.peak)
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun readOnlyDescriptorKeepsItsReportWithoutGrantingAWrite() = runTest {
        val camera = camera(access = SettingAccess.READ_ONLY)
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val field = assertNotNull(control.captureField(SettingKey.ISO))
        assertEquals("200", field.label)
        assertEquals(iso(200), field.selection)
        assertFalse(field.isEditable)
        assertNull(field.editor)
        assertFalse(control.commit(field.choices.first { it.value == iso(400) }, field))
        assertTrue(control.state.value.pending.isEmpty())
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun absentSettingDomainDoesNotInventEditableDetents() = runTest {
        val camera = camera(domain = null)
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val field = assertNotNull(control.captureField(SettingKey.ISO))
        assertEquals("200", field.label)
        assertTrue(field.choices.isEmpty())
        assertFalse(field.isEditable)
        assertFalse(control.commit(MonitorCaptureChoice(iso(400), "400"), field))
        assertTrue(control.state.value.pending.isEmpty())
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun recoveryWithIdenticalValuesRetiresTheCapturedField() = runTest {
        val camera = camera()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val before = assertNotNull(control.captureField(SettingKey.ISO))
        val attempt = camera.loseLink(); runCurrent()
        assertFalse(assertNotNull(control.captureField(SettingKey.ISO)).isEditable)
        camera.completeAttempt(attempt); runCurrent()
        val after = assertNotNull(control.captureField(SettingKey.ISO))
        assertEquals(before.selection, after.selection)
        assertEquals(before.choices, after.choices)
        assertNotEquals(before.editor, after.editor)
        val choice = before.choices.first { it.value == iso(400) }
        assertFalse(control.commit(choice, before))
        assertTrue(control.commit(choice, after))
        runCurrent(); advanceTimeBy(120); runCurrent()
        assertEquals(listOf("set ${choice.value}"), camera.wire)
    }

    /** Swift `aWriteRefusedBeforeSendingIsJournaled`: a refused write still reaches the journal. */
    @Test fun aWriteRefusedBeforeSendingIsJournaled() = runTest {
        val camera = camera()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        val journal = mutableListOf<Pair<String, CommandStage>>()
        control.onWriteFinished = { label, receipt -> journal += label to receipt.stage }
        control.bind(camera)
        assertNotNull(control.captureField(SettingKey.ISO))
        control.set(iso(1600), "ISO 1600")
        runCurrent(); advanceTimeBy(120); runCurrent()
        assertEquals(listOf("ISO 1600" to (CommandStage.Rejected(CommandRejection.OutOfDomain) as CommandStage)), journal)
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun replacementRetiresQueuedWorkWithoutBorrowingTheSuccessor() = runTest {
        val old = camera()
        val next = camera()
        old.cameraReportsStatus(); next.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(old)
        val oldField = assertNotNull(control.captureField(SettingKey.ISO))
        val oldChoice = oldField.choices.first { it.value == iso(400) }
        assertTrue(control.commit(oldChoice, oldField)); runCurrent()
        control.bind(next)
        val nextField = assertNotNull(control.captureField(SettingKey.ISO))
        assertEquals(oldField.selection, nextField.selection)
        assertEquals(oldField.choices, nextField.choices)
        assertFalse(control.commit(oldChoice, oldField))
        val nextChoice = nextField.choices.first { it.value == iso(800) }
        assertTrue(control.commit(nextChoice, nextField))
        runCurrent(); advanceTimeBy(120); runCurrent()
        assertEquals(listOf("set ${nextChoice.value}"), next.wire)
        old.cameraReportsStatus(); runCurrent()
        assertEquals(next.id, control.state.value.snapshot?.session)
        assertTrue(old.wire.isEmpty())
    }

    private fun iso(value: Int): SettingValue = SettingValue.Iso(ISOValue.Manual(value))

    private fun camera(access: SettingAccess = SettingAccess.READ_WRITE,
        domain: SettingDomain? = SettingDomain(choices = listOf(iso(200), iso(400), iso(800))),
        recording: Boolean? = false, batteryPercent: Int? = null, freeBytes: Long? = null,
        audioLevels: AudioLevels? = null): FakeCameraSession {
        val mode = FakeMode(CaptureMode(CaptureMode.Role.VIDEO, "contract.video", "SIMULATED"),
            listOf(SettingDescriptor(SettingKey.ISO, access = access, domain = domain)), emptySet(),
            timecodeCapability = TimecodeCapability.supported(TimecodePrecision.Seconds), audioLevels = SupportStatus.SUPPORTED)
        return FakeCameraSession(FakeCameraBehavior(IntegrationID("contract"), 3.seconds,
            5.seconds, FakeCameraBehavior.RecordWire.EXPLICIT, modes = mapOf(1 to mode)),
            FakeDevice(1, mapOf(SettingKey.ISO to iso(200)), recording = recording,
                batteryPercent = batteryPercent, freeBytes = freeBytes, audioLevels = audioLevels))
    }
}
