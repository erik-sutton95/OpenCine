package com.opencapture.opencine.cameracontrols

import android.annotation.SuppressLint
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import com.opencapture.opencine.vocabulary.CamFov
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.GamepadDpad
import com.opencapture.opencine.vocabulary.GamepadFaceButton
import com.opencapture.opencine.vocabulary.GamepadGimbalStick
import com.opencapture.opencine.vocabulary.GamepadOperatorAction
import com.opencapture.opencine.vocabulary.GamepadOperatorMap
import com.opencapture.opencine.vocabulary.GamepadShoulder
import com.opencapture.opencine.vocabulary.GimbalLimitContact
import kotlin.math.abs
import kotlin.math.max

/** Live-monitor gamepad: discussion #159 map. Selected stick gimbal, L2/R2 analog zoom. */
object GimbalGamepad {
    fun isJoystickMotion(event: MotionEvent): Boolean {
        val source = event.source
        return source and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK ||
            source and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD
    }

    fun isExtendedPad(device: InputDevice?): Boolean {
        if (device == null || device.isVirtual) return false
        val sources = device.sources
        return sources and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
            sources and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK
    }

    fun anyExtendedPadConnected(): Boolean =
        InputDevice.getDeviceIds().any { isExtendedPad(InputDevice.getDevice(it)) }

    fun analogLeftFrom(event: MotionEvent): Pair<Float, Float> {
        val x = event.getAxisValue(MotionEvent.AXIS_X)
        val y = -event.getAxisValue(MotionEvent.AXIS_Y)
        return x to y
    }

    fun analogRightFrom(event: MotionEvent): Pair<Float, Float> {
        val x = event.getAxisValue(MotionEvent.AXIS_Z)
        val y = -event.getAxisValue(MotionEvent.AXIS_RZ)
        return x to y
    }

    fun analogFrom(event: MotionEvent, stick: GamepadGimbalStick = GamepadGimbalStick.DEFAULT): Pair<Float, Float> {
        val left = analogLeftFrom(event)
        val right = analogRightFrom(event)
        return stick.axes(left.first, left.second, right.first, right.second)
    }

    /** Left trigger, right trigger in 0…1. DualSense L2/R2. */
    fun triggersFrom(event: MotionEvent): Pair<Float, Float> {
        val left =
            max(
                event.getAxisValue(MotionEvent.AXIS_LTRIGGER),
                event.getAxisValue(MotionEvent.AXIS_BRAKE),
            )
        val right =
            max(
                event.getAxisValue(MotionEvent.AXIS_RTRIGGER),
                event.getAxisValue(MotionEvent.AXIS_GAS),
            )
        return left.coerceIn(0f, 1f) to right.coerceIn(0f, 1f)
    }

    fun zoomAxisFrom(event: MotionEvent): Float {
        val (left, right) = triggersFrom(event)
        return CamFov.triggerZoomAxis(left.toDouble(), right.toDouble()).toFloat()
    }

    fun isRest(x: Float, y: Float): Boolean =
        CameraCommands.gimbalAnalogCurve(x) == 0f && CameraCommands.gimbalAnalogCurve(y) == 0f

    fun isZoomRest(y: Float): Boolean = CameraCommands.gimbalLinearThrow(y) == 0f

    fun faceButton(keyCode: Int): GamepadFaceButton? =
        when (keyCode) {
            KeyEvent.KEYCODE_BUTTON_A -> GamepadFaceButton.A
            KeyEvent.KEYCODE_BUTTON_B -> GamepadFaceButton.B
            KeyEvent.KEYCODE_BUTTON_X -> GamepadFaceButton.X
            KeyEvent.KEYCODE_BUTTON_Y -> GamepadFaceButton.Y
            else -> null
        }

    fun shoulder(keyCode: Int): GamepadShoulder? =
        when (keyCode) {
            KeyEvent.KEYCODE_BUTTON_L1 -> GamepadShoulder.LEFT
            KeyEvent.KEYCODE_BUTTON_R1 -> GamepadShoulder.RIGHT
            else -> null
        }

    fun dpad(keyCode: Int): GamepadDpad? =
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> GamepadDpad.UP
            KeyEvent.KEYCODE_DPAD_DOWN -> GamepadDpad.DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> GamepadDpad.LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> GamepadDpad.RIGHT
            else -> null
        }

    fun actionForKey(keyCode: Int): GamepadOperatorAction? {
        faceButton(keyCode)?.let { return GamepadOperatorMap.face(it) }
        shoulder(keyCode)?.let { return GamepadOperatorMap.shoulder(it) }
        dpad(keyCode)?.let { return GamepadOperatorMap.dpad(it) }
        return null
    }

    /** AXIS_HAT: −X left, +X right, −Y up, +Y down. Neutral inside 0.5. */
    fun hatDpad(x: Float, y: Float): GamepadDpad? {
        val ax = if (abs(x) > 0.5f) x else 0f
        val ay = if (abs(y) > 0.5f) y else 0f
        if (ax == 0f && ay == 0f) return null
        return if (abs(ax) >= abs(ay)) {
            if (ax < 0f) GamepadDpad.LEFT else GamepadDpad.RIGHT
        } else {
            if (ay < 0f) GamepadDpad.UP else GamepadDpad.DOWN
        }
    }

    /** Pad motor from [InputDevice], not the phone vibrator. */
    @SuppressLint("MissingPermission")
    fun rumble(device: InputDevice?, contact: GimbalLimitContact) {
        if (contact.isEmpty) return
        val vibrator = vibrator(device) ?: return
        if (!vibrator.hasVibrator()) return
        val duration = 40L
        val amplitude = 200
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(duration, amplitude))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(duration)
        }
    }

    private fun vibrator(device: InputDevice?): Vibrator? {
        if (device == null) return null
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            device.vibratorManager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            device.vibrator
        }
    }
}
