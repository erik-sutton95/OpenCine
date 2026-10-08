package com.opencapture.opencine.dji

import com.opencapture.opencine.motion.GimbalWaypoint
import com.opencapture.opencine.vocabulary.CaptureShutterPolicy
import com.opencapture.opencine.vocabulary.CamFov
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.FocusTrackMode
import com.opencapture.opencine.vocabulary.VideoFormat
import com.opencapture.opencine.vocabulary.VideoFrameRate

val CameraCommands.SET: Int get() = 0x02

val CameraCommands.SENDER_APP: Int get() = 0x02

val CameraCommands.RX_CAMERA: Int get() = 0x01

val CameraCommands.FLAG_REQUEST: Int get() = 0x40

val CameraCommands.CMD_RECORD: Int get() = 0x02

val CameraCommands.CMD_EXPO: Int get() = 0x1E

val CameraCommands.CMD_FOCUS: Int get() = 0x24

val CameraCommands.CMD_SHUTTER: Int get() = 0x28

val CameraCommands.CMD_ISO: Int get() = 0x2A

val CameraCommands.CMD_WB: Int get() = 0x2C

val CameraCommands.CMD_RES_FPS: Int get() = 0x18

val CameraCommands.CMD_COLOR: Int get() = 0x42

val CameraCommands.CMD_PARAM: Int get() = 0x8E

val CameraCommands.CMD_AUDIO_DSP_SET: Int get() = 0x9F

val CameraCommands.CMD_AUDIO_DSP_GET: Int get() = 0xA0

val CameraCommands.CMD_TAP_PREPARE: Int get() = 0x22

val CameraCommands.CMD_TAP_POINT: Int get() = 0x30

val CameraCommands.CMD_TAP_HINT: Int get() = 0x68

val CameraCommands.CMD_TAP_COMMIT: Int get() = 0x32

val CameraCommands.PID_AUDIO_CHANNEL: Int get() = 0x0020

val CameraCommands.PID_SELFIE_FLIP: Int get() = 0x0038

val CameraCommands.PID_FOCUS_TRACK: Int get() = 0x003B

val CameraCommands.PID_VOCAL_BOOST: Int get() = 0x004C

/** Untracked pid `0x38` GET reply. Must not complete other `0x8E` waiters. */
fun CameraCommands.isSelfieFlipGetReply(cmdSet: Int, cmdId: Int, payload: ByteArray): Boolean {
    if ((cmdSet and 0xFF) != SET || (cmdId and 0xFF) != CMD_PARAM) return false
    if (payload.size < 7) return false
    if (payload[0] != 0.toByte() || payload[1] != 0.toByte() || payload[2] != 1.toByte()) {
        return false
    }
    if (payload[5] != 1.toByte()) return false
    val pid = (payload[3].toInt() and 0xFF) or ((payload[4].toInt() and 0xFF) shl 8)
    return pid == PID_SELFIE_FLIP
}

/**
 * DJI decode of an ISO index byte: the DJI ladder only, so ISO 160 (not a DJI byte) reads as
 * unknown (I-2).
 */
internal fun CameraCommands.djiIsoIndex(raw: Int): Int = if (raw == ISO_160) -1 else raw

private val COLOR_KNOWN =
    setOf(
        CameraCommands.COLOR_NORMAL, CameraCommands.COLOR_HDR, CameraCommands.COLOR_DLOG,
        CameraCommands.COLOR_DLOG2, CameraCommands.COLOR_NORMAL10, CameraCommands.COLOR_DLOG_M,
    )

/**
 * Pocket 3 / Nano SET / `cam_image_effect` `@2`. Pocket 3 (#176): Normal
 * `00`, HDR `3C`, D-Log M `3D`. Nano: Normal 8-bit `00`, Normal 10-bit
 * `3F`, D-Log M `3D`. Action 6 is the Nano pair without `00`. Other bodies use the COLOR_* constants as wire bytes.
 */
fun CameraCommands.wireColorMode(mode: Int, name: String = "", family: String = ""): Int {
    if (CameraModel.looksLikeNano(name, family) || CameraModel.looksLikeAction6(name)) {
        return when (mode) {
            COLOR_NORMAL -> 0x00
            COLOR_NORMAL10 -> 0x3F
            COLOR_DLOG_M -> 0x3D
            else -> mode
        }
    }
    if (!CameraModel.looksLikePocket3(name)) return mode
    return when (mode) {
        COLOR_NORMAL -> 0x00
        COLOR_DLOG_M -> 0x3D
        else -> mode
    }
}

/** Inverse of [wireColorMode]. */
fun CameraCommands.parseColorMode(byte: Int, name: String = "", family: String = ""): Int {
    // No DJI body reports Dolby Vision: the DJI table leaves it out and reads it as unknown (I-2).
    if (byte == COLOR_DOLBY_VISION) return -1
    if (CameraModel.looksLikeNano(name, family) || CameraModel.looksLikeAction6(name)) {
        return when (byte) {
            0x00 -> COLOR_NORMAL
            0x3F -> COLOR_NORMAL10
            0x3D -> COLOR_DLOG_M
            else -> byte
        }
    }
    if (!CameraModel.looksLikePocket3(name)) return byte
    return when (byte) {
        0x00 -> COLOR_NORMAL
        0x3D -> COLOR_DLOG_M
        else -> byte
    }
}

fun CameraCommands.recordStart(): ByteArray = byteArrayOf(0x01)

fun CameraCommands.recordStop(): ByteArray = byteArrayOf(0x00)

/** JNI extra for `CommandKind.setExpoMode`. */
fun CameraCommands.expoWireExtra(mode: Int): String? =
    when (mode) {
        EXPO_AUTO -> "auto"
        EXPO_MANUAL -> "manual"
        else -> null
    }

fun CameraCommands.focusMode(continuous: Boolean): ByteArray =
    byteArrayOf(if (continuous) FOCUS_CONTINUOUS.toByte() else FOCUS_SINGLE.toByte())

/** Video `0x02/0x18` trailer. SlowMo uses [slowMoFormatTrailer] instead. */
private val _VIDEO_FORMAT_TRAILER: ByteArray = byteArrayOf(0x00, 0x00, 0x00)

val CameraCommands.VIDEO_FORMAT_TRAILER: ByteArray get() = _VIDEO_FORMAT_TRAILER

/**
 * Pocket 3 SlowMo `0x02/0x18` trailer, or null when that fps index has no
 * documented SlowMo request. 4X (100/120) is `00 04 00`; 8X (240) is `00 08 00`.
 */
fun CameraCommands.slowMoFormatTrailer(fpsIndex: Int): ByteArray? =
    when (fpsIndex) {
        VideoFrameRate.FPS100.rawValue,
        VideoFrameRate.FPS120.rawValue,
        VideoFrameRate.FPS200.rawValue,
        -> byteArrayOf(0x00, 0x04, 0x00)
        VideoFrameRate.FPS240.rawValue -> byteArrayOf(0x00, 0x08, 0x00)
        else -> null
    }

/** `[res][fps_idx]` plus Video `00 00 00` or the documented SlowMo trailer. */
fun CameraCommands.resolutionFps(res: Int, fpsIndex: Int, shootingMode: Int = SHOOT_VIDEO): ByteArray {
    val trailer =
        if (shootingMode == SHOOT_SLOWMO) {
            slowMoFormatTrailer(fpsIndex) ?: VIDEO_FORMAT_TRAILER
        } else {
            VIDEO_FORMAT_TRAILER
        }
    return byteArrayOf(res.toByte(), fpsIndex.toByte()) + trailer
}

/**
 * JNI extra for video-format SET. Third field is shooting-mode raw for
 * Pocket 3 and Pocket 4 Pro SlowMo so the facade can emit 4X/8X trailers
 * (200 fps still uses `00 04 00`). Regular Pocket 4 omits it.
 */
fun CameraCommands.formatCommandExtra(
    res: Int,
    fpsIndex: Int,
    shootingMode: Int = SHOOT_VIDEO,
    cameraName: String? = null,
): String {
    if (shootingMode == SHOOT_SLOWMO &&
        CameraModel.supportsSlowMoFormatTrailer(cameraName.orEmpty())
    ) {
        return "$res\u001f$fpsIndex\u001f$shootingMode"
    }
    return "$res\u001f$fpsIndex"
}

val CameraCommands.AUDIO_DSP_SIZE: Int get() = 26

fun CameraCommands.audioDspGet(): ByteArray = ByteArray(0)

/** SET payload is the GET blob with only `@2` rewritten. Do not invent other bytes. */
fun CameraCommands.audioDspSet(blob: ByteArray, at2: Int): ByteArray {
    val out = blob.copyOf()
    if (out.size > 2) out[2] = at2.toByte()
    return out
}

/** Wind off is only `18`. Captured directional bytes already include wind-on. */
fun CameraCommands.patchWind(blob: ByteArray, on: Boolean): ByteArray {
    if (!on) return audioDspSet(blob, WIND_OFF)
    val raw = if (blob.size > 2) blob[2].toInt() and 0xFF else -1
    if (directionalFrom(raw) >= 0) return audioDspSet(blob, raw)
    return audioDspSet(blob, WIND_ON)
}

fun CameraCommands.patchDirectional(blob: ByteArray, mode: Int): ByteArray =
    audioDspSet(
        blob,
        when (mode) {
            1 -> DIR_FRONT
            2 -> DIR_FRONT_BACK
            else -> DIR_ALL
        },
    )

/** `0` off, `1` on, `-1` leave. Directional bytes count as on. */
fun CameraCommands.windFrom(raw: Int): Int =
    when (raw) {
        WIND_OFF -> 0
        WIND_ON, DIR_ALL, DIR_FRONT, DIR_FRONT_BACK -> 1
        else -> -1
    }

/** `0` All / `1` Front / `2` Front+back / `-1` not a directional byte. */
fun CameraCommands.directionalFrom(raw: Int): Int =
    when (raw) {
        DIR_ALL -> 0
        DIR_FRONT -> 1
        DIR_FRONT_BACK -> 2
        else -> -1
    }

fun CameraCommands.audioDspHex(blob: ByteArray): String =
    buildString(blob.size * 2) {
        for (b in blob) append("%02x".format(b.toInt() and 0xFF))
    }

fun CameraCommands.audioDspBytes(hex: String): ByteArray? {
    if (hex.length < 6 || hex.length % 2 != 0) return null
    val out = ByteArray(hex.length / 2)
    for (i in out.indices) {
        val b = hex.substring(i * 2, i * 2 + 2).toIntOrNull(16) ?: return null
        out[i] = b.toByte()
    }
    return out
}

fun CameraCommands.tapPrepare(): ByteArray = byteArrayOf(0x02)

fun CameraCommands.tapPoint(x: Float, y: Float): ByteArray = floatLE(x) + floatLE(y) + ByteArray(12)

fun CameraCommands.tapHint(): ByteArray = byteArrayOf(0x08)

fun CameraCommands.tapCommit(x: Float, y: Float): ByteArray =
    byteArrayOf(0x00, 0x02, 0x01, 0x00) + floatLE(x) + floatLE(y) + ByteArray(8)

val CameraCommands.RX_GIMBAL: Int get() = 0x04

val CameraCommands.LIVE_VIEW_ENABLE_RECEIVER_POCKET: Int get() = 0x08

val CameraCommands.LIVE_VIEW_ENABLE_RECEIVER_NANO: Int get() = 0x41

val CameraCommands.CMD_PHOTO: Int get() = 0x01

val CameraCommands.CMD_EV: Int get() = 0x2E

val CameraCommands.CMD_ZOOM: Int get() = 0xB8

val CameraCommands.CMD_TRACK_SET: Int get() = 0xA6

val CameraCommands.CMD_TRACK_POLL: Int get() = 0xA5

val CameraCommands.CMD_PLAYBACK: Int get() = 0x0C

val CameraCommands.CMD_GIMBAL_ANGLE: Int get() = 0x14

val CameraCommands.CMD_GIMBAL_MODE: Int get() = 0x4C

val CameraCommands.CMD_GIMBAL_PARAMS: Int get() = 0x50

val CameraCommands.CMD_MEDIA_LIST: Int get() = 0x26

val CameraCommands.CMD_MEDIA_DELETE: Int get() = 0x28

val CameraCommands.CMD_MEDIA_FAVORITE: Int get() = 0xBF

val CameraCommands.CMD_NANO_GATE: Int get() = 0x09

val CameraCommands.CMD_LIVE_VIEW: Int get() = 0xA8

val CameraCommands.PID_ISO_LIMIT: Int get() = 0x000F

fun CameraCommands.shootPhoto(): ByteArray = byteArrayOf(0x01)

fun CameraCommands.zoomLens(position: Int): ByteArray {
    val p = position.coerceIn(0, 0xFFFF)
    return byteArrayOf(0x0A, 0x4E, (p and 0xFF).toByte(), ((p shr 8) and 0xFF).toByte())
}

fun CameraCommands.zoomSlew(value: Int): ByteArray {
    val v = value.coerceIn(0, 0xFFFF)
    return byteArrayOf(0x03, 0x00, (v and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte())
}

fun CameraCommands.zoomStop(): ByteArray = byteArrayOf(0xFF.toByte(), 0x00, 0x00, 0x00)

/** Chip stops land on slider lens (Pro 217 / 651 / 1302 / 2604; 2× / 4× interpolate). */
fun CameraCommands.lensForZoomFactor(factor: Double): Int =
    when (val write = CamFov.chipWrite(factor)) {
        is CamFov.ChipWrite.Lens -> write.position
        else -> CamFov.lensPosition(factor)
    }

fun CameraCommands.zoomForFactor(factor: Double): ByteArray = zoomLens(lensForZoomFactor(factor))

/** Native timed target: yaw/roll/pitch i16 LE, absolute + ignore roll, duration in 0.1s. */
fun CameraCommands.gimbalTimedTarget(target: GimbalWaypoint, duration: Double): ByteArray? {
    if (target.pitchDeg !in GimbalWaypoint.TILT_MIN_DEG..GimbalWaypoint.TILT_MAX_DEG) return null
    val nativePitch = target.nativePitchDeg ?: return null
    return gimbalTimedTarget(target.yawDeg, nativePitch, duration)
}

fun CameraCommands.gimbalTimedTarget(yawDeg: Double, nativePitchDeg: Double, duration: Double): ByteArray? {
    if (!yawDeg.isFinite() || !nativePitchDeg.isFinite() || !duration.isFinite() ||
        yawDeg !in GimbalWaypoint.PAN_MIN_DEG..GimbalWaypoint.PAN_MAX_DEG ||
        nativePitchDeg !in -180.0..180.0 || duration !in 0.1..25.5 ||
        kotlin.math.abs(duration * 10 - kotlin.math.round(duration * 10)) >= 1e-6) return null
    fun tenth(value: Double): Int =
        java.lang.Math.copySign(kotlin.math.floor(kotlin.math.abs(value * 10) + 0.5), value).toInt()
    return u16LE(tenth(yawDeg)) + u16LE(0) + u16LE(tenth(nativePitchDeg)) +
        byteArrayOf(0x05, tenth(duration).toByte())
}

fun CameraCommands.gimbalTimedStop(): ByteArray = byteArrayOf(0, 0, 0, 0, 0, 0, 4, 1)

fun CameraCommands.gimbalRecenter(): ByteArray = byteArrayOf(0xFE.toByte(), 0x08)

fun CameraCommands.gimbalFlip(): ByteArray = byteArrayOf(0xFE.toByte(), 0x09)

fun CameraCommands.gimbalFollowFamily(): ByteArray = byteArrayOf(0x02, 0x08)

fun CameraCommands.gimbalFpv(): ByteArray = byteArrayOf(0x01, 0x08)

fun CameraCommands.gimbalDirectionLock(): ByteArray = byteArrayOf(0x00, 0x08)

fun CameraCommands.gimbalParamsGet(): ByteArray = byteArrayOf(0x01, 0x04, 0x05)

fun CameraCommands.setGimbalSpeed(speed: Int): ByteArray =
    byteArrayOf(0x00, 0x05, 0x01, (speed and 0xFF).toByte())

fun CameraCommands.setGimbalTiltLock(locked: Boolean): ByteArray =
    byteArrayOf(0x00, 0x04, 0x01, if (locked) 0x01 else 0x00)

fun CameraCommands.liveViewEnablePayload(): ByteArray =
    byteArrayOf(0x00, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

/** Nano `0x02/0x09` start `…03` / stop `…04`. Do not send on Pocket. */
fun CameraCommands.nanoLiveViewGate(start: Boolean): ByteArray =
    ByteArray(11).also { it[10] = if (start) 0x03 else 0x04 }

fun CameraCommands.enterPlayback(): ByteArray = byteArrayOf(0x01, 0x01, 0x00, 0x01)

fun CameraCommands.exitPlayback(): ByteArray = byteArrayOf(0x01, 0x01, 0x00, 0x00)

fun CameraCommands.trackingBox(id: Int, x: Float, y: Float, width: Float, height: Float): ByteArray {
    val uid = id and 0xFFFF
    return byteArrayOf(0x01, 0x00, 0x00) +
        u16LE(uid) +
        floatLE(x) +
        floatLE(y) +
        floatLE(width) +
        floatLE(height)
}

fun CameraCommands.pollTracking(): ByteArray = byteArrayOf(0x00)

fun CameraCommands.mediaList(counter: Int, cursor: Int): ByteArray {
    val payload = MEDIA_LIST_TEMPLATE.copyOf()
    payload[4] = (counter and 0xFF).toByte()
    payload[10] = (cursor and 0xFF).toByte()
    payload[11] = ((cursor shr 8) and 0xFF).toByte()
    payload[12] = ((cursor shr 16) and 0xFF).toByte()
    payload[13] = ((cursor shr 24) and 0xFF).toByte()
    return payload
}

fun CameraCommands.mediaListTrigger(): ByteArray =
    byteArrayOf(
        0x4A, 0x04, 0x0E, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
    )

fun CameraCommands.deleteMedia(handle: Int, counter: Int): ByteArray =
    byteArrayOf(0x01) +
        u32LE(handle) +
        u32LE(counter) +
        byteArrayOf(0x00) +
        u32LE(1) +
        byteArrayOf(0x01, 0x01, 0x00, 0x00)

/** Action 6 moves On/Off to byte 1 and sends its captured tail verbatim (handbook `devices/action-6/coverage`). */
fun CameraCommands.setMediaFavorite(handle: Int, on: Boolean, counter: Int, cameraName: String = ""): ByteArray =
    if (CameraModel.looksLikeAction6(cameraName)) {
        byteArrayOf(0x01, if (on) 0x01 else 0x00) +
            u32LE(handle) +
            byteArrayOf(0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00)
    } else {
        byteArrayOf(0x01, 0x01) +
            u32LE(handle) +
            u32LE(counter) +
            byteArrayOf(0x00, if (on) 0x01 else 0x00, 0x00, 0x00, 0x00)
    }

/**
 * The only `0x04/0x05` layout with known offsets. Another length is a different
 * frame; reading it as attitude corrupts pan/tilt and Motion Control.
 */
val CameraCommands.ATTITUDE_LENGTH: Int get() = 50

fun CameraCommands.isAttitude(payload: ByteArray): Boolean = payload.size == ATTITUDE_LENGTH

private fun CameraCommands.i16(payload: ByteArray, at: Int): Int =
    ((payload[at].toInt() and 0xFF) or ((payload[at + 1].toInt() and 0xFF) shl 8)).toShort().toInt()

fun CameraCommands.yawTenthDeg(payload: ByteArray): Int? = if (isAttitude(payload)) i16(payload, 4) else null

/** Tilt 0.1° from i16-LE `@20`, negated so look-up is positive (Mimo stick-down → `@20` +). */
fun CameraCommands.pitchTenthDeg(payload: ByteArray): Int? = if (isAttitude(payload)) -i16(payload, 20) else null

/** Native absolute pitch i16-LE `@0` (the `0x04/0x14` pitch reference). */
fun CameraCommands.nativePitchTenthDeg(payload: ByteArray): Int? = if (isAttitude(payload)) i16(payload, 0) else null

/** `0x04/0x01` payload: two u16-LE axes + trailer `00 80 22 00`. */
fun CameraCommands.gimbalStickPayload(axis0: Int, axis1: Int): ByteArray {
    val a0 = axis0.coerceIn(GIMBAL_STICK_MIN, GIMBAL_STICK_MAX)
    val a1 = axis1.coerceIn(GIMBAL_STICK_MIN, GIMBAL_STICK_MAX)
    return byteArrayOf(
        (a0 and 0xFF).toByte(),
        ((a0 shr 8) and 0xFF).toByte(),
        0x00,
        0x00,
        (a1 and 0xFF).toByte(),
        ((a1 shr 8) and 0xFF).toByte(),
        0x00,
        0x80.toByte(),
        0x22,
        0x00,
    )
}

fun CameraCommands.parseShutterDenoms(value: ByteArray): List<Int> {
    if (value.size < 13 || value[0] != 0x01.toByte()) return emptyList()
    val inner = (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
    if (inner < 10 || 3 + inner > value.size) return emptyList()
    val body = value.copyOfRange(3, 3 + inner)
    val count = body[9].toInt() and 0xFF
    val payload = body.copyOfRange(10, body.size)
    if (count <= 0 || payload.size != count * 3) return emptyList()
    val out = ArrayList<Int>(count)
    val seen = HashSet<Int>()
    var i = 0
    while (i + 2 < payload.size) {
        val raw = (payload[i].toInt() and 0xFF) or ((payload[i + 1].toInt() and 0xFF) shl 8)
        if (raw and 0x8000 != 0) {
            val denom = raw and 0x7FFF
            if (denom in 1..16_000 && seen.add(denom)) out.add(denom)
        }
        i += 3
    }
    return out
}

/**
 * `camcap_video_format`; legal `[res][fps]` pairs for the current shooting
 * mode. Pocket 4 Pro Video (`mimo-live-start-20260828`): `01 25 00 0c` then
 * 12× `[res][fps_idx] 00`; 4K 24–60 then 1080p 60–24.
 */
fun CameraCommands.parseVideoFormats(value: ByteArray): List<VideoFormat> {
    if (value.size < 5 || value[0] != 0x01.toByte()) return emptyList()
    val inner = (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
    if (inner < 2 || 3 + inner > value.size) return emptyList()
    val body = value.copyOfRange(3, 3 + inner)
    val count = body[0].toInt() and 0xFF
    if (count < 1 || body.size < 1 + count * 3) return emptyList()
    val out = ArrayList<VideoFormat>(count)
    var i = 1
    repeat(count) {
        if (i + 1 >= body.size) return@repeat
        val res = body[i].toInt() and 0xFF
        val fps = body[i + 1].toInt() and 0xFF
        VideoFormat.parseDji(res, fps)?.let { if (it !in out) out.add(it) }
        i += 3
    }
    return out
}

fun CameraCommands.parseColorModes(value: ByteArray, name: String = "", family: String = ""): List<Int> {
    if (value.size < 5 || value[0] != 0x01.toByte()) return emptyList()
    val inner = (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
    if (inner < 2 || 3 + inner > value.size) return emptyList()
    val body = value.copyOfRange(3, 3 + inner)
    val count = body[0].toInt() and 0xFF
    if (count < 1 || body.size < 1 + count) return emptyList()
    return body.copyOfRange(1, 1 + count)
        .map { parseColorMode(it.toInt() and 0xFF, name, family) }
        .filter { it in COLOR_KNOWN }
}

fun CameraCommands.parseIsoIndices(value: ByteArray): List<Int> {
    if (value.size < 5 || value[0] != 0x01.toByte()) return emptyList()
    val inner = (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
    if (inner < 2 || 3 + inner > value.size) return emptyList()
    val body = value.copyOfRange(3, 3 + inner)
    val count = body[1].toInt() and 0xFF
    if (body[0].toInt() != 0 || count < 1 || body.size < 2 + count) return emptyList()
    return body.copyOfRange(2, 2 + count).map { it.toInt() and 0xFF }.filter { it in ISO_INDEX_ALL }
}

private val MEDIA_LIST_TEMPLATE =
    byteArrayOf(
        0x4A, 0x00, 0x2A, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x2D, 0x00, 0x0D, 0x01, 0x00,
        0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
        0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    )

private fun CameraCommands.u16LE(value: Int): ByteArray =
    byteArrayOf((value and 0xFF).toByte(), ((value shr 8) and 0xFF).toByte())

private fun CameraCommands.u32LE(value: Int): ByteArray =
    byteArrayOf(
        (value and 0xFF).toByte(),
        ((value shr 8) and 0xFF).toByte(),
        ((value shr 16) and 0xFF).toByte(),
        ((value shr 24) and 0xFF).toByte(),
    )

private fun CameraCommands.floatLE(value: Float): ByteArray {
    val bits = value.toRawBits()
    return byteArrayOf(
        (bits and 0xFF).toByte(),
        ((bits shr 8) and 0xFF).toByte(),
        ((bits shr 16) and 0xFF).toByte(),
        ((bits shr 24) and 0xFF).toByte(),
    )
}

/** GET reply `00 00 01 3B 00 02 01 <mode>`. */
fun FocusTrackMode.Companion.parseReply(payload: ByteArray): FocusTrackMode? {
    if (payload.size < 8) return null
    if (payload[0] != 0.toByte() || payload[1] != 0.toByte() || payload[2] != 0x01.toByte()) {
        return null
    }
    val pid = (payload[3].toInt() and 0xFF) or ((payload[4].toInt() and 0xFF) shl 8)
    if (pid != CameraCommands.PID_FOCUS_TRACK) return null
    val len = payload[5].toInt() and 0xFF
    if (len != 2 || payload.size < 8 || payload[6] != 0x01.toByte()) return null
    return fromRaw(payload[7].toInt() and 0xFF)
}

    /**
     * Photo is the one mode whose `0x02/0xE1` value is body-dependent: Pocket 4 / 4 Pro take
     * `0x17`, and a Nano rejects that and takes `0x05`.
     */
    fun CameraCommands.photoModeRaw(cameraName: String?): Int {
        val n = cameraName.orEmpty().lowercase().replace(" ", "")
        return if (n.contains("pocket4")) CameraCommands.SHOOT_PHOTO_POCKET4 else CameraCommands.SHOOT_PHOTO
    }

    /**
     * The camera's own on-screen carousel order; Video, Photo, TimeLapse, HyperLapse,
     * SuperNight (Low-Light on Pocket 3), SlowMo; which is not the numeric order. The
     * wire enum is sparse and unordered, so this is tabled and never computed.
     *
     * Only ever send a value from this table. Sweeping the `0x02/0xE1` value space froze a Nano
     * solid and needed a power cycle, so an unlisted mode must be refused rather than passed
     * through (Osmosis `MEDIA_PROTOCOL.md` §13a, DJI-Remote `engine_media.c`).
     *
     * Panorama (`0x0c`) is documented but left out: no hardware here has confirmed it.
     *
     * Note this is `0x02/0xE1`, never `0x02/0x02`. That opcode is nominally DJI's four-value
     * *work* mode, but on a Nano it **is** record control; a "Video" entry mapped to `[01]`
     * would start a recording behind the operator's back.
     */
    fun CameraCommands.shootingModeCarousel(cameraName: String?): List<Int> =
        listOf(
            CameraCommands.SHOOT_VIDEO,
            photoModeRaw(cameraName),
            CameraCommands.SHOOT_TIMELAPSE,
            CameraCommands.SHOOT_HYPERLAPSE,
            CameraCommands.SHOOT_SUPER_NIGHT,
            CameraCommands.SHOOT_SLOWMO,
        )


    /**
     * Pocket 3 and Action 6 TimeLapse start/stop is `0x02/0x01` `01`/`00`, not Video `0x02/0x02`.
     * Pocket 4 / 4 Pro TimeLapse stays Video record until a later survey.
     */
    fun CaptureShutterPolicy.usesShutterTriggerOnPocket3(shootingMode: Int, cameraName: String?): Boolean =
        shootingMode == CameraCommands.SHOOT_TIMELAPSE &&
            (CameraModel.looksLikePocket3(cameraName.orEmpty()) ||
                CameraModel.looksLikeAction6(cameraName.orEmpty()))

    /** JNI extra for command 36. Empty stays start `01` in the facade. */
    fun CaptureShutterPolicy.shootPhotoExtra(start: Boolean): String = if (start) "1" else "0"

    fun CaptureShutterPolicy.captureKind(shootingMode: Int, cameraName: String?): CaptureShutterPolicy.CaptureKind =
        when {
            isStillCapture(shootingMode) -> CaptureShutterPolicy.CaptureKind.PHOTO
            usesShutterTriggerOnPocket3(shootingMode, cameraName) -> CaptureShutterPolicy.CaptureKind.SHUTTER_TRIGGER
            else -> CaptureShutterPolicy.CaptureKind.VIDEO_RECORD
        }
