package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Swift suite `MonitorCapturePolicyTests`, same method names: the capture control keeps the
 * pre-shared-UI behavior of every app (behavior audit ZIA-359, II-034, II-144, PIA-425, ZAA-415,
 * ZAA-414, PAA-422, IA-024).
 */
class MonitorCapturePolicyTest {
    private fun policy(
        enabled: Boolean = true, busy: Boolean = false, pending: Boolean = false, photo: Boolean = false,
        canRecord: Boolean = true, recording: Boolean? = false, offersMode: Boolean = false,
    ) = MonitorCapturePolicy(enabled, busy, pending, photo, canRecord, recording, offersMode)

    private class Recorded : OperatorHaptics {
        val calls = mutableListOf<String>()
        override fun selection() { calls += "selection" }
        override fun tick() { calls += "tick" }
        override fun confirm() { calls += "confirm" }
        override fun longPress() { calls += "longPress" }
        override fun limit() { calls += "limit" }
        override fun lock() { calls += "lock" }
    }

    /** ZIA-359: a source with no mode sheet records on a hold, like a tap. */
    @Test fun aHoldRecordsWhenTheSourceOffersNoModeSheet() {
        assertEquals(MonitorCapturePolicy.Action.PRESS, policy().holdAction)
        assertEquals(MonitorCapturePolicy.Action.PRESS, policy(recording = true).holdAction)
        assertNull(policy(enabled = false).holdAction)
        assertEquals(MonitorCapturePolicy.Action.OPEN_MODE, policy(offersMode = true).holdAction)
    }

    /** II-034: the hold opens Shooting mode in every state but busy or locked. */
    @Test fun theModeHoldDoesNotWaitForTheRecordingState() {
        val unknown = policy(canRecord = false, recording = null, offersMode = true)
        assertNull(unknown.tapAction)
        assertEquals(MonitorCapturePolicy.Action.OPEN_MODE, unknown.holdAction)
        assertNull(policy(busy = true, offersMode = true).holdAction)
        assertNull(policy(pending = true, offersMode = true).holdAction)
        assertNull(policy(enabled = false, offersMode = true).holdAction)
    }

    /** II-144, PIA-425: busy and pending windows are inert without the locked look; stopping is 72 %. */
    @Test fun onlyTheLockedLookDimsToFortyPercent() {
        assertEquals(.4f, policy(enabled = false).alpha)
        assertEquals(1f, policy(busy = true).alpha)
        assertEquals(1f, policy(pending = true).alpha)
        assertEquals(1f, policy(busy = true, photo = true).alpha)
        assertEquals(.72f, policy(busy = true, recording = true).alpha)
        assertEquals(.72f, policy(pending = true, recording = true).alpha)
        assertEquals(1f, policy(recording = true).alpha)
        assertNull(policy(busy = true).tapAction)
        assertNull(policy(pending = true).tapAction)
    }

    /** ZAA-415: the record disc speaks its state beside the action. */
    @Test fun theRecordDiscSpeaksItsState() {
        assertEquals("Recording", policy(recording = true).stateDescription)
        assertEquals("Standby", policy(recording = false).stateDescription)
        assertNull(policy(recording = null).stateDescription)
        assertNull(policy(photo = true).stateDescription)
        assertEquals("Start recording", policy(recording = false).accessibilityLabel)
        assertEquals("Stop recording", policy(recording = true).accessibilityLabel)
        assertEquals("Take photo", policy(photo = true).accessibilityLabel)
    }

    /** Review: an unrelated busy command is not a stop; a hold that opens the sheet is named. */
    @Test fun onlyAPendingStopIsAnnouncedAndTheModeHoldIsNamed() {
        assertEquals("Stop recording", policy(busy = true, recording = true).accessibilityLabel)
        assertEquals("Stopping recording", policy(pending = true, recording = true).accessibilityLabel)
        assertEquals("Shooting mode", policy(offersMode = true).holdAccessibilityLabel)
        assertNull(policy().holdAccessibilityLabel)
    }

    @Test fun aTapPressesOnlyWhenAdmitted() {
        assertEquals(MonitorCapturePolicy.Action.PRESS, policy().tapAction)
        assertEquals(MonitorCapturePolicy.Action.PRESS, policy(photo = true, canRecord = false, recording = null).tapAction)
        assertNull(policy(canRecord = false, recording = null).tapAction)
        assertNull(policy(enabled = false).tapAction)
    }

    /** ZAA-414, PAA-422, IA-024: an admitted tap ticks before it acts; a refused one stays silent. */
    @Test fun anAdmittedPressGivesTheSelectionHaptic() {
        val haptics = Recorded()
        var presses = 0
        policy().tap(haptics) { presses++ }
        assertEquals(listOf("selection"), haptics.calls)
        assertEquals(1, presses)
        policy(enabled = false).tap(haptics) { presses++ }
        policy(busy = true).tap(haptics) { presses++ }
        assertEquals(listOf("selection"), haptics.calls)
        assertEquals(1, presses)
        var modes = 0
        policy(offersMode = true).hold(haptics, { presses++ }) { modes++ }
        assertEquals(listOf("selection", "longPress"), haptics.calls)
        assertEquals(1, modes)
        policy().hold(haptics, { presses++ }) { modes++ }
        assertEquals(listOf("selection", "longPress", "selection"), haptics.calls)
        assertEquals(2, presses)
    }
}
