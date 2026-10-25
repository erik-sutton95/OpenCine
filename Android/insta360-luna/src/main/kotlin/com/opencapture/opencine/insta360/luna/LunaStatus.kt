package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.CameraTrackFrame
import com.opencapture.opencine.insta360.shell.aspectLabel
import com.opencapture.opencine.insta360.shell.CameraTrackState
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.roundToInt

// Typed decoders for Luna replies and notifications, ports of Adapters/Insta360Protocol
// `LunaStatus.swift`. The camera sends explicit zeros, so a present field means "reported".

/** Protobuf view with presence, singular last-wins and wire checks (Swift `ProtoMessage`). */
internal class LunaProto(data: ByteArray) {
    val fields = LunaWire.fields(data)
    private fun last(n: Int) = fields.lastOrNull { it.number == n }
    fun u(n: Int): Long? = last(n)?.let { require(it.wire == 0) { "Invalid field $n" }; it.value }
    fun u(n: Int, default: Long): Long = u(n) ?: default
    fun b(n: Int): Boolean? = u(n)?.let { it != 0L }
    fun bytes(n: Int): ByteArray? = last(n)?.let { require(it.wire == 2) { "Invalid field $n" }; it.bytes }
    fun text(n: Int): String? = bytes(n)?.toString(Charsets.UTF_8)
    fun double(n: Int): Double? = last(n)?.let {
        require(it.wire == 1 && it.bytes.size == 8) { "Invalid field $n" }
        ByteBuffer.wrap(it.bytes).order(ByteOrder.LITTLE_ENDIAN).double
    }
    fun float(n: Int): Double? = last(n)?.let {
        require(it.wire == 5 && it.bytes.size == 4) { "Invalid field $n" }
        ByteBuffer.wrap(it.bytes).order(ByteOrder.LITTLE_ENDIAN).float.toDouble()
    }
    fun all(n: Int) = fields.filter { it.number == n }.map { require(it.wire == 2) { "Invalid field $n" }; it.bytes }
    /** Packed or unpacked repeated varints. */
    fun repeated(n: Int): List<Long> = fields.filter { it.number == n }.flatMap { field ->
        if (field.wire == 0) listOf(field.value) else LunaWire.schemes(LunaWire.blob(1, field.bytes))
    }

    companion object {
        fun unzigzag32(value: Long): Int { val raw = value.toInt(); return (raw ushr 1) xor -(raw and 1) }
    }
}

internal enum class LunaShootingMode(val functionMode: Int, private val deviceType: Int, private val subMode: Long) {
    VIDEO(7, 41, 0), TIMELAPSE(2, 41, 2), TIME_SHIFT(12, 41, 4), SLOW_MOTION(21, 41, 9), PURE_VIDEO(27, 41, 11),
    PHOTO(6, 40, 0), PANO(67, 40, 8);

    val isPhoto get() = this == PHOTO || this == PANO

    /** Observed: exact official cmd 7 body for every mode. */
    fun request() = LunaControl.deviceSet(deviceType, subMode)

    companion object {
        /** From device options 40/41 or notification 8275. The inactive family reads 100 (NONE). */
        fun from(photoSubMode: Long?, videoSubMode: Long?): LunaShootingMode? = when ((photoSubMode ?: 100L) to (videoSubMode ?: 100L)) {
            100L to 0L -> VIDEO
            100L to 2L -> TIMELAPSE
            100L to 4L -> TIME_SHIFT
            100L to 9L -> SLOW_MOTION
            100L to 11L -> PURE_VIDEO
            0L to 100L -> PHOTO
            8L to 100L -> PANO
            else -> null
        }
    }
}

/** `ExposureOptions` (option 20 stills, 21 video). ISO 0 / shutter 0.0 mean the camera chooses. */
internal data class LunaExposure(val program: Long, val iso: Long, val shutterSeconds: Double) {
    companion object {
        fun parse(data: ByteArray) = LunaProto(data).let { LunaExposure(it.u(1, 0), it.u(2, 0), it.double(3) ?: 0.0) }
    }
}

/** Option 91: rc speed, follow speed, track sensitivity, mode (official labels 1 FPV ... 4 FPV-V). */
internal data class LunaGimbalOptions(val rcSpeed: Long, val followSpeed: Long, val trackSensitivity: Long, val mode: Long)

/** `GimbalStatus` (option 92, notification 8302): roll, pitch, yaw limit, stall, sleep, over/under temp, imbalance, shutdown. */
internal data class LunaGimbalStatus(val flags: List<Boolean>) {
    val rollLimit get() = flags[0]
    val pitchLimit get() = flags[1]
    val yawLimit get() = flags[2]
    val stall get() = flags[3]

    companion object {
        fun parse(data: ByteArray) = LunaProto(data).let { m -> LunaGimbalStatus((1..9).map { m.u(it, 0) != 0L }) }
    }
}

/** Everything the official app reads from `PhotographyOptions`; null = the camera omitted the field. */
internal data class LunaPhotographySettings(
    val types: List<Int> = emptyList(),
    val functionMode: Int? = null,
    val sharpness: Long? = null,
    val exposureBiasTenths: Int? = null,
    val filter: Long? = null,
    val stillExposure: LunaExposure? = null,
    val videoExposure: LunaExposure? = null,
    val isoTopLimit: Long? = null,
    val recordResolution: Long? = null,
    val fov: Long? = null,
    val colorMode: Long? = null,
    val whiteBalanceKelvin: Long? = null,
    val photoResolution: Long? = null,
    /** Option 46: true Face Priority, false Matrix. */
    val faceMetering: Boolean? = null,
    val zoom: Double? = null,
    val iLog: Boolean? = null,
    val colorRecovery: Boolean? = null,
    val gimbal: LunaGimbalOptions? = null,
    val gimbalStatus: LunaGimbalStatus? = null,
    /** Option 93: 1 AF-S, 3 AF-C, 6 Product Showcase (the official app offers only these). */
    val afMode: Long? = null,
    /** Option 99: (seconds, card location) pairs. */
    val remainingRecordTime: List<Pair<Long, Long>> = emptyList(),
    val iq3AMode: Long? = null,
    val filterStrength: Long? = null,
) {
    val videoResolution get() = recordResolution?.let { LunaVideoResolution.of(it) }

    /** Later partial reads overwrite only the fields they carry (proto3 omits defaults). */
    fun merge(other: LunaPhotographySettings) = LunaPhotographySettings(
        (types + other.types).distinct().sorted(), other.functionMode ?: functionMode, other.sharpness ?: sharpness,
        other.exposureBiasTenths ?: exposureBiasTenths, other.filter ?: filter, other.stillExposure ?: stillExposure,
        other.videoExposure ?: videoExposure, other.isoTopLimit ?: isoTopLimit,
        if (31 in other.types) other.recordResolution else other.recordResolution ?: recordResolution,
        other.fov ?: fov, if (35 in other.types) other.colorMode else other.colorMode ?: colorMode,
        other.whiteBalanceKelvin ?: whiteBalanceKelvin,
        other.photoResolution ?: photoResolution, other.faceMetering ?: faceMetering, other.zoom ?: zoom, other.iLog ?: iLog, other.colorRecovery ?: colorRecovery,
        other.gimbal ?: gimbal, other.gimbalStatus ?: gimbalStatus, other.afMode ?: afMode,
        // Option 99 rides its own poll: only a reply that carries it replaces the last report.
        if (LunaControl.REMAINING_TIME in other.types || other.remainingRecordTime.isNotEmpty()) other.remainingRecordTime
        else remainingRecordTime,
        other.iq3AMode ?: iq3AMode, other.filterStrength ?: filterStrength,
    )

    companion object {
        /** `GetPhotographyOptionsResp` / `SetPhotographyOptionsResp` / notification 8293: 1 types, 2 options, 3 mode. */
        fun parse(response: ByteArray): LunaPhotographySettings {
            val outer = LunaProto(response)
            val types = outer.repeated(1).map { it.toInt() }
            val mode = outer.u(3)?.toInt()
            val o = LunaProto(outer.bytes(2) ?: return LunaPhotographySettings(types, mode))
            return LunaPhotographySettings(
                types = types, functionMode = mode, sharpness = o.u(6),
                exposureBiasTenths = o.u(7)?.let(LunaProto::unzigzag32), filter = o.u(18),
                stillExposure = o.bytes(20)?.let(LunaExposure::parse), videoExposure = o.bytes(21)?.let(LunaExposure::parse),
                isoTopLimit = o.u(24), recordResolution = o.u(31), fov = o.u(33), colorMode = o.u(35),
                whiteBalanceKelvin = o.u(39), photoResolution = o.u(40),
                // proto3 may omit false: a requested 46 with no value is Matrix.
                faceMetering = o.b(46) ?: if (46 in types) false else null, zoom = o.double(53), iLog = o.b(72),
                colorRecovery = o.b(73),
                gimbal = o.bytes(91)?.let { LunaProto(it) }?.let { LunaGimbalOptions(it.u(1, 0), it.u(2, 0), it.u(3, 0), it.u(4, 0)) },
                gimbalStatus = o.bytes(92)?.let(LunaGimbalStatus::parse), afMode = o.u(93),
                remainingRecordTime = o.all(99).map { LunaProto(it).let { e -> e.u(1, 0) to e.u(2, 0) } },
                iq3AMode = o.u(100), filterStrength = o.u(104),
            )
        }
    }
}

/** `VideoResolution` enum (photography option 31). Width/height/fps from the schema enum name. */
internal data class LunaVideoResolution(val rawValue: Long, val width: Int, val height: Int, val framesPerSecond: Double) {
    val aspectLabel get() = aspectLabel(width, height)

    companion object {
        val index: Map<Long, LunaVideoResolution> = LunaSchemaTables.video.toList().chunked(4)
            .associate { (raw, w, h, fps) -> raw.toLong() to LunaVideoResolution(raw.toLong(), w, h, fps / 100.0) }
        /** Observed on the wire; preferred when several enum values share a shape. */
        val observed = setOf(14L, 24L, 31L, 43L, 48L, 52L, 211L, 214L, 454L)

        fun of(raw: Long) = index[raw]

        fun rawValue(width: Int, height: Int, framesPerSecond: Double): Long? = index.values
            .filter { it.width == width && it.height == height && abs(it.framesPerSecond - framesPerSecond) < 0.01 }
            .map { it.rawValue }.minWithOrNull(compareBy({ if (it in observed) 0 else 1 }, { it }))
    }
}

/** `PhotoSize` enum (photography option 40). */
internal data class LunaPhotoSize(val rawValue: Long, val width: Int, val height: Int) {
    val aspectLabel get() = aspectLabel(width, height)

    companion object {
        private val index = LunaSchemaTables.photo.toList().chunked(3).associate { (raw, w, h) -> raw.toLong() to LunaPhotoSize(raw.toLong(), w, h) }
        fun of(raw: Long) = index[raw]
    }
}

/** `BatteryInfo` (option 11, notification 8195) and screen battery (option 180, 8308). */
internal data class LunaBattery(val percent: Long, val powerType: Long) {
    val isCharging get() = powerType != 0L

    companion object {
        fun parse(data: ByteArray) = LunaProto(data).let { LunaBattery(it.u(2, 0), it.u(1, 0)) }
    }
}

/** `StorageState` (options 20 and 176). Card state 0 PASS, 1 NOCARD; location 2 inner, 3 SD. */
internal data class LunaStorage(val cardState: Long, val freeBytes: Long, val totalBytes: Long, val location: Long) {
    val isUsable get() = cardState == 0L && totalBytes > 0

    companion object {
        fun parse(data: ByteArray) = LunaProto(data).let { LunaStorage(it.u(1, 0), it.u(2, 0), it.u(3, 0), it.u(4, 0)) }
    }
}

/** Decoded device `Options` (cmd 8 replies) for the fields the official app polls. */
internal data class LunaDeviceStatus(
    val battery: LunaBattery? = null,
    val storage: LunaStorage? = null,
    val storageList: List<LunaStorage> = emptyList(),
    val cardLocationLastUpdate: Long? = null,
    val screenBattery: LunaBattery? = null,
    val screenConnection: Long? = null,
    val photoSubMode: Long? = null,
    val videoSubMode: Long? = null,
) {
    val shootingMode get() = LunaShootingMode.from(photoSubMode, videoSubMode)

    /** A later partial poll keeps what it does not carry. */
    fun merge(other: LunaDeviceStatus) = LunaDeviceStatus(
        other.battery ?: battery, other.storage ?: storage, other.storageList.ifEmpty { storageList },
        other.cardLocationLastUpdate ?: cardLocationLastUpdate, other.screenBattery ?: screenBattery,
        other.screenConnection ?: screenConnection,
        if (other.shootingMode != null) other.photoSubMode else photoSubMode,
        if (other.shootingMode != null) other.videoSubMode else videoSubMode,
    )

    companion object {
        fun parse(response: ByteArray): LunaDeviceStatus {
            val outer = LunaProto(response)
            outer.repeated(1)
            val o = LunaProto(outer.bytes(2) ?: return LunaDeviceStatus())
            val screen = o.bytes(180)
            return LunaDeviceStatus(
                battery = o.bytes(11)?.let(LunaBattery::parse), storage = o.bytes(20)?.let(LunaStorage::parse),
                storageList = o.all(176).map(LunaStorage::parse), cardLocationLastUpdate = o.u(177),
                screenBattery = screen?.let(LunaBattery::parse), screenConnection = screen?.let { LunaProto(it).u(3, 0) },
                photoSubMode = o.u(40), videoSubMode = o.u(41),
            )
        }
    }
}

/** `CameraCaptureState`: 0 idle, 1 recording, 4 photo, 32 gimbal pano. */
internal data class LunaCaptureStatus(val state: Long, val captureSeconds: Long, val submode: Long, val panoFramesTotal: Long = 0, val panoFramesDone: Long = 0) {
    val isRecording get() = state in recordingStates
    val isIdle get() = state == 0L

    companion object {
        /** Source-backed video-family states (1 is Observed). */
        val recordingStates = listOf(1, 2, 7, 12, 13, 17, 18, 20, 21, 22, 23, 24, 26, 29, 30).map(Int::toLong).toSet()

        /** cmd 15 reply: `GetCurrentCaptureStatusResp { CameraCaptureStatus status = 1 }`. */
        fun fromResponse(data: ByteArray): LunaCaptureStatus {
            val m = LunaProto(LunaProto(data).bytes(1) ?: ByteArray(0))
            return LunaCaptureStatus(m.u(1, 0), m.u(2, 0), m.u(10, 0))
        }

        /** Notification 8208 body: `CaptureStatus` (different field numbers). */
        fun fromNotification(data: ByteArray) = LunaProto(data).let { LunaCaptureStatus(it.u(1, 0), it.u(2, 0), it.u(7, 0), it.u(17, 0), it.u(18, 0)) }
    }
}

/**
 * Deep Track result, media subtype 0x85 with every video frame (fw 1.1.15 official-app capture):
 * `{1: ms, 2: state, 3: 0, 4: {1 x, 2 y, 3 w, 4 h}}` float32, top-left preview fractions.
 * State 2 tracking, 3 lost, 5 idle. Swift `LunaTrackFrame`.
 */
internal data class LunaTrackFrame(val state: Long, val x: Double, val y: Double, val width: Double, val height: Double) {
    val shared: CameraTrackFrame? get() = when (state) {
        2L -> CameraTrackState.TRACKING
        3L -> CameraTrackState.LOST
        5L -> CameraTrackState.IDLE
        else -> null
    }?.let { CameraTrackFrame(it, x, y, width, height) }

    companion object {
        fun parse(data: ByteArray): LunaTrackFrame {
            val message = LunaProto(data)
            val box = LunaProto(message.bytes(4) ?: ByteArray(0))
            // Proto3 omits zero floats.
            return LunaTrackFrame(message.u(2, 0), box.float(1) ?: 0.0, box.float(2) ?: 0.0, box.float(3) ?: 0.0, box.float(4) ?: 0.0)
        }
    }
}

/** Unsolicited camera messages (codes >= 8192) the backend acts on. */
internal sealed class LunaNotification {
    data class Battery(val battery: LunaBattery) : LunaNotification()           // 8195, 8196 low
    data class Storage(val cardState: Long, val location: Long) : LunaNotification() // 8198
    data class CaptureStopped(val errorCode: Long) : LunaNotification()        // 8201
    data class Capture(val status: LunaCaptureStatus) : LunaNotification()     // 8208
    data class SubMode(val photo: Long, val video: Long) : LunaNotification() { // 8275
        val shootingMode get() = LunaShootingMode.from(photo, video)
    }
    data class PhotographyChanged(val settings: LunaPhotographySettings) : LunaNotification() // 8293, 8334
    data class Gimbal(val status: LunaGimbalStatus) : LunaNotification()       // 8302
    data class Tracking(val state: Long, val endReason: Long) : LunaNotification() // 8315
    data class Unknown(val code: Int) : LunaNotification()

    companion object {
        fun parse(code: Int, body: ByteArray): LunaNotification {
            val m = LunaProto(body)
            return when (code) {
                8195, 8196 -> Battery(LunaBattery.parse(m.bytes(1) ?: ByteArray(0)))
                8198 -> Storage(m.u(1, 0), m.u(2, 0))
                8201 -> CaptureStopped(m.u(1, 0))
                8208 -> Capture(LunaCaptureStatus.fromNotification(body))
                8275 -> SubMode(m.u(1, 0), m.u(2, 0))
                8293, 8334 -> PhotographyChanged(LunaPhotographySettings.parse(body))
                8302 -> Gimbal(LunaGimbalStatus.parse(body))
                8315 -> Tracking(m.u(1, 0), m.u(2, 0))
                else -> Unknown(code)
            }
        }
    }
}

/** Subset of `ExtraMetadata` (cmd 38 FileInfo.metadata). */
internal data class LunaFileMetadata(
    /** Local wall time as decimal yyyyMMddHHmmss. */
    val creationStamp: Long? = null,
    val fileSize: Long? = null,
    val durationSeconds: Long? = null,
    val durationMilliseconds: Long? = null,
    val width: Int? = null,
    val height: Int? = null,
    val frameRate: Long? = null,
    val gammaMode: String? = null,
    val subMediaType: Long? = null,
    val codec: Long? = null,
    /** 61 `AudioModeType` the clip was recorded with, see [LunaAudioMode]. */
    val audioModeRaw: Long? = null,
) {
    val audioMode: LunaAudioMode? get() = LunaAudioMode.entries.firstOrNull { it.raw == audioModeRaw }

    companion object {
        fun parse(data: ByteArray): LunaFileMetadata {
            val m = LunaProto(data)
            val size = m.bytes(19)?.let { LunaProto(it) }
            return LunaFileMetadata(
                m.u(7), m.u(9), m.u(10), m.u(93), size?.u(1, 0)?.toInt(), size?.u(2, 0)?.toInt(), m.u(20),
                m.text(22), m.bytes(26)?.let { LunaProto(it).u(1, 0) }, m.u(132), m.u(61),
            )
        }
    }
}

/**
 * Camera-screen Audio Mode as `ExtraMetadata.audio_mode` (61) of a recorded clip. The phone
 * protocol cannot read or set it on fw 1.1.15 (docs/research/luna-fw-1.1.15-verification.md, Audio).
 */
internal enum class LunaAudioMode(val raw: Long, val label: String) {
    WIND_REDUCTION(20, "Wind Reduction"), // AI_WINDREDUCTION_INNER, observed on fw 1.1.15
    VOICE_ENHANCEMENT(21, "Voice Enhancement"), // SPEECH_ENHANCE_INNER, inferred from the schema
    ORIGINAL_AUDIO(24, "Original Audio"), // HIFI, inferred from the schema
}

/** One camera file; [uri] is the absolute camera path used for cmd 11/12 and HTTP. */
internal data class LunaMediaFile(val uri: String, val metadata: LunaFileMetadata? = null) {
    val isVideo get() = uri.lowercase().endsWith(".mp4")
    val isProxy get() = uri.lowercase().endsWith(".lrv")

    /** Observed: `VID_<stamp>.mp4` has proxy `LRV_<stamp>.lrv` in the same directory. */
    val proxyUri: String?
        get() {
            if (!isVideo) return null
            val name = uri.substringAfterLast('/')
            if (!name.startsWith("VID_")) return null
            return uri.substringBeforeLast('/') + "/LRV_" + name.removePrefix("VID_").substringBeforeLast('.') + ".lrv"
        }

    companion object {
        /** cmd 13 reply `GetFileListResp`: uris + total_count. */
        fun list(response: ByteArray): Pair<List<String>, Long> {
            val m = LunaProto(response)
            return m.all(1).map { it.toString(Charsets.UTF_8) } to m.u(2, 0)
        }

        /** cmd 38 reply `FileInfo_List`: repeated { file_path, metadata }. */
        fun infoList(response: ByteArray): List<LunaMediaFile> = LunaProto(response).all(1).map {
            val info = LunaProto(it)
            LunaMediaFile(checkNotNull(info.text(1)) { "Missing file path" }, info.bytes(2)?.let(LunaFileMetadata::parse))
        }
    }
}

/** cmd 11 extra_type 2 reply: raw 40-byte LE header [1, total, a, b, width, height, 0...] then NV12. */
internal class LunaThumbnail(val width: Int, val height: Int, val nv12: ByteArray) {
    /** ARGB pixels, BT.709 limited range (same decode as the iOS converter). */
    fun argb(): IntArray {
        val out = IntArray(width * height)
        val luma = width * height
        fun clamp(v: Double) = v.roundToInt().coerceIn(0, 255)
        for (y in 0 until height) for (x in 0 until width) {
            val c = luma + (y / 2) * width + (x / 2) * 2
            val yy = 1.164384 * ((nv12[y * width + x].toInt() and 255) - 16)
            val cb = (nv12[c].toInt() and 255) - 128.0
            val cr = (nv12[c + 1].toInt() and 255) - 128.0
            val r = clamp(yy + 1.792741 * cr)
            val g = clamp(yy - 0.213249 * cb - 0.532909 * cr)
            val b = clamp(yy + 2.112402 * cb)
            out[y * width + x] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
        }
        return out
    }

    companion object {
        const val HEADER_SIZE = 40

        fun parse(data: ByteArray): LunaThumbnail {
            require(data.size >= HEADER_SIZE && LunaWire.intAt(data, 0) == 1 && LunaWire.intAt(data, 4) == data.size) { "Unexpected thumbnail" }
            val width = LunaWire.intAt(data, 16)
            val height = LunaWire.intAt(data, 20)
            require(width > 0 && height > 0 && width % 2 == 0 && height % 2 == 0 && data.size - HEADER_SIZE == width * height * 3 / 2) { "Unexpected thumbnail" }
            return LunaThumbnail(width, height, data.copyOfRange(HEADER_SIZE, data.size))
        }
    }
}
