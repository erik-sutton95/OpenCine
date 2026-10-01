package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.CameraColorProfile
import com.opencapture.opencine.insta360.shell.CameraExposure
import com.opencapture.opencine.insta360.shell.CameraFocusMode
import com.opencapture.opencine.insta360.shell.CameraGimbalMode
import com.opencapture.opencine.insta360.shell.CameraGimbalSpeed
import com.opencapture.opencine.insta360.shell.CameraMediaItem
import com.opencapture.opencine.insta360.shell.CameraReadout
import com.opencapture.opencine.insta360.shell.CameraRecordFormat
import com.opencapture.opencine.insta360.shell.CameraShootingMode
import com.opencapture.opencine.insta360.shell.CameraStorage

/** Luna numbers to the neutral core-api vocabulary. The shell maps that onto its own status. */
internal object LunaReadout {
    /**
     * Every RecordResolution the camera stored in normal video on fw 1.1.15, in the iOS
     * `LunaShellMapping.videoFormatValues` order (docs/research/luna-fw-1.1.15-verification.md).
     */
    val videoFormatValues = listOf<Long>(
        210, 211, 154, // 8K 24/25/30
        219, 212, 213, // 8K 2.35:1
        49, 48, 24, 258, 92, 23, 220, 214, // 4K 24...120
        440, 439, 438, 437, 436, 435, 434, 433, // 4K 2.35:1
        248, 247, 246, 331, 245, 244, 243, 242, // 2.7K 2688x1520
        53, 52, 29, 260, 81, 40, 150, 28, 26, 27, // 1080p 24...240
        126, 125, 124, // 9:16 4K
        455, 454, 453, 452, 451, 450, // 9:16 3K
        445, 444, 443, 468, 442, 441, // 9:16 2.7K (443/444 from the fw 1.1.15 official app)
        119, 120, 121, 448, 447, 446, // 1:1 3K 3072x3072, fw 1.1.15 official app
        85, 71, 64, 298, 82, 68, // 9:16 1080
    )

    val shootingModes = mapOf(
        LunaShootingMode.VIDEO to CameraShootingMode.VIDEO, LunaShootingMode.TIMELAPSE to CameraShootingMode.TIMELAPSE,
        LunaShootingMode.TIME_SHIFT to CameraShootingMode.TIMESHIFT, LunaShootingMode.SLOW_MOTION to CameraShootingMode.SLOW_MOTION,
        LunaShootingMode.PURE_VIDEO to CameraShootingMode.PURE_VIDEO, LunaShootingMode.PHOTO to CameraShootingMode.PHOTO,
        LunaShootingMode.PANO to CameraShootingMode.PANO,
    )
    val colors = mapOf(1L to CameraColorProfile.STANDARD, 2L to CameraColorProfile.LOG, 3L to CameraColorProfile.VIVID,
        4L to CameraColorProfile.HDR, 5L to CameraColorProfile.DOLBY_VISION)
    val gimbalModes = mapOf(1L to CameraGimbalMode.FPV, 2L to CameraGimbalMode.ROLL_LOCK, 3L to CameraGimbalMode.ROLL_TILT_LOCK,
        4L to CameraGimbalMode.FPV_VERTICAL, 5L to CameraGimbalMode.LOCK, 6L to CameraGimbalMode.STABILIZED_VERTICAL)
    val gimbalSpeeds = mapOf(1L to CameraGimbalSpeed.SLOW, 2L to CameraGimbalSpeed.MEDIUM, 3L to CameraGimbalSpeed.FAST,
        4L to CameraGimbalSpeed.SENSITIVE)
    /** Option 93 values the official app offers; it never offers 0, 2, 4, 5 (OFF, MACRO, CONTINUOUS_PICTURE, EDOF). */
    val focusModes = mapOf(1L to CameraFocusMode.SINGLE, 3L to CameraFocusMode.CONTINUOUS, 6L to CameraFocusMode.PRODUCT_SHOWCASE)

    fun <K, V> Map<K, V>.key(value: V): K = entries.first { it.value == value }.key

    fun format(raw: Long): CameraRecordFormat? =
        LunaVideoResolution.of(raw)?.let { CameraRecordFormat(raw, it.width, it.height, it.framesPerSecond) }

    private fun exposure(e: LunaExposure?) = e?.let { CameraExposure(it.program.toInt(), it.iso.toInt(), it.shutterSeconds) }

    fun readout(settings: LunaPhotographySettings?, device: LunaDeviceStatus?, capture: LunaCaptureStatus?): CameraReadout {
        val storages = device?.let { d -> d.storageList.ifEmpty { listOfNotNull(d.storage) } }.orEmpty()
        return CameraReadout(
            batteryPercent = device?.battery?.percent?.toInt(),
            charging = device?.battery?.isCharging,
            storages = storages.map { CameraStorage(it.location.toInt(), it.isUsable, it.freeBytes, it.totalBytes) },
            shootingMode = device?.shootingMode?.let(shootingModes::get),
            // Photo and pano capture states say nothing about video recording: unknown.
            recording = capture?.let { if (it.isRecording) true else if (it.isIdle) false else null },
            captureSeconds = capture?.captureSeconds?.toInt() ?: 0,
            videoExposure = exposure(settings?.videoExposure),
            stillExposure = exposure(settings?.stillExposure),
            exposureBiasTenths = settings?.exposureBiasTenths,
            whiteBalanceKelvin = settings?.whiteBalanceKelvin?.toInt(),
            color = settings?.colorMode?.let(colors::get),
            recordFormat = settings?.recordResolution?.let(::format),
            recordFormats = if (settings == null) emptyList() else videoFormatValues.mapNotNull(::format),
            zoom = settings?.zoom,
            gimbalMode = settings?.gimbal?.let { gimbalModes[it.mode] },
            gimbalSpeed = settings?.gimbal?.let { gimbalSpeeds[it.followSpeed] },
            focusMode = settings?.afMode?.let(focusModes::get),
            faceMetering = settings?.faceMetering,
        )
    }

    fun mediaItem(file: LunaMediaFile): CameraMediaItem {
        val meta = file.metadata
        val duration = meta?.durationMilliseconds?.let { ((it + 500) / 1000).toInt() } ?: meta?.durationSeconds?.toInt() ?: 0
        return CameraMediaItem(
            path = file.uri, proxyPath = file.proxyUri, sizeBytes = meta?.fileSize ?: 0, durationSeconds = duration,
            width = meta?.width?.takeIf { it > 0 }, height = meta?.height?.takeIf { it > 0 }, fps = meta?.frameRate?.toInt(),
            gamma = meta?.gammaMode,
        )
    }
}
