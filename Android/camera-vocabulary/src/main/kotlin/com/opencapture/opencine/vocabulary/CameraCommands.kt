package com.opencapture.opencine.vocabulary

import kotlin.math.hypot
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Documented Pocket 4 payloads only (`docs/protocol-notes.md`).
 * No invented `0xE1` values. No 1 Hz `0x09/0xa8`.
 */
object CameraCommands {
    const val RES_1080 = 0x0A
    const val RES_4K = 0x10

    const val COLOR_NORMAL = 0x3F
    const val COLOR_HDR = 0x3C
    const val COLOR_DLOG = 0x17
    const val COLOR_DLOG2 = 0x41
    /** Semantic Normal 10-bit. Nano SET is `3F`; Pocket 3 D-Log M wire is `3D`. */
    const val COLOR_NORMAL10 = 0x3D
    /** Semantic D-Log M. Nano and Pocket 3 SET is `3D`. */
    const val COLOR_DLOG_M = 0x00
    /** I-Log (Insta360's log curve). The monitor's I-Log id (`MonitorTransfer.ILOG_BRIDGE_ID`), never a camera byte. */
    const val COLOR_ILOG = 65_536
    /** Dolby Vision. Stored as `0xE5`; no DJI body reports it, so the DJI decode tables leave it out. */
    const val COLOR_DOLBY_VISION = 0xE5

    const val EXPO_AUTO = 0x01
    const val EXPO_MANUAL = 0x04

    const val FOCUS_SINGLE = 0x01
    const val FOCUS_CONTINUOUS = 0x02

    const val WB_AUTO = 0x00
    const val WB_CUSTOM = 0x06

    const val AUDIO_MONO = 0x01
    const val AUDIO_STEREO = 0x02
    const val AUDIO_SPATIAL = 0x03

    const val WIND_ON = 0x1A
    const val WIND_OFF = 0x18
    const val DIR_ALL = 0xDA
    const val DIR_FRONT = 0x3A
    const val DIR_FRONT_BACK = 0xBA

    /** iOS `CameraSession.setWhiteBalanceCustom` clamp. */
    fun clampWhiteBalanceCustom(kelvin: Int, tint: Int): Pair<Int, Int> =
        kelvin.coerceIn(2_000, 10_000) to tint.coerceIn(-100, 100)

    /**
     * D-Log2 cannot zoom. Any step off 1× hops the body to D-Log.
     * ISO star still follows `status.colorMode` after the body reports; this
     * guess must not flip the wheel marker while `@2` is still D-Log2.
     */
    fun colorModeForZoom(factor: Double, current: Int): Int? =
        CamFov.colorModeForZoom(factor, current)

    /** iOS `CamFov.shouldRestoreDLog2`; only park back at 1×, not 2.9×. */
    fun shouldRestoreDLog2(factor: Double): Boolean = CamFov.shouldRestoreDLog2(factor)

    fun audioChannelLabel(value: Int): String? =
        when (value) {
            AUDIO_MONO -> "Mono"
            AUDIO_STEREO -> "Stereo"
            AUDIO_SPATIAL -> "Spatial"
            else -> null
        }

    fun audioDirLabel(mode: Int): String? =
        when (mode) {
            0 -> "All"
            1 -> "Front"
            2 -> "Front+back"
            else -> null
        }

    const val ZOOM_LENS_1X = 217
    const val ZOOM_LENS_3X = 651
    const val ZOOM_LENS_6X = 1302
    const val ZOOM_LENS_12X = 2604
    const val ZOOM_SLEW_TELE = 100
    const val ZOOM_SLEW_WIDE = 300

    const val SHOOT_SLOWMO = 0x00
    const val SHOOT_VIDEO = 0x01
    const val SHOOT_TIMELAPSE = 0x02
    const val SHOOT_PHOTO = 0x05
    const val SHOOT_HYPERLAPSE = 0x0A
    const val SHOOT_PHOTO_POCKET4 = 0x17
    const val SHOOT_SUPER_NIGHT = 0x28
    /** Pocket 4 Pro Live Photo, physically observed in Mimo. */
    const val SHOOT_LIVE_PHOTO = 0x4D

    /** Still capture: Photo `0x05` / Pocket 4 `0x17` / Live Photo `0x4D`. SuperNight `0x28` is video. */
    fun isPhotoMode(shootingMode: Int): Boolean =
        shootingMode == SHOOT_PHOTO ||
            shootingMode == SHOOT_PHOTO_POCKET4 ||
            shootingMode == SHOOT_LIVE_PHOTO

    /**
     * Label for a tabled `0x02/0xE1` value, or null when the camera reports one we do not know.
     * Both photo encodings read back as "Photo"; the body decides which it uses.
     * Pocket 3 presents `0x28` as Low-Light video; other bodies keep SuperNight.
     */
    /** [profile] carries the session's own names (for example TimeShift or PureVideo). */
    fun shootingModeLabel(
        raw: Int,
        cameraName: String? = null,
        profile: CameraLabelProfile = CameraLabelProfile.standard,
    ): String? =
        profile.shootingModeLabels[raw] ?: when (raw) {
            SHOOT_SLOWMO -> "SlowMo"
            SHOOT_VIDEO -> "Video"
            SHOOT_TIMELAPSE -> "TimeLapse"
            SHOOT_PHOTO, SHOOT_PHOTO_POCKET4 -> "Photo"
            SHOOT_LIVE_PHOTO -> "Live Photo"
            SHOOT_HYPERLAPSE -> "HyperLapse"
            SHOOT_SUPER_NIGHT -> "SuperNight"
            else -> null
        }

    fun shootingModeCarousel(profile: CameraLabelProfile = CameraLabelProfile.standard): List<Int> =
        profile.shootingModes ?: listOf(SHOOT_VIDEO, SHOOT_PHOTO, SHOOT_TIMELAPSE,
            SHOOT_HYPERLAPSE, SHOOT_SUPER_NIGHT, SHOOT_SLOWMO)

    const val GIMBAL_STICK_CENTER = 1024
    const val GIMBAL_STICK_TRAVEL = 550
    const val GIMBAL_STICK_MIN = 474
    const val GIMBAL_STICK_MAX = 1574
    const val GIMBAL_STICK_DEADZONE = 0.08f
    const val GIMBAL_STICK_ANALOG_EXPO = 2.0
    const val GIMBAL_STICK_DEFAULT_DEADZONE_PERCENT = 8

    const val GIMBAL_STICK_DEFAULT_SENSITIVITY = 4

    enum class VirtualJoystickCurve(val raw: String, val expo: Double, val label: String) {
        LINEAR("linear", 1.0, "Linear"),
        STANDARD("standard", GIMBAL_STICK_ANALOG_EXPO, "Standard"),
        FINE("fine", 3.0, "Fine"),
        ;

        companion object {
            fun parse(raw: String?): VirtualJoystickCurve =
                entries.firstOrNull { it.raw.equals(raw, ignoreCase = true) } ?: STANDARD

            fun fromLabel(label: String): VirtualJoystickCurve =
                entries.firstOrNull { it.label == label } ?: STANDARD
        }
    }

    data class VirtualJoystickMapping(
        val invertPan: Boolean = false,
        val invertTilt: Boolean = false,
        val deadzone: Float = GIMBAL_STICK_DEADZONE,
        val curve: VirtualJoystickCurve = VirtualJoystickCurve.STANDARD,
    ) {
        val isDefault: Boolean
            get() = this == DEFAULT

        companion object {
            val DEFAULT = VirtualJoystickMapping()

            fun clampedDeadzone(value: Float): Float =
                if (value.isFinite()) value.coerceIn(0f, 0.25f) else GIMBAL_STICK_DEADZONE

            fun clampedDeadzonePercent(value: Int): Int = value.coerceIn(0, 25)

            fun deadzoneFromPercent(percent: Int): Float {
                val p = clampedDeadzonePercent(percent)
                return if (p == GIMBAL_STICK_DEFAULT_DEADZONE_PERCENT) GIMBAL_STICK_DEADZONE
                else p / 100f
            }

            fun resolvedDeadzonePercent(stored: Int?): Int =
                if (stored == null) GIMBAL_STICK_DEFAULT_DEADZONE_PERCENT
                else clampedDeadzonePercent(stored)
        }
    }
    const val GIMBAL_STICK_TAP_SLOP = 0.18f
    /** Full command throw as a multiple of the visible outer radius (`stickSize / 2`). */
    const val GIMBAL_STICK_TOUCH_COMMAND_RADIUS_FACTOR = 1.35f

    data class GimbalStickTouchMapping(
        val visualX: Float,
        val visualY: Float,
        val commandX: Float,
        val commandY: Float,
        val isTap: Boolean,
        val engaged: Boolean,
        val emit: Boolean,
    )

    fun mapGimbalStickTouch(
        dx: Float,
        dy: Float,
        stickSize: Float,
        knobSize: Float,
        engaged: Boolean,
    ): GimbalStickTouchMapping {
        val size = if (stickSize.isFinite()) maxOf(stickSize, 0f) else 0f
        val knob = if (knobSize.isFinite()) maxOf(knobSize, 0f) else 0f
        val rawX = if (dx.isFinite()) dx else 0f
        val rawY = if (dy.isFinite()) dy else 0f
        val travel = maxOf((size - knob) / 2f, 0f)
        val commandRadius = GIMBAL_STICK_TOUCH_COMMAND_RADIUS_FACTOR * (size / 2f)
        val (visualX, visualY) = radialClamp(rawX, rawY, travel)
        val visualMag = hypot(visualX, visualY)
        val visualNorm = if (travel > 0f) visualMag / travel else 0f
        val isTap = visualNorm <= GIMBAL_STICK_TAP_SLOP
        val nowEngaged = engaged || !isTap
        val (cmdX, cmdY) = radialClamp(rawX, rawY, commandRadius)
        val commandX = if (commandRadius > 0f) cmdX / commandRadius else 0f
        val commandY = if (commandRadius > 0f) -cmdY / commandRadius else 0f
        return GimbalStickTouchMapping(
            visualX = visualX,
            visualY = visualY,
            commandX = commandX,
            commandY = commandY,
            isTap = isTap,
            engaged = nowEngaged,
            emit = nowEngaged,
        )
    }

    private fun radialClamp(x: Float, y: Float, radius: Float): Pair<Float, Float> {
        val mag = hypot(x, y)
        if (radius <= 0f || mag <= radius) return x to y
        val scale = radius / mag
        return x * scale to y * scale
    }

    /** iOS `GimbalStick.streamInterval`; ACK pump emits while held. */
    const val GIMBAL_STICK_STREAM_INTERVAL_MS = 40L
    /** Stick throw can pause HEVC the same way zoom/AF-C do. */
    const val GIMBAL_STICK_VIDEO_GRACE_SEC = 3.0
    const val STALL_SEC = 2.0

    fun shouldEmitGimbalStick(
        held: Boolean,
        restPending: Boolean,
        nowMs: Long,
        lastEmittedMs: Long,
    ): Boolean {
        if (restPending) return true
        if (!held) return false
        if (lastEmittedMs == 0L) return true
        return nowMs - lastEmittedMs >= GIMBAL_STICK_STREAM_INTERVAL_MS
    }

    /** iOS `GimbalStick.shouldEmitOnSocket`. Rest still leaves while ingest is down. */
    fun shouldEmitGimbalStickOnSocket(
        rest: Boolean,
        liveAccepting: Boolean,
        hasConnection: Boolean,
    ): Boolean {
        if (!hasConnection) return false
        if (rest) return true
        return liveAccepting
    }

    /** Core `FeedWatchdog.cameraSetGrace`: any tracked SET can pause HEVC. */
    const val CAMERA_SET_VIDEO_GRACE_SEC = 4.0

    /** Core `FeedWatchdog.shouldHoldForCameraSet`. Same shape as the gimbal hold. */
    fun shouldHoldCameraSetWatchdog(
        secondsSinceSet: Double?,
        lastVideoPacketAgeSec: Double? = null,
    ): Boolean {
        val s = secondsSinceSet ?: return false
        if (s < 0.0 || s >= CAMERA_SET_VIDEO_GRACE_SEC) return false
        if (lastVideoPacketAgeSec != null &&
            lastVideoPacketAgeSec >= STALL_SEC + CAMERA_SET_VIDEO_GRACE_SEC
        ) {
            return false
        }
        return true
    }

    fun shouldHoldGimbalWatchdog(
        secondsSinceThrow: Double?,
        lastVideoPacketAgeSec: Double? = null,
        stickHeld: Boolean = false,
    ): Boolean {
        if (stickHeld) return true
        val s = secondsSinceThrow ?: return false
        if (s < 0.0 || s >= GIMBAL_STICK_VIDEO_GRACE_SEC) return false
        if (lastVideoPacketAgeSec != null &&
            lastVideoPacketAgeSec >= STALL_SEC + GIMBAL_STICK_VIDEO_GRACE_SEC
        ) {
            return false
        }
        return true
    }

    const val GIMBAL_FACE_UNKNOWN = -1
    const val GIMBAL_FACE_FRONT = 0
    const val GIMBAL_FACE_SELFIE = 1

    /** View-space X flip: TT180 extra-mirror XOR MIRROR assist. */
    fun liveViewFlip(poseViewFlip: Boolean, assistMirror: Boolean): Boolean =
        poseViewFlip != assistMirror

    /** Stick invert follows the visible picture (TT180 XOR MIRROR). */
    fun liveInvertPan(poseInvert: Boolean, assistMirror: Boolean): Boolean =
        poseInvert != assistMirror

    /** `0x04/0x05` i16-LE @4 in 0.1°. |angle| > 90° is the selfie-facing pose. */
    const val ROTATED_180_TENTH_DEG = 900
    /** Invert latch like Mimo: end of the 180, not the midpoint. */
    const val SETTLE_180_TENTH_DEG = 1650
    const val SETTLE_FRONT_TENTH_DEG = 150
    const val POSE_SEED_FRONT_VOTES = 3

    fun rotationSettled(yawTenthDeg: Int, want180: Boolean): Boolean {
        val angle = kotlin.math.abs(yawTenthDeg)
        return if (want180) angle >= SETTLE_180_TENTH_DEG else angle <= SETTLE_FRONT_TENTH_DEG
    }

    /** Pocket `FE 09` destination: front half (`|yaw| ≤ 90°`) goes to ±180°. */
    fun fe09GoesTo180(yawTenthDeg: Int?): Boolean {
        val yaw = yawTenthDeg ?: return true
        return kotlin.math.abs(yaw) <= ROTATED_180_TENTH_DEG
    }

    /** 4 = 1.0 (captured ±550 throw). 5 saturates earlier; 1–3 never reach full throw. */
    fun gimbalSensitivityGain(sensitivity: Int): Float =
        sensitivity.coerceIn(1, 5) / GIMBAL_STICK_DEFAULT_SENSITIVITY.toFloat()

    /** Deadzone, then linear remainder onto −1…1. Zoom stick uses this (no expo). */
    fun gimbalLinearThrow(
        normalized: Float,
        deadzone: Float = GIMBAL_STICK_DEADZONE,
    ): Float {
        val n = normalized.coerceIn(-1f, 1f)
        val magnitude = kotlin.math.abs(n)
        val rest = VirtualJoystickMapping.clampedDeadzone(deadzone)
        if (magnitude < rest) return 0f
        val span = 1f - rest
        if (span <= 0f) return 0f
        val t = (magnitude - rest) / span
        return if (n < 0f) -t else t
    }

    /** Deadzone, then expo ease-in onto −1…1. Full throw stays 1. Rest stays 0. */
    fun gimbalAnalogCurve(
        normalized: Float,
        deadzone: Float = GIMBAL_STICK_DEADZONE,
        expo: Double = GIMBAL_STICK_ANALOG_EXPO,
    ): Float {
        val t = gimbalLinearThrow(normalized, deadzone)
        if (t == 0f) return 0f
        val power = if (expo.isFinite() && expo > 0.0) expo else GIMBAL_STICK_ANALOG_EXPO
        val curved = kotlin.math.abs(t).toDouble().pow(power).toFloat()
        return if (t < 0f) -curved else curved
    }

    /** `x` −1…1 left…right → pan (axis1). `y` −1…1 down…up → tilt (axis0). */
    fun gimbalAxisLinear(normalized: Float): Int {
        val n = normalized.coerceIn(-1f, 1f)
        if (kotlin.math.abs(n) < 0.02f) return GIMBAL_STICK_CENTER
        return (GIMBAL_STICK_CENTER + n * GIMBAL_STICK_TRAVEL)
            .roundToInt()
            .coerceIn(GIMBAL_STICK_MIN, GIMBAL_STICK_MAX)
    }

    fun gimbalAxis(
        normalized: Float,
        sensitivity: Int = GIMBAL_STICK_DEFAULT_SENSITIVITY,
        mapping: VirtualJoystickMapping = VirtualJoystickMapping.DEFAULT,
    ): Int {
        val curved = gimbalAnalogCurve(normalized, mapping.deadzone, mapping.curve.expo)
        if (curved == 0f) return GIMBAL_STICK_CENTER
        val scaled = (curved * gimbalSensitivityGain(sensitivity)).coerceIn(-1f, 1f)
        return (GIMBAL_STICK_CENTER + scaled * GIMBAL_STICK_TRAVEL)
            .roundToInt()
            .coerceIn(GIMBAL_STICK_MIN, GIMBAL_STICK_MAX)
    }

    /** Invert pan in selfie so the throw stays screen-relative. Tilt is unchanged. */
    fun gimbalAxes(
        x: Float,
        y: Float,
        invertPan: Boolean = false,
        sensitivity: Int = GIMBAL_STICK_DEFAULT_SENSITIVITY,
        mapping: VirtualJoystickMapping = VirtualJoystickMapping.DEFAULT,
        linear: Boolean = false,
    ): Pair<Int, Int> {
        if (linear) {
            val pan = if (invertPan) -x else x
            return gimbalAxisLinear(y) to gimbalAxisLinear(pan)
        }
        val pan = if (invertPan != mapping.invertPan) -x else x
        val tilt = if (mapping.invertTilt) -y else y
        return gimbalAxis(tilt, sensitivity, mapping) to gimbalAxis(pan, sensitivity, mapping)
    }

    fun fpsIndex(fps: Int): Int? = VideoFrameRate.fromFps(fps)?.rawValue

    /**
     * iOS `CameraStatusDecoder.fps(index:)`; subscribe display table,
     * including SlowMo 100/120/240. FORMAT SET still only writes a pair
     * the body advertised (or Video 24–60 when camcap is empty).
     */
    fun fpsFromSubscribeIndex(index: Int): Int? = VideoFrameRate.fps(index)

    fun resolutionLabel(code: Int): String = VideoResolution.fromRaw(code)?.label ?: "—"

    /** [profile] carries the session's own names (for example Standard for Normal). */
    fun colorLabel(mode: Int, family: String = "pocket", profile: CameraLabelProfile = CameraLabelProfile.standard): String =
        profile.colorModeLabels[mode] ?: when (mode) {
            COLOR_NORMAL -> "Normal"
            COLOR_HDR -> "HDR"
            COLOR_DLOG -> "D-Log"
            COLOR_DLOG2 -> "D-Log2"
            COLOR_NORMAL10 -> "Normal 10-bit"
            COLOR_DLOG_M -> "D-Log M"
            COLOR_ILOG -> "I-Log"
            COLOR_DOLBY_VISION -> "Dolby Vision"
            else -> "—"
        }

    /** `IsoIndex.allCases` raw bytes. Unknown camcap entries are dropped. */
    val ISO_INDEX_ALL = listOf(0x00, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B)
    /** ISO 160, a third stop. Not on the DJI ladder [ISO_INDEX_ALL], so the DJI tables leave it out. */
    const val ISO_160 = 0xE0
    /** Every stored ISO stop: the DJI ladder plus [ISO_160]. */
    val ISO_INDEX_BYTES = (ISO_INDEX_ALL + ISO_160).toSet()

    fun isoLabel(index: Int): String =
        when (index) {
            0x00 -> "Auto"
            0x03 -> "100"
            0x04 -> "200"
            0x05 -> "400"
            0x06 -> "800"
            0x07 -> "1600"
            0x08 -> "3200"
            0x09 -> "6400"
            0x0A -> "12800"
            0x0B -> "25600"
            ISO_160 -> "160"
            else -> "—"
        }

    /** nil for Auto / unknown; matches Swift `IsoIndex.isoValue`. */
    fun isoValue(index: Int): Int? =
        when (index) {
            0x03 -> 100
            0x04 -> 200
            0x05 -> 400
            0x06 -> 800
            0x07 -> 1600
            0x08 -> 3200
            0x09 -> 6400
            0x0A -> 12800
            0x0B -> 25600
            ISO_160 -> 160
            else -> null
        }

    fun isoIndexFromValue(iso: Int): Int? =
        when (iso) {
            100 -> 0x03
            200 -> 0x04
            400 -> 0x05
            800 -> 0x06
            1600 -> 0x07
            3200 -> 0x08
            6400 -> 0x09
            12800 -> 0x0A
            25600 -> 0x0B
            160 -> ISO_160
            else -> null
        }

    /** D-Log2 has no Auto ISO. Unknown color is treated as Normal. */
    fun offersIsoAuto(colorMode: Int): Boolean = colorMode != COLOR_DLOG2

    /** GET `0x8E` pid `0x000F` only when Auto ISO exists. */
    fun shouldGetIsoLimit(colorMode: Int): Boolean = offersIsoAuto(colorMode)

    fun isoWheelIndices(available: List<Int>, fallback: List<Int>): List<Int> =
        if (available.isEmpty()) fallback else available

    /**
     * Native base ISO for D-Log ↔ D-Log2 hops. Rec.709 / HLG / D-Log M / unknown:
     * none. Hop uses this, not [markedIsoLabel] (D-Log M stars 400 but does not hop).
     */
    fun baseIsoLabel(colorMode: Int): String? =
        when (colorMode) {
            COLOR_DLOG -> "400"
            COLOR_DLOG2 -> "1600"
            else -> null
        }

    /**
     * If the operator is still on [from]'s native ISO, hop to [to]'s native.
     * Off-base or Auto stays put. Rec.709 / HDR / D-Log M have no native; no hop.
     */
    fun nativeIsoHop(from: Int, to: Int, currentIndex: Int, hopEnabled: Boolean): Int? {
        if (!hopEnabled || from == to) return null
        val fromBase = baseIsoLabel(from)?.toIntOrNull() ?: return null
        val toBase = baseIsoLabel(to)?.toIntOrNull() ?: return null
        val current = isoValue(currentIndex) ?: return null
        if (current != fromBase) return null
        return isoIndexFromValue(toBase)
    }

    /**
     * Star on the ISO wheel. Follows `cam_image_effect` `@2` after the body
     * reports, mapped like iOS `MonitorTransfer`; D-Log / D-Log M = 400,
     * D-Log2 = 1600. Rec.709 / HLG / unknown: none. Not a tele hop SET.
     */
    fun markedIsoLabel(colorMode: Int): String? =
        when (colorMode) {
            COLOR_DLOG, COLOR_DLOG_M -> "400"
            COLOR_DLOG2 -> "1600"
            else -> null
        }

    fun isoChoices(colorMode: Int): List<Pair<Int, String>> {
        val all =
            listOf(
                0x00 to "Auto",
                0x03 to "100",
                0x04 to "200",
                0x05 to "400",
                0x06 to "800",
                0x07 to "1600",
                0x08 to "3200",
                0x09 to "6400",
                0x0A to "12800",
                0x0B to "25600",
            )
        val allowed =
            when (colorMode) {
                COLOR_DLOG2 -> setOf(0x03, 0x04, 0x05, 0x06, 0x07, 0x08)
                COLOR_DLOG -> setOf(0x00, 0x05, 0x06, 0x07, 0x08, 0x09)
                else -> setOf(0x00, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B)
            }
        return all.filter { it.first in allowed }
    }

    /** Pocket 3 empty-camcap video ladder. Fast-first, matching iOS `CamCapShutter`. */
    val emptyCapVideoDenoms: List<Int> = listOf(
        8000, 6400, 4000, 3200, 2000, 1600, 1000, 800, 500, 400, 250, 200,
        125, 120, 100, 60, 50, 48, 40, 30, 25, 24,
    )

    fun shutterWheelDenoms(available: List<Int>, current: Int): List<Int> {
        if (available.isNotEmpty()) return available
        return mergeCurrentShutter(current, emptyCapVideoDenoms)
    }

    private fun mergeCurrentShutter(current: Int, ladder: List<Int>): List<Int> {
        if (current !in 1..16_000 || current in ladder) return ladder
        val out = ladder.toMutableList()
        val idx = out.indexOfFirst { it < current }
        if (idx >= 0) out.add(idx, current) else out.add(current)
        return out
    }

    /** Next / previous 1/N in camera order (fast-first). nil at the end. */
    fun shutterSteppedDenom(from: Int, steps: Int, available: List<Int>): Int? {
        val list = shutterWheelDenoms(available, from)
        val nearest = list.minByOrNull { kotlin.math.abs(it - from) } ?: return null
        val idx = list.indexOf(from).takeIf { it >= 0 } ?: list.indexOf(nearest)
        val next = idx + steps
        if (next !in list.indices || next == idx) return null
        return list[next]
    }

    /** Next / previous full-stop ISO. Skips Auto. nil at the end. */
    fun isoStepped(from: Int, steps: Int, available: List<Int>): Int? {
        val list = available.filter { it != 0x00 }
        val idx = list.indexOf(from)
        if (from == 0x00 || idx < 0) return null
        val next = idx + steps
        if (next !in list.indices || next == idx) return null
        return list[next]
    }

    val kelvinPresets = listOf(2000, 3200, 4000, 5000, 5600, 6500, 8000, 10000)

}

/** AF-C submenu. `0x02/0x8E` pid `0x003B`. SET/GET value is `01 <mode>`. */
enum class FocusTrackMode(val raw: Int, val label: String) {
    DEFAULT(0x00, "Default"),
    PRODUCT_SHOWCASE(0x01, "Product Showcase"),
    SUBJECT_LOCK(0x02, "Subject Lock Tracking"),
    REGISTERED_PRIORITY(0x03, "Registered Subject Priority"),
    ;

    companion object {
        /** Camera can pause HEVC while switching AF-C intelligence. */
        const val VIDEO_GRACE_SEC = 4.0

        fun fromRaw(raw: Int): FocusTrackMode? = entries.firstOrNull { it.raw == raw }

        fun shouldHoldWatchdog(secondsSinceSet: Double?): Boolean {
            val s = secondsSinceSet ?: return false
            return s >= 0.0 && s < VIDEO_GRACE_SEC
        }

    }
}

/** FOCUS picker + capture-strip chip. Single is `0x24`. The rest are AF-C + pid `0x003B`. */
enum class FocusOption(val chip: String) {
    SINGLE("AF-S"),
    CONTINUOUS_DEFAULT("AF-C"),
    PRODUCT_SHOWCASE("Showcase"),
    SUBJECT_LOCK("Lock"),
    REGISTERED_PRIORITY("Priority"),
    ;

    companion object {
        fun resolve(mode: Int, track: Int): FocusOption? =
            when (mode) {
                CameraCommands.FOCUS_SINGLE -> SINGLE
                CameraCommands.FOCUS_CONTINUOUS ->
                    when (FocusTrackMode.fromRaw(track)) {
                        FocusTrackMode.PRODUCT_SHOWCASE -> PRODUCT_SHOWCASE
                        FocusTrackMode.SUBJECT_LOCK -> SUBJECT_LOCK
                        FocusTrackMode.REGISTERED_PRIORITY -> REGISTERED_PRIORITY
                        FocusTrackMode.DEFAULT, null -> CONTINUOUS_DEFAULT
                    }
                else -> null
            }
    }
}

/**
 * Drop GET / subscribe snapshots that still show the pre-SET audio row.
 * Mirrors iOS `CameraSession.AudioPin` (2 s).
 */
data class AudioPin(
    val channel: Int? = null,
    val vocal: Int? = null,
    val wind: Int? = null,
    val directional: Int? = null,
    val deadlineElapsedMs: Long,
) {
    fun isEmpty(): Boolean =
        channel == null && vocal == null && wind == null && directional == null

    fun absorb(
        incoming: CameraStatus,
        current: CameraStatus,
        nowElapsedMs: Long,
        reported: Boolean = true,
        reportedValues: CameraStatus = incoming,
    ): Pair<CameraStatus, AudioPin?> {
        if (nowElapsedMs >= deadlineElapsedMs) return incoming to null
        if (!reported) return incoming to this
        var next = incoming
        var channel = this.channel
        var vocal = this.vocal
        var wind = this.wind
        var directional = this.directional
        if (channel != null) {
            when {
                reportedValues.audioChannel == channel -> channel = null
                incoming.audioChannel >= 0 -> next = next.copy(audioChannel = current.audioChannel)
            }
        }
        if (vocal != null) {
            when {
                reportedValues.vocalBoost == vocal -> vocal = null
                incoming.vocalBoost >= 0 -> next = next.copy(vocalBoost = current.vocalBoost)
            }
        }
        if (wind != null) {
            when {
                reportedValues.windNr == wind -> wind = null
                incoming.windNr >= 0 -> next = next.copy(windNr = current.windNr)
            }
        }
        if (directional != null) {
            when {
                reportedValues.directionalAudio == directional -> directional = null
                incoming.directionalAudio >= 0 ->
                    next = next.copy(directionalAudio = current.directionalAudio)
            }
        }
        val pin =
            AudioPin(
                channel = channel,
                vocal = vocal,
                wind = wind,
                directional = directional,
                deadlineElapsedMs = deadlineElapsedMs,
            )
        return next to pin.takeUnless { it.isEmpty() }
    }

    companion object {
        const val TTL_MS = 2_000L
    }
}
