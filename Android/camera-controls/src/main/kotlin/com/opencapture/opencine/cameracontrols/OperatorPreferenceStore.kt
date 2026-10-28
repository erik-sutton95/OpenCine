package com.opencapture.opencine.cameracontrols

import android.content.Context
import androidx.core.content.edit
import com.opencapture.monitorui.MonitorJoystickSize
import com.opencapture.opencine.appkit.MonitorClipShotColorPreferences
import com.opencapture.opencine.appkit.MonitorDisplayChrome
import com.opencapture.opencine.appkit.MonitorDisplayPreferences
import com.opencapture.opencine.appkit.MonitorMotionPreferences
import com.opencapture.opencine.appkit.MonitorOperatorPreferences
import com.opencapture.opencine.appkit.MonitorToolUsagePreferences
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.GamepadGimbalStick
import com.opencapture.opencine.vocabulary.LutCatalog
import com.opencapture.opencine.vocabulary.ShutterAngle

enum class PortraitFeedAspect(val raw: String) {
    FIT_16X9("fit16x9"),
    FILL("fill"),
    ;

    companion object {
        fun fromRaw(raw: String?): PortraitFeedAspect =
            entries.firstOrNull { it.raw == raw } ?: FIT_16X9
    }
}

/**
 * The operator's stored choices in one preferences file. The app names the file and the key prefix its
 * saved data already uses, so every stored value carries over unchanged.
 */
open class OperatorPreferenceStore @JvmOverloads constructor(
    file: String,
    private val keyPrefix: String,
    private val remoteShutterDefault: Boolean = true,
) {
    private val PREFS = file
    private val AWAKE = key("KeepScreenAwake")
    private val HDR_DISPLAY = key("HDRDisplay")
    private val AWAKE_LEGACY = "keep-screen-awake"
    private val RECORD_CONFIRM = key("RecordConfirmation")
    private val HAPTICS = key("HapticsEnabled")
    private val REMOTE_SHUTTER = key("RemoteShutter")
    private val DISP_LIVE = key("DispChrome.Live")
    private val DISP_CLEAN = key("DispChrome.Clean")
    private val CLEAN_PINS = key("CleanViewPins.v1")
    private val PORTRAIT_ASPECT = key("PortraitFeedAspect")
    private val NATIVE_ISO_HOP = key("NativeISOHop")
    private val FACE_PRIORITY = key("FacePriorityExposure")
    private val SHUTTER_ANGLE = key("ShutterUsesAngle")
    private val SHUTTER_DEGREES = key("ShutterAngleDegrees")
    private val GIMBAL_GAMEPAD_STICK = key("GimbalGamepadStick")
    private val LUT_SELECTION = key("LUTSelection")
    private val LAST_MONITOR_COLOR = key("LastMonitorColorMode")
    private val CLIP_SHOT_COLOR = key("ClipShotColor")
    private val CACHE_FULL_RESOLUTION = key("CacheFullResolution")
    private val ASSIST_V1 = key("Assist.v1")
    private val ASSIST_TOOL_USAGE = key("AssistToolUsage.v1")
    private val PLAYBACK_ASSISTS = key("PlaybackAssists.v1")

    val DEFAULT_GIMBAL_SENSITIVITY = 4
    val DEFAULT_CLEAN_PINS = setOf("LUT", "PEAK", "MIRROR", "DESQ")

    /** Only absent preferences receive defaults; an explicitly empty set stays empty. */
    fun resolvedCleanPins(raw: Set<String>?): Set<String> =
        raw ?: DEFAULT_CLEAN_PINS

    /** A stored key under the app's prefix (for the choices an app keeps itself). */
    protected fun key(name: String): String = keyPrefix + name

    protected fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun common(context: Context) = MonitorOperatorPreferences(
        storage = prefs(context),
        keys = MonitorOperatorPreferences.Keys(AWAKE, HDR_DISPLAY, RECORD_CONFIRM, HAPTICS,
            CACHE_FULL_RESOLUTION, AWAKE_LEGACY, REMOTE_SHUTTER),
        defaults = MonitorOperatorPreferences.Defaults(remoteShutter = remoteShutterDefault),
    )

    fun keepScreenAwake(context: Context): Boolean = common(context).keepScreenAwake
    fun setKeepScreenAwake(context: Context, value: Boolean) { common(context).keepScreenAwake = value }
    fun hdrDisplay(context: Context): Boolean = common(context).hdrDisplay
    fun setHdrDisplay(context: Context, value: Boolean) { common(context).hdrDisplay = value }
    fun recordConfirmationEnabled(context: Context): Boolean = common(context).recordConfirmation
    fun setRecordConfirmationEnabled(context: Context, value: Boolean) { common(context).recordConfirmation = value }
    fun hapticsEnabled(context: Context): Boolean = common(context).haptics
    fun setHapticsEnabled(context: Context, value: Boolean) { common(context).haptics = value }
    /** Volume and media presses toggle recording while the live view is in front (A2-32). */
    fun remoteShutterEnabled(context: Context): Boolean = common(context).remoteShutter
    fun setRemoteShutterEnabled(context: Context, value: Boolean) { common(context).remoteShutter = value }

    /** The shared motion owner over this file's existing keys, defaults and ranges. */
    fun motionPreferences(context: Context) = MonitorMotionPreferences(
        prefs(context), MonitorMotionPreferences.Keys.prefixed(keyPrefix),
        MonitorMotionPreferences.Defaults(
            gimbalStickSensitivity = DEFAULT_GIMBAL_SENSITIVITY,
            virtualJoystickDeadzonePercent = CameraCommands.GIMBAL_STICK_DEFAULT_DEADZONE_PERCENT,
            virtualJoystickResponseCurve = CameraCommands.VirtualJoystickCurve.parse(null).raw,
            virtualJoystickSize = MonitorJoystickSize.parse(null).raw,
            gimbalRamp = com.opencapture.opencine.vocabulary.GimbalRamp.OFF.raw,
            gimbalDoubleTap = com.opencapture.opencine.vocabulary.GimbalDoubleTap.RECENTER.raw,
        ),
        MonitorMotionPreferences.Limits(sensitivity = 1..5, deadzonePercent = 0..25),
    )

    fun gimbalStickSensitivity(context: Context): Int = motionPreferences(context).gimbalStickSensitivity

    fun setGimbalStickSensitivity(context: Context, value: Int) {
        motionPreferences(context).gimbalStickSensitivity = value
    }

    fun virtualJoystickInvertPan(context: Context): Boolean = motionPreferences(context).virtualJoystickInvertPan

    fun setVirtualJoystickInvertPan(context: Context, value: Boolean) {
        motionPreferences(context).virtualJoystickInvertPan = value
    }

    fun virtualJoystickInvertTilt(context: Context): Boolean = motionPreferences(context).virtualJoystickInvertTilt

    fun setVirtualJoystickInvertTilt(context: Context, value: Boolean) {
        motionPreferences(context).virtualJoystickInvertTilt = value
    }

    fun virtualJoystickDeadzonePercent(context: Context): Int =
        motionPreferences(context).virtualJoystickDeadzonePercent

    fun setVirtualJoystickDeadzonePercent(context: Context, value: Int) {
        motionPreferences(context).virtualJoystickDeadzonePercent = value
    }

    fun virtualJoystickResponseCurve(context: Context): CameraCommands.VirtualJoystickCurve =
        CameraCommands.VirtualJoystickCurve.parse(motionPreferences(context).virtualJoystickResponseCurve)

    fun setVirtualJoystickResponseCurve(
        context: Context,
        value: CameraCommands.VirtualJoystickCurve,
    ) {
        motionPreferences(context).virtualJoystickResponseCurve = value.raw
    }

    fun virtualJoystickSize(context: Context): MonitorJoystickSize =
        MonitorJoystickSize.parse(motionPreferences(context).virtualJoystickSize)

    fun setVirtualJoystickSize(context: Context, value: MonitorJoystickSize) {
        motionPreferences(context).virtualJoystickSize = value.raw
    }

    fun virtualJoystickMapping(context: Context): CameraCommands.VirtualJoystickMapping =
        CameraCommands.VirtualJoystickMapping(
            invertPan = virtualJoystickInvertPan(context),
            invertTilt = virtualJoystickInvertTilt(context),
            deadzone = CameraCommands.VirtualJoystickMapping.deadzoneFromPercent(
                virtualJoystickDeadzonePercent(context),
            ),
            curve = virtualJoystickResponseCurve(context),
        )

    fun gimbalRamp(context: Context): com.opencapture.opencine.vocabulary.GimbalRamp =
        com.opencapture.opencine.vocabulary.GimbalRamp.fromRaw(motionPreferences(context).gimbalRamp)

    fun setGimbalRamp(context: Context, value: com.opencapture.opencine.vocabulary.GimbalRamp) {
        motionPreferences(context).gimbalRamp = value.raw
    }

    /** Stick double-tap / gamepad Circle/B. Absent key is Recenter (iOS parity). */
    fun gimbalDoubleTap(context: Context): com.opencapture.opencine.vocabulary.GimbalDoubleTap =
        com.opencapture.opencine.vocabulary.GimbalDoubleTap.fromRaw(motionPreferences(context).gimbalDoubleTap)

    fun setGimbalDoubleTap(context: Context, value: com.opencapture.opencine.vocabulary.GimbalDoubleTap) {
        motionPreferences(context).gimbalDoubleTap = value.raw
    }

    fun displayPreferences(context: Context) = MonitorDisplayPreferences(
        prefs(context), MonitorDisplayPreferences.Keys(DISP_LIVE, DISP_CLEAN),
    )

    fun dispLive(context: Context): MonitorDisplayChrome = displayPreferences(context).live

    fun setDispLive(context: Context, value: MonitorDisplayChrome) {
        displayPreferences(context).live = value
    }

    fun dispClean(context: Context): MonitorDisplayChrome =
        displayPreferences(context).clean

    fun setDispClean(context: Context, value: MonitorDisplayChrome) {
        displayPreferences(context).clean = value
    }

    fun cleanViewPinnedTools(context: Context): Set<String> {
        val raw = prefs(context).getStringSet(CLEAN_PINS, null)
        return resolvedCleanPins(raw)
    }

    fun setCleanViewPinnedTools(context: Context, value: Set<String>) {
        prefs(context).edit { putStringSet(CLEAN_PINS, HashSet(resolvedCleanPins(value))) }
    }

    fun portraitFeedAspect(context: Context): PortraitFeedAspect =
        PortraitFeedAspect.fromRaw(prefs(context).getString(PORTRAIT_ASPECT, null))

    fun setPortraitFeedAspect(context: Context, value: PortraitFeedAspect) {
        prefs(context).edit { putString(PORTRAIT_ASPECT, value.raw) }
    }

    fun nativeISOHopEnabled(context: Context): Boolean =
        prefs(context).getBoolean(NATIVE_ISO_HOP, true)

    fun setNativeISOHopEnabled(context: Context, value: Boolean) {
        prefs(context).edit { putBoolean(NATIVE_ISO_HOP, value) }
    }

    fun facePriorityExposureEnabled(context: Context): Boolean =
        prefs(context).getBoolean(FACE_PRIORITY, false)

    fun setFacePriorityExposureEnabled(context: Context, value: Boolean) {
        prefs(context).edit { putBoolean(FACE_PRIORITY, value) }
    }

    fun gimbalGamepadStick(context: Context): GamepadGimbalStick =
        GamepadGimbalStick.parse(prefs(context).getString(GIMBAL_GAMEPAD_STICK, null))

    fun setGimbalGamepadStick(context: Context, value: GamepadGimbalStick) {
        prefs(context).edit { putString(GIMBAL_GAMEPAD_STICK, value.raw) }
    }

    fun shutterUsesAngle(context: Context): Boolean =
        prefs(context).getBoolean(SHUTTER_ANGLE, false)

    fun setShutterUsesAngle(context: Context, value: Boolean) {
        prefs(context).edit { putBoolean(SHUTTER_ANGLE, value) }
    }

    fun shutterAngleDegrees(context: Context): Double {
        val stored = prefs(context).getFloat(SHUTTER_DEGREES, 0f).toDouble()
        return if (stored > 0) ShutterAngle.nearestDegrees(stored) else ShutterAngle.DEFAULT_DEGREES
    }

    fun setShutterAngleDegrees(context: Context, value: Double) {
        val snapped = ShutterAngle.nearestDegrees(value)
        prefs(context).edit { putFloat(SHUTTER_DEGREES, snapped.toFloat()) }
    }

    fun lutSelection(context: Context): String {
        val stored = prefs(context).getString(LUT_SELECTION, LutCatalog.OFFICIAL_AUTO) ?: LutCatalog.OFFICIAL_AUTO
        return LutCatalog.migratedToOfficialCatalog(stored)
    }

    fun setLutSelection(context: Context, value: String) {
        prefs(context).edit { putString(LUT_SELECTION, value) }
    }

    fun lastMonitorColorMode(context: Context): Int =
        if (prefs(context).contains(LAST_MONITOR_COLOR)) {
            prefs(context).getInt(LAST_MONITOR_COLOR, -1)
        } else {
            -1
        }

    fun setLastMonitorColorMode(context: Context, value: Int) {
        if (value < 0) {
            prefs(context).edit { remove(LAST_MONITOR_COLOR) }
        } else {
            prefs(context).edit { putInt(LAST_MONITOR_COLOR, value) }
        }
    }

    private fun clipShotColors(context: Context) = MonitorClipShotColorPreferences(prefs(context), CLIP_SHOT_COLOR)

    fun clipShotColor(context: Context, path: String): Int = clipShotColors(context).color(path)

    fun setClipShotColor(context: Context, path: String, value: Int) { clipShotColors(context).setColor(path, value) }

    fun legacyClipShotColorJson(context: Context) = clipShotColors(context).legacyJson

    fun clearLegacyClipShotColor(context: Context) { clipShotColors(context).clear() }

    fun cacheFullResolution(context: Context): Boolean = common(context).cacheOriginals

    fun setCacheFullResolution(context: Context, value: Boolean) { common(context).cacheOriginals = value }

    fun assistEncoded(context: Context): String? =
        prefs(context).getString(ASSIST_V1, null)

    fun setAssistEncoded(context: Context, value: String) {
        prefs(context).edit { putString(ASSIST_V1, value) }
    }

    private fun toolUsage(context: Context) =
        MonitorToolUsagePreferences(prefs(context), ASSIST_TOOL_USAGE)

    /** Borrow the exact existing usage storage and deployed key. */
    fun assistToolUsagePreferences(context: Context): MonitorToolUsagePreferences = toolUsage(context)

    fun assistToolUsage(context: Context): com.opencapture.monitorui.MonitorToolUsageState =
        toolUsage(context).value

    fun setAssistToolUsage(context: Context, value: com.opencapture.monitorui.MonitorToolUsageState) {
        toolUsage(context).value = value
    }

    fun playbackVisibleAssistTools(context: Context): Set<String> =
        prefs(context).getStringSet(PLAYBACK_ASSISTS, null)?.toSet() ?: emptySet()

    fun setPlaybackVisibleAssistTools(context: Context, value: Set<String>) {
        prefs(context).edit { putStringSet(PLAYBACK_ASSISTS, value) }
    }
}
