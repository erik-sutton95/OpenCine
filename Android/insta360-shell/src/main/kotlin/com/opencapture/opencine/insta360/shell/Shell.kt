// The Insta360 app shell contract: what an OpenInstaCine-style monitor shell calls and what the
// Luna adapter implements (discovery, connection, picture, media, Luna live controls). Kotlin twin
// of the Swift `CameraBackend` seam in Insta360Apple. Not OpenCineCore: the values are Luna-shaped
// (shooting/gimbal/focus modes, program and storage codes). Commands and reported camera state go
// through OpenCineCore `CameraSession` ([CoreSessionSource]), not through this contract.
// Moved from OpenInstaCine `:core-api` (package com.opencapture.openpocketcine.core).
package com.opencapture.opencine.insta360.shell

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.media.CameraMediaService
import com.opencapture.opencine.media.MediaByteSink
import com.opencapture.opencine.media.MediaTransferReceipt

/** Operator-visible connection stage the shell renders. Same constants as OpenPocketCine's so the shared shell code reads both. */
public enum class ConnectionPhase { IDLE, SCANNING, CONNECTING_GATT, PAIRING, AWAITING_APPROVAL, READING_WIFI_CREDS, JOINING_WIFI, OPENING_DATALINK, LIVE, FAILED }
public enum class CameraCapability { LIVE_VIDEO, CAMERA_SETTINGS, RECORD, GIMBAL, FOCUS, CAMERA_MEDIA, AUDIO, ZOOM, TRACKING, METERED_EV, NATIVE_ISO_HOP }
public data class CameraIdentity(public val id: String, public val advertisedName: String, public val modelName: String)
public data class CameraSnapshot(public val firmware: String? = null, public val batteryPercent: Int? = null, public val previewWidth: Int = 1280, public val previewHeight: Int = 720, public val previewFps: Int = 25)
public data class EncodedVideoFrame(
    public val annexB: ByteArray, public val timestampMicros: Long,
    /** Captured native connection; absent when the backend cannot identify its source. */
    public val connectionGeneration: Long? = null,
)

/** Backend owns camera protocol and connection I/O. Shared monitor owns decode and UI. */
public interface CameraBackend {
    public val capabilities: Set<CameraCapability>
    public val phase: StateFlow<ConnectionPhase>
    public val found: StateFlow<List<CameraIdentity>>
    public val connected: StateFlow<CameraIdentity?>
    public val snapshot: StateFlow<CameraSnapshot>
    public val failure: StateFlow<String?>
    public val radioOn: StateFlow<Boolean>
    public val joinedSSID: StateFlow<String?>
    public val frames: Flow<EncodedVideoFrame>
    /** The current native frame source, changed before a replacement connection starts. */
    public val frameConnectionGeneration: Long? get() = null
    public fun startScan()
    public fun connect(id: String)
    public fun disconnect()
    public fun close()
    public fun sceneActive(active: Boolean)
}

/**
 * A backend whose camera commands and reported camera state go through OpenCineCore. Recording,
 * ISO, shutter and white balance are not on [CameraControls]: they are common intents submitted
 * to the session, which reports their outcome honestly (CORE-02).
 */
public interface CoreSessionSource {
    /** A new session for the next connection; the previous one closes as replaced. */
    public fun openSession(): com.opencapture.opencine.core.CameraSession
}

/** Optional producer bound to the exact session in ConnectedCamera.services. */
public interface CameraMediaServiceSource {
    public fun mediaService(session: CameraSessionID): CameraMediaService? = null
}

/** Existing app HTTP driver; the source supplies addressing, the driver streams to owned staging. */
public interface LunaMediaTransferPort {
    public suspend fun transfer(url: String, sink: MediaByteSink): MediaTransferReceipt
    public suspend fun transfer(url: String, expectedByteCount: Long?, sink: MediaByteSink): MediaTransferReceipt = transfer(url, sink)
}

/**
 * Optional live camera controls. A backend implements this only for commands it has verified;
 * the shared session gates each control on [CameraBackend.capabilities]. Coordinates are
 * normalized 0..1 in the displayed live frame. Each call returns false when the camera rejected
 * the command or no control link is up. Members have no defaults: an implementation states what
 * it does not support instead of inheriting a silent `false`.
 */
public interface CameraControls {
    public val zoomRange: ClosedFloatingPointRange<Double>
    public suspend fun setZoom(factor: Double): Boolean
    /** Rate stick, each axis -1..1. A zero stick releases the gimbal. */
    public suspend fun gimbalStick(pan: Double, tilt: Double): Boolean
    public suspend fun gimbalRecenter(): Boolean
    public suspend fun gimbalFlip(): Boolean
    /** [x], [y]: the tapped point; the backend sizes its focus region around it and keeps it in frame. */
    public suspend fun tapFocus(x: Double, y: Double): Boolean
    public suspend fun startTracking(x: Double, y: Double, width: Double, height: Double): Boolean
    public suspend fun stopTracking(): Boolean

    // Capture and settings outside the CORE-02 slice. Readout fields not reported stay null.
    public val readout: StateFlow<CameraReadout>
    public suspend fun takePhoto(): Boolean
    public suspend fun setExposureBias(thirds: Int): Boolean
    public suspend fun setColorProfile(profile: CameraColorProfile): Boolean
    /** [id] is a [CameraRecordFormat.id] from the readout. */
    public suspend fun setRecordFormat(id: Long): Boolean
    public suspend fun setShootingMode(mode: CameraShootingMode): Boolean
    public suspend fun setGimbalMode(mode: CameraGimbalMode): Boolean
    public suspend fun setGimbalSpeed(speed: CameraGimbalSpeed): Boolean
    public suspend fun setFocusMode(mode: CameraFocusMode): Boolean
    /** True Face Priority metering, false Matrix. */
    public suspend fun setFaceMetering(on: Boolean): Boolean
    /** Re-read settings shortly after a burst of writes. */
    public fun requestSettingsRefresh()
    /** The camera's own subject tracking, from the live stream; only changes are delivered. */
    public val trackFrames: Flow<CameraTrackFrame>
    /** Camera-side notices (Luna 8315 Deep Track state, 8201 capture stopped). */
    public val notices: Flow<CameraNotice>
    /** Absolute head angle in the handle frame (Luna GET_ANGLE), or null when unavailable. */
    public suspend fun gimbalAngle(): CameraGimbalAngle?
    /** Aim the head at an absolute handle-frame angle (Luna SET_ANGLE); the latest request wins. */
    public suspend fun gimbalSetAngle(pitch: Double, yaw: Double): Boolean
    /** Head world pitch from the camera IMU in degrees (up positive), or null without a sample in the last 0.3 s. */
    public val gimbalHeadPitch: Double?
}

/** Degrees: pitch up positive, yaw as the camera reports it (-180..180). */
public data class CameraGimbalAngle(public val pitch: Double, public val yaw: Double)

public enum class CameraTrackState { TRACKING, LOST, IDLE }
public sealed class CameraNotice {
    /** The camera's Deep Track state notice: active (locked) or ended, e.g. cancelled on the camera. */
    public data class Tracking(public val active: Boolean) : CameraNotice()
    /** Capture stopped on the camera; a non-zero [errorCode] is a camera-side stop. */
    public data class CaptureStopped(public val errorCode: Long) : CameraNotice()
}
/** Tracking state and the camera's box, top-left fractions of the preview. */
public data class CameraTrackFrame(public val state: CameraTrackState, public val x: Double, public val y: Double, public val width: Double, public val height: Double)

public enum class CameraShootingMode { VIDEO, TIMELAPSE, TIMESHIFT, SLOW_MOTION, PURE_VIDEO, PHOTO, PANO }
public enum class CameraColorProfile { STANDARD, LOG, VIVID, HDR, DOLBY_VISION }
public enum class CameraGimbalMode { FPV, ROLL_LOCK, ROLL_TILT_LOCK, FPV_VERTICAL, LOCK, STABILIZED_VERTICAL }
public enum class CameraGimbalSpeed { SLOW, MEDIUM, FAST, SENSITIVE }
public enum class CameraFocusMode { SINGLE, CONTINUOUS, PRODUCT_SHOWCASE }

/** [program]: 0 auto, 1 ISO priority, 2 shutter priority, 3 manual, 4 adaptive, 5 full auto. ISO 0 / shutter 0 = camera chooses. */
public data class CameraExposure(public val program: Int, public val iso: Int, public val shutterSeconds: Double)
/** One recordable frame size and rate; [id] is the backend's own value for it. */
public data class CameraRecordFormat(public val id: Long, public val width: Int, public val height: Int, public val fps: Double)
/** [location] 2 camera inner storage, 3 SD card. */
public data class CameraStorage(public val location: Int, public val usable: Boolean, public val freeBytes: Long, public val totalBytes: Long)

/** What the camera last reported. Null fields have not been reported yet (unknown, not false). */
public data class CameraReadout(
    public val batteryPercent: Int? = null,
    public val charging: Boolean? = null,
    public val storages: List<CameraStorage> = emptyList(),
    public val shootingMode: CameraShootingMode? = null,
    /** Video recording; null while no capture state was reported or the state is not a video one. */
    public val recording: Boolean? = null,
    public val captureSeconds: Int = 0,
    public val videoExposure: CameraExposure? = null,
    public val stillExposure: CameraExposure? = null,
    public val exposureBiasTenths: Int? = null,
    /** 0 is auto. */
    public val whiteBalanceKelvin: Int? = null,
    public val color: CameraColorProfile? = null,
    public val recordFormat: CameraRecordFormat? = null,
    /** Formats the operator may pick. Empty until settings are read. */
    public val recordFormats: List<CameraRecordFormat> = emptyList(),
    public val zoom: Double? = null,
    public val gimbalMode: CameraGimbalMode? = null,
    public val gimbalSpeed: CameraGimbalSpeed? = null,
    /** Null also when the camera reports a mode the shell does not offer. */
    public val focusMode: CameraFocusMode? = null,
    /** True Face Priority metering, false Matrix. */
    public val faceMetering: Boolean? = null,
) {
}

/** One camera file. [path] addresses it for thumbnail, delete and HTTP. */
public data class CameraMediaItem(
    public val path: String,
    public val proxyPath: String? = null,
    public val sizeBytes: Long = 0,
    public val durationSeconds: Int = 0,
    public val width: Int? = null,
    public val height: Int? = null,
    public val fps: Int? = null,
    /** Camera's gamma name, e.g. "standard" or "log". */
    public val gamma: String? = null,
)

/** Optional camera media over the control link. Every call throws when it fails. */
public interface CameraMediaStore {
    public suspend fun listMedia(): List<CameraMediaItem>
    public suspend fun thumbnailJpeg(path: String): ByteArray
    public suspend fun deleteMedia(path: String)
    /** Stop live video while the album is open so HTTP has the link. */
    public suspend fun pauseLive()
    public suspend fun resumeLive()
}
