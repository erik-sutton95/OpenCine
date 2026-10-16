package com.opencapture.opencine.appkit

import android.view.KeyEvent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A2-32: the Android remote shutter moved from OpenZCine (Swift twin: MonitorRemoteShutterPolicyTests). */
class MonitorRemoteShutterTest {
    private var nowMillis: Long = 1_000L
    private val received = mutableListOf<MonitorRemoteShutterCommand>()
    private val controller = MonitorRemoteShutterController { nowMillis }

    @Test
    fun `only armed allowlisted hardware keys emit one command`() {
        assertFalse(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))

        controller.arm(received::add)

        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        assertEquals(listOf(MonitorRemoteShutterCommand.TOGGLE), received)
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.ACTION_UP))
        assertEquals(listOf(MonitorRemoteShutterCommand.TOGGLE), received)
        assertFalse(key(KeyEvent.KEYCODE_CAMERA))

        nowMillis += 600
        assertTrue(key(KeyEvent.KEYCODE_VOLUME_UP))
        assertEquals(
            listOf(MonitorRemoteShutterCommand.TOGGLE, MonitorRemoteShutterCommand.TOGGLE),
            received,
        )
    }

    @Test
    fun `repeats and duplicate delivery are debounced while their key events remain consumed`() {
        controller.arm(received::add)

        assertTrue(key(KeyEvent.KEYCODE_HEADSETHOOK))
        assertTrue(key(KeyEvent.KEYCODE_HEADSETHOOK, repeatCount = 1))
        nowMillis += 100
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        assertEquals(listOf(MonitorRemoteShutterCommand.TOGGLE), received)

        nowMillis += 500
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        assertEquals(
            listOf(MonitorRemoteShutterCommand.TOGGLE, MonitorRemoteShutterCommand.TOGGLE),
            received,
        )
    }

    @Test
    fun `disarming releases normal media-key handling and a later arm can receive a fresh command`() {
        controller.arm(received::add)
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_PLAY))
        controller.disarm()

        assertFalse(controller.isArmed)
        assertFalse(key(KeyEvent.KEYCODE_MEDIA_PLAY))
        assertEquals(listOf(MonitorRemoteShutterCommand.START), received)

        controller.arm(received::add)
        assertTrue(key(KeyEvent.KEYCODE_MEDIA_STOP))
        assertEquals(
            listOf(MonitorRemoteShutterCommand.START, MonitorRemoteShutterCommand.STOP),
            received,
        )
    }

    @Test
    fun `key map supports documented media and volume shutter actions`() {
        assertEquals(
            MonitorRemoteShutterCommand.TOGGLE,
            MonitorRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_HEADSETHOOK),
        )
        assertEquals(
            MonitorRemoteShutterCommand.START,
            MonitorRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_MEDIA_RECORD),
        )
        assertEquals(
            MonitorRemoteShutterCommand.STOP,
            MonitorRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_MEDIA_PAUSE),
        )
        assertEquals(
            MonitorRemoteShutterCommand.TOGGLE,
            MonitorRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_VOLUME_DOWN),
        )
        assertEquals(
            MonitorRemoteShutterCommand.TOGGLE,
            MonitorRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_VOLUME_UP),
        )
        assertNull(MonitorRemoteShutterKeyMap.commandFor(KeyEvent.KEYCODE_CAMERA))
    }

    @Test
    fun `arm decision rejects every non-ready monitor state`() {
        assertTrue(armDecision())
        assertFalse(armDecision(enabled = false))
        assertFalse(armDecision(monitorIsFront = false))
        assertFalse(armDecision(cameraConnected = false))
        assertFalse(armDecision(recordCommandPending = true))
        assertFalse(armDecision(applicationResumed = false))
        assertFalse(armDecision(recordConfirmationPending = true))
        assertFalse(armDecision(cameraControlPending = true))
    }

    @Test
    fun `each command asks for one recording state or none`() {
        assertEquals(true, monitorRemoteShutterRecordingTarget(MonitorRemoteShutterCommand.TOGGLE, isRecording = false))
        assertEquals(false, monitorRemoteShutterRecordingTarget(MonitorRemoteShutterCommand.TOGGLE, isRecording = true))
        assertEquals(true, monitorRemoteShutterRecordingTarget(MonitorRemoteShutterCommand.START, isRecording = false))
        assertNull(monitorRemoteShutterRecordingTarget(MonitorRemoteShutterCommand.START, isRecording = true))
        assertEquals(false, monitorRemoteShutterRecordingTarget(MonitorRemoteShutterCommand.STOP, isRecording = true))
        assertNull(monitorRemoteShutterRecordingTarget(MonitorRemoteShutterCommand.STOP, isRecording = false))
    }

    private fun key(
        keyCode: Int,
        action: Int = KeyEvent.ACTION_DOWN,
        repeatCount: Int = 0,
    ): Boolean =
        controller.handleKeyEvent(
            keyCode = keyCode,
            action = action,
            repeatCount = repeatCount,
        )

    private fun armDecision(
        enabled: Boolean = true,
        monitorIsFront: Boolean = true,
        cameraConnected: Boolean = true,
        recordCommandPending: Boolean = false,
        applicationResumed: Boolean = true,
        recordConfirmationPending: Boolean = false,
        cameraControlPending: Boolean = false,
    ): Boolean =
        monitorRemoteShutterShouldArm(
            enabled = enabled,
            monitorIsFront = monitorIsFront,
            cameraConnected = cameraConnected,
            recordCommandPending = recordCommandPending,
            applicationResumed = applicationResumed,
            recordConfirmationPending = recordConfirmationPending,
            cameraControlPending = cameraControlPending,
        )
}
