package com.opencapture.opencine.insta360.luna

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Luna control requests, byte-for-byte ports of Adapters/Insta360Protocol `LunaControl.swift`
 * and `LunaProtocol.swift`. All are plaintext on TCP 6666. [functionMode] is the settings bank
 * the shooting mode reads (7 normal video); the backend passes the active one.
 */
internal object LunaControl {
    const val SET_OPTIONS = 7
    const val GET_OPTIONS = 8
    const val SET_PHOTOGRAPHY_OPTIONS = 9
    const val GET_PHOTOGRAPHY_OPTIONS = 10
    const val GIMBAL_CONTROL = 226
    const val OPEN_TRACKING = 237
    const val CANCEL_TRACKING = 238
    const val MAXIMUM_ZOOM = 15.0
    const val FUNCTION_MODE_VIDEO = 7
    const val FUNCTION_MODE_PHOTO = 6
    /** Observed official shutter-SET ISO top limit: UInt32 wrap of -3200, not an ISO. */
    const val OFFICIAL_ISO_TOP_LIMIT = 4_294_964_096L

    class Request(val code: Int, val body: ByteArray)

    private fun tag(field: Int, wire: Int) = LunaWire.varint(((field shl 3) or wire).toLong())
    private fun sint32(field: Int, value: Int) = LunaWire.integer(field, ((value shl 1) xor (value shr 31)).toLong() and 0xFFFF_FFFFL)
    private fun double(field: Int, value: Double) =
        tag(field, 1) + ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putDouble(value).array()
    private fun float(field: Int, value: Float) =
        tag(field, 5) + ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(value).array()
    private fun packed(values: List<Int>) = values.fold(ByteArray(0)) { acc, v -> acc + LunaWire.varint(v.toLong()) }
    private fun joined(fields: Map<Int, ByteArray>) = fields.toSortedMap().values.fold(ByteArray(0)) { acc, b -> acc + b }

    // Official cmd 9 shape.

    /** Whole PhotographyOptions with defaults 20, 21, 31, 88 present; the camera applies only [types]. */
    fun photographySet(types: List<Int>, fields: Map<Int, ByteArray>, functionMode: Int = FUNCTION_MODE_VIDEO): Request {
        val all = mapOf(
            20 to LunaWire.blob(20, ByteArray(0)),
            21 to LunaWire.blob(21, ByteArray(0)),
            31 to LunaWire.integer(31, 1),
            88 to LunaWire.integer(88, 1),
        ) + fields
        val body = LunaWire.blob(1, packed(types)) + LunaWire.blob(2, joined(all)) + LunaWire.integer(3, functionMode.toLong())
        return Request(SET_PHOTOGRAPHY_OPTIONS, body)
    }

    /** Scalar option; zero is encoded explicitly (fw 1.1.15 ignores an omitted FOV 33). */
    fun photographyValue(type: Int, value: Long, functionMode: Int = FUNCTION_MODE_VIDEO) =
        photographySet(listOf(type), mapOf(type to LunaWire.integer(type, value)), functionMode)

    /** Schema `sint32` tenths: +0.3 EV -> 3 -> wire 6. */
    fun exposureBias(stops: Double, functionMode: Int = FUNCTION_MODE_VIDEO): Request {
        require(stops.isFinite() && abs(stops) <= 4)
        val tenths = (stops * 10).roundToInt()
        val fields = if (tenths == 0) mutableMapOf() else mutableMapOf(7 to sint32(7, tenths))
        // fw 1.1.15 official app: photo EV writes types [7, 77] with 77 = 1.
        if (functionMode != FUNCTION_MODE_PHOTO) return photographySet(listOf(7), fields, functionMode)
        fields[77] = LunaWire.integer(77, 1)
        return photographySet(listOf(7, 77), fields, functionMode)
    }

    /** Observed: 1 Standard, 2 I-Log, 5 Dolby Vision. */
    fun colorMode(mode: Long, functionMode: Int = FUNCTION_MODE_VIDEO) = photographyValue(35, mode, functionMode)

    fun whiteBalanceKelvin(kelvin: Long, functionMode: Int = FUNCTION_MODE_VIDEO): Request {
        require(kelvin in 2000..10000)
        return photographyValue(39, kelvin, functionMode)
    }

    /** Official WB Auto is type 39 with the value omitted. */
    fun whiteBalanceAuto(functionMode: Int = FUNCTION_MODE_VIDEO) = photographySet(listOf(39), emptyMap(), functionMode)

    /** fw 1.1.15 stores 1...15; values outside are ignored, not clamped. */
    fun zoom(factor: Double, functionMode: Int = FUNCTION_MODE_VIDEO): Request {
        require(factor in 1.0..MAXIMUM_ZOOM)
        return photographySet(listOf(53), mapOf(53 to double(53, factor)), functionMode)
    }

    /** Observed types [31, 63] (resolution + HDR switch). 1080p 240 (27) is Standard-only: the official app writes colour 35 = 1 with it. */
    fun recordResolution(raw: Long, functionMode: Int = FUNCTION_MODE_VIDEO): Request {
        require(raw > 0)
        val fields = mapOf(31 to LunaWire.integer(31, raw))
        if (raw != 27L) return photographySet(listOf(31, 63), fields, functionMode)
        return photographySet(listOf(31, 63, 35), fields + (35 to LunaWire.integer(35, 1)), functionMode)
    }

    /** The shell's independent ISO / shutter drums map onto Luna's four programs. */
    fun exposureProgram(iso: Long?, shutterSeconds: Double?): Int = when {
        iso == null && shutterSeconds == null -> 0
        shutterSeconds == null -> 1
        iso == null -> 2
        else -> 3
    }

    /**
     * Official exposure SETs (field 21, IQ_3A_MODE 100 = 2 PRO). Auto ISO in a shutter program adds
     * the ISO top-limit sentinel (types 21, 24, 100). Manual with an explicit ISO omits it: on fw
     * 1.1.15 the sentinel turns program 3 into 2 and drops the ISO.
     */
    fun videoExposure(program: Int, iso: Long? = null, shutterSeconds: Double? = null, functionMode: Int = FUNCTION_MODE_VIDEO): Request {
        if (shutterSeconds != null) require(shutterSeconds > 0 && shutterSeconds <= 60)
        var exposure = if (program == 0) ByteArray(0) else LunaWire.integer(1, program.toLong())
        if (iso != null && iso > 0) exposure += LunaWire.integer(2, iso)
        if (shutterSeconds != null) exposure += double(3, shutterSeconds)
        val fields = mutableMapOf(21 to LunaWire.blob(21, exposure), 100 to LunaWire.integer(100, 2))
        val autoIso = program == 2 || (program == 3 && (iso ?: 0L) == 0L)
        if (autoIso) fields[24] = LunaWire.integer(24, OFFICIAL_ISO_TOP_LIMIT)
        var types = if (autoIso) listOf(21, 24, 100) else listOf(21, 100)
        // fw 1.1.15 official app: photo mode writes the still (20) and video (21) exposure together;
        // 21 alone leaves the still exposure unchanged.
        if (functionMode == FUNCTION_MODE_PHOTO) {
            types = listOf(20) + types
            fields[20] = LunaWire.blob(20, exposure)
        }
        return photographySet(types, fields, functionMode)
    }

    /** Option 93, fw 1.1.15 verified (stored at once, video and photo share it): 1 AF-S, 3 AF-C, 6 Product Showcase. */
    fun afMode(mode: Long, functionMode: Int = FUNCTION_MODE_VIDEO) = photographyValue(93, mode, functionMode)

    /** Option 46 `metering_enable`: true Face Priority, false Matrix (an explicit 0). fw 1.1.15 stores it 3.7 to 4.9 s after the SET. */
    fun faceMetering(on: Boolean, functionMode: Int = FUNCTION_MODE_VIDEO) = photographyValue(46, if (on) 1 else 0, functionMode)

    /** Option 91 field 2: 1 slow, 2 medium, 3 fast, 4 sensitive. */
    fun gimbalFollowSpeed(speed: Long, functionMode: Int = FUNCTION_MODE_VIDEO) =
        photographySet(listOf(91), mapOf(91 to LunaWire.blob(91, LunaWire.integer(2, speed))), functionMode)

    /** Option 91 field 4: 1 FPV, 2 Roll Lock, 3 Roll & Tilt Lock, 4 FPV-V. */
    fun gimbalMode(mode: Long, functionMode: Int = FUNCTION_MODE_VIDEO) =
        photographySet(listOf(91), mapOf(91 to LunaWire.blob(91, LunaWire.integer(4, mode))), functionMode)

    private fun roi(values: List<Double>, firstField: Int): ByteArray {
        require(values.all { it in 0.0..1.0 })
        return values.withIndex().filter { it.value != 0.0 }
            .fold(ByteArray(0)) { acc, (offset, value) -> acc + float(firstField + offset, value.toFloat()) }
    }

    /** fw 1.1.15 official ROI with the camera upright: 0.1545 x 0.271..0.275 of the 16:9 preview. */
    const val FOCUS_WIDTH = 0.1545
    const val FOCUS_HEIGHT = 0.2727

    fun tapFocus(x: Double, y: Double, width: Double = FOCUS_WIDTH, height: Double = FOCUS_HEIGHT, functionMode: Int = FUNCTION_MODE_VIDEO): Request {
        val params = LunaWire.integer(1, 1) + roi(listOf(x, y, width, height), 2)
        return photographySet(listOf(94), mapOf(94 to LunaWire.blob(94, params)), functionMode)
    }

    fun openTracking(x: Double, y: Double, width: Double, height: Double, nowMillis: Long = System.currentTimeMillis()): Request =
        Request(OPEN_TRACKING, LunaWire.integer(1, nowMillis) + roi(listOf(x, y, width, height), 2))

    val cancelTracking = Request(CANCEL_TRACKING, ByteArray(0))

    /** Action 1 move, 2 recenter, 3 flip. Axes -99..99; a move with both axes zero releases the stick. */
    fun gimbal(action: Int, upDown: Int = 0, leftRight: Int = 0, field4: Long? = null): Request {
        require(upDown in -99..99 && leftRight in -99..99)
        var remote = ByteArray(0)
        if (upDown != 0) remote += sint32(1, upDown)
        if (leftRight != 0) remote += sint32(2, leftRight)
        val body = LunaWire.integer(1, action.toLong()) + LunaWire.blob(2, remote)
        return Request(GIMBAL_CONTROL, if (field4 == null) body else body + LunaWire.integer(4, field4))
    }

    /** fw 1.1.15 official app sends field 4 = 4 on every stick move and release, whatever the gimbal mode. */
    const val STICK_FIELD4 = 4L

    fun gimbalStick(pan: Double, tilt: Double): Request = gimbal(
        1,
        upDown = Math.round(tilt.coerceIn(-1.0, 1.0) * 99).toInt(),
        leftRight = Math.round(pan.coerceIn(-1.0, 1.0) * 99).toInt(),
        field4 = STICK_FIELD4,
    )

    /** App 2.34.5 GIMBAL_ACTION_SET_ANGLE (5): field 5 {roll 1, pitch 2, yaw 3} float degrees, handle frame. Zero axes omitted. */
    fun gimbalSetAngle(pitch: Float, yaw: Float, roll: Float = 0f): Request {
        require(pitch.isFinite() && yaw.isFinite() && roll.isFinite())
        val angle = listOf(1 to roll, 2 to pitch, 3 to yaw).filter { it.second != 0f }
            .fold(ByteArray(0)) { acc, (field, value) -> acc + float(field, value) }
        return Request(GIMBAL_CONTROL, LunaWire.integer(1, 5) + LunaWire.blob(5, angle))
    }

    /** GIMBAL_ACTION_GET_ANGLE (6); parse the reply with [gimbalAngle]. */
    val gimbalGetAngle = Request(GIMBAL_CONTROL, LunaWire.integer(1, 6))

    data class GimbalAngle(val grf: Int, val roll: Float, val pitch: Float, val yaw: Float)

    /** GimbalControlResp {int32 grf = 1; float roll = 2, pitch = 3, yaw = 4}; omitted fields are zero. */
    fun gimbalAngle(reply: ByteArray): GimbalAngle {
        val fields = LunaWire.fields(reply)
        fun f(n: Int) = fields.lastOrNull { it.number == n && it.wire == 5 }
            ?.let { ByteBuffer.wrap(it.bytes).order(ByteOrder.LITTLE_ENDIAN).float } ?: 0f
        return GimbalAngle(LunaWire.number(reply, 1).toInt(), f(2), f(3), f(4))
    }

    // Official cmd 7 shape: cached device Options (1 = 1, 5 = 48000, 42 = 1, 82 = 3) around one field.

    fun deviceSet(type: Int, value: Long): Request {
        val all = mapOf(
            1 to LunaWire.integer(1, 1),
            5 to LunaWire.integer(5, 48_000),
            42 to LunaWire.integer(42, 1),
            82 to LunaWire.integer(82, 3),
        ) + (if (value == 0L) emptyMap() else mapOf(type to LunaWire.integer(type, value)))
        return Request(SET_OPTIONS, LunaWire.blob(1, packed(listOf(type))) + LunaWire.blob(2, joined(all)))
    }

    // Camera clock. Its time-of-day timecode runs from it; the phone app is expected to set it.

    const val SYNC_TIME_ACCURATE = 214

    /**
     * Official connect: LOCAL_TIME 12 (unix seconds), TIME_ZONE 13 (seconds east of GMT, int32)
     * and GEOGRAPHIC_TIME_ZONE 175. fw 1.1.15 does not return them on GET.
     */
    fun setClock(unixSeconds: Long, timeZoneSeconds: Int, zone: String): Request {
        val nested = LunaWire.integer(12, unixSeconds) + LunaWire.integer(13, timeZoneSeconds.toLong()) +
            LunaWire.blob(175, zone.toByteArray())
        return Request(SET_OPTIONS, LunaWire.blob(1, packed(listOf(12, 13, 175))) + LunaWire.blob(2, nested))
    }

    /** PHONE_COMMAND_SYNCTIME_ACCURATE `{1: {1: s, 2: ms}, 2: count}`, sent twice by the official app (count 0, then 1). */
    fun syncTimeAccurate(unixMilliseconds: Long, count: Int): Request {
        val time = LunaWire.integer(1, unixMilliseconds / 1000) + LunaWire.integer(2, unixMilliseconds % 1000)
        return Request(SYNC_TIME_ACCURATE, LunaWire.blob(1, time) + (if (count > 0) LunaWire.integer(2, count.toLong()) else ByteArray(0)))
    }

    // Capture, media and status requests.

    val startLive = Request(1, LunaWire.liveBody)
    val stopLive = Request(2, ByteArray(0))
    /** `IFRAME_REQUEST`: the body answers with a keyframe in about a second. */
    val keyframe = Request(105, ByteArray(0))
    /** Mode 0 (normal) is omitted; 5 is 360 gimbal pano. */
    fun takePicture(mode: Long = 0) = Request(3, if (mode == 0L) ByteArray(0) else LunaWire.integer(1, mode))
    /**
     * fw 1.1.15 official app: the capture mode rides in cmd 4 field 1 and cmd 5 field 2 (1 Video,
     * 4 TimeShift, 9 Slow Motion); Timelapse uses cmd 22 / 23. PureVideo was not captured and records as video.
     */
    private fun captureMode(mode: LunaShootingMode): Long = when (mode) {
        LunaShootingMode.TIME_SHIFT -> 4
        LunaShootingMode.SLOW_MOTION -> 9
        else -> 1
    }

    /** ExtraMetadata stub the official app sends on every stop: `{13:{6:1}, 19:{}, 21:{}, 23:{}, 26:{}, 44:{}, 71:{}, 160:{}}`. */
    private val captureStopMetadata = LunaWire.hex("6a0230019a0100aa0100ba0100d20100e20200ba0400820a00")

    fun startCapture(mode: LunaShootingMode): Request =
        if (mode == LunaShootingMode.TIMELAPSE) Request(22, byteArrayOf(8, 1)) else Request(4, LunaWire.integer(1, captureMode(mode)))

    fun stopCapture(mode: LunaShootingMode): Request =
        if (mode == LunaShootingMode.TIMELAPSE) Request(23, LunaWire.integer(1, 1) + LunaWire.blob(2, captureStopMetadata))
        else Request(5, LunaWire.blob(1, captureStopMetadata) + LunaWire.integer(2, captureMode(mode)))
    val captureStatus = Request(15, ByteArray(0))

    /** Official shape: media type 2 (video and photo), limit INT32_MAX, card location. */
    fun fileList(mediaType: Long = 2, location: Long = 2, start: Long = 0,
        count: Long = Int.MAX_VALUE.toLong()): Request {
        require(start in 0..0xFFFF_FFFFL && count in 0..0xFFFF_FFFFL)
        val body = LunaWire.integer(1, mediaType) +
            (if (start > 0) LunaWire.integer(2, start) else ByteArray(0)) +
            LunaWire.integer(3, count) + LunaWire.integer(4, location)
        return Request(13, body)
    }

    fun fileInfoList(location: Long? = null) = Request(38, location?.let { LunaWire.integer(1, it) } ?: ByteArray(0))

    /** Extra type 1 metadata, 2 NV12 thumbnail. */
    fun fileExtra(path: String, extraType: Long? = null): Request {
        require(path.isNotEmpty())
        return Request(11, LunaWire.blob(1, path.toByteArray()) + (extraType?.let { LunaWire.integer(2, it) } ?: ByteArray(0)))
    }

    fun deleteFiles(uri: String): Request {
        require(uri.isNotEmpty() && uri.toByteArray().size <= 512)
        return Request(12, LunaWire.blob(1, uri.toByteArray()))
    }

    fun accessCameraFileState(state: Long) = Request(118, LunaWire.integer(1, state))
    /**
     * Official app: 5 on entering the shooting view, 1 on leaving it for the album. 5 also wakes
     * the gimbal, which sleeps pointing down when no app holds the shooting view (fw 1.1.15).
     */
    const val SHOOTING_VIEW_ACCESS_STATE = 5L
    const val ALBUM_ACCESS_STATE = 1L

    private fun optionTypes(numbers: List<Int>, packed: Boolean): ByteArray {
        require(numbers.isNotEmpty() && numbers.size <= 256 && numbers.all { it > 0 && it < (1 shl 29) })
        return if (packed) LunaWire.blob(1, packed(numbers)) else numbers.fold(ByteArray(0)) { acc, n -> acc + LunaWire.integer(1, n.toLong()) }
    }

    fun getOptions(numbers: List<Int>, packed: Boolean = true) = Request(GET_OPTIONS, optionTypes(numbers, packed))

    /** Official 1 Hz poll: battery 11, storage 20, 85, screen battery 180. */
    val statusRequest = getOptions(listOf(11, 20, 85, 180))
    /** Official storage-list poll: repeated per-location storage176 and active location177. */
    val storageListRequest = getOptions(listOf(176, 177))
    /** Official mode probe (41, 40, 65, 124, 132, 82, 135, 169, 173). */
    val shootingModeRequest = getOptions(listOf(41, 40, 65, 124, 132, 82, 135, 169, 173))

    fun getPhotographyOptions(types: List<Int>, functionMode: Int = FUNCTION_MODE_VIDEO, packed: Boolean = false) =
        Request(GET_PHOTOGRAPHY_OPTIONS, optionTypes(types, packed) + LunaWire.integer(2, functionMode.toLong()))

    /** Official remaining-record-time poll (photography option 99), per function mode. */
    fun remainingTimeRequest(functionMode: Int = FUNCTION_MODE_VIDEO) =
        getPhotographyOptions(listOf(REMAINING_TIME), functionMode, packed = true)

    /** Photography option 99: remaining record time per card location. */
    const val REMAINING_TIME = 99

    /** Every photography type the monitor shows. */
    val settingTypes = listOf(6, 7, 18, 20, 21, 24, 31, 33, 35, 39, 40, 43, 46, 53, 72, 73, 91, 92, 93, 100, 104)
}
