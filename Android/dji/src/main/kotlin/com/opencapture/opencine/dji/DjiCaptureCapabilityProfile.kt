package com.opencapture.opencine.dji

import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.vocabulary.*

fun CameraModel.Companion.looksLikePocket3(name: String): Boolean {
    val n = name.lowercase().replace(" ", "")
    return n.contains("pocket3") || n.contains("muse")
}

fun CameraModel.Companion.looksLikePocket4Pro(name: String): Boolean {
    val n = name.lowercase().replace(" ", "")
    return n.contains("pocket4p")
}

/** SlowMo `0x02/0x18` trailer context. Regular Pocket 4 stays unqualified. */
fun CameraModel.Companion.supportsSlowMoFormatTrailer(name: String): Boolean =
    looksLikePocket3(name) || looksLikePocket4Pro(name)

/** Osmo Action 6 (BLE `0x0018`). Handbook `devices/action-6/`. */
fun CameraModel.Companion.looksLikeAction6(name: String): Boolean =
    name.lowercase().replace(" ", "").contains("action6")

fun CameraModel.Companion.looksLikeNano(name: String, family: String = ""): Boolean {
    if (family == "nano") return true
    return name.lowercase().contains("nano")
}

/**
 * Rec.709 / HDR / D-Log M Auto ISO range floor. Pocket 3 and Pocket 4
 * start at 50 (DJI spec; #180). Pocket 4 Pro wide is 100 (captured
 * `camcap_iso_auto_max`). Unknown bodies keep 100.
 */
fun CameraModel.Companion.isoAutoRangeFloorFor(name: String): Int {
    val n = name.lowercase().replace(" ", "")
    if (n.contains("pocket4p") || n.contains("4pro")) return 100
    if (n.contains("pocket4") || n.contains("pocket3") || n.contains("muse")) return 50
    return 100
}

/** DJI color wheel. D-Log2 is Pocket 4 Pro only. Pocket 3 is HLG / D-Log M. */
fun CameraModel.Companion.colorModesFor(name: String, family: String): List<Int> {
    if (family == "nano") {
        return listOf(CameraCommands.COLOR_NORMAL, CameraCommands.COLOR_NORMAL10, CameraCommands.COLOR_DLOG_M)
    }
    if (looksLikeAction6(name)) {
        return listOf(CameraCommands.COLOR_NORMAL10, CameraCommands.COLOR_DLOG_M)
    }
    val n = name.lowercase().replace(" ", "")
    if (n.contains("pocket4p") || n.contains("4pro")) {
        return listOf(
            CameraCommands.COLOR_NORMAL,
            CameraCommands.COLOR_HDR,
            CameraCommands.COLOR_DLOG,
            CameraCommands.COLOR_DLOG2,
        )
    }
    if (n.contains("pocket4")) {
        return listOf(
            CameraCommands.COLOR_NORMAL,
            CameraCommands.COLOR_HDR,
            CameraCommands.COLOR_DLOG,
        )
    }
    if (n.contains("pocket3") || n.contains("muse")) {
        return listOf(
            CameraCommands.COLOR_NORMAL,
            CameraCommands.COLOR_HDR,
            CameraCommands.COLOR_DLOG_M,
        )
    }
    return listOf(
        CameraCommands.COLOR_NORMAL,
        CameraCommands.COLOR_HDR,
        CameraCommands.COLOR_DLOG,
    )
}

fun CameraModel.Companion.zoomStopsFor(name: String, family: String): List<Double> =
    namedZoomStops(name) ?: if (family == "pocket") listOf(1.0, 2.0, 4.0) else listOf(1.0)

/**
 * The zoom stops a named body cycles whatever a saved record says (Swift
 * `DJICaptureCapabilityProfile.make`); null for a body the name does not identify.
 */
internal fun namedZoomStops(name: String): List<Double>? {
    val n = name.lowercase().replace(" ", "")
    if (n.contains("pocket4p") || n.contains("4pro")) return listOf(1.0, 3.0, 6.0, 12.0)
    if (n.contains("pocket4") || n.contains("pocket3") || n.contains("muse")) return listOf(1.0, 2.0, 4.0)
    return null
}

val CameraModel.Companion.default: CameraModel
    get() {
        val model = CameraModel(name = "DJI Osmo camera", family = "pocket", pairingToken = "osmo",
            supportsFocusMode = true, supportsTapFocus = true, hasGimbal = true, supportsZoom = true,
            tcpPoke = true, usesCapturedLiveEnable = true, sendsLiveViewPrepare = true,
            zoomStops = listOf(1.0, 2.0, 4.0))
        return model.copy(captureProfile = DjiCaptureCapabilityProfile.make(model))
    }

/**
     * Pocket 3 digital-zoom ceiling for this FORMAT, or `null` for a byte the
     * catalog does not name.
     *
     * The limit tracks the capture size class, not the aspect; a bigger frame
     * leaves less crop headroom. Measured on a body by asking past the ceiling
     * and reading `cam_fov` `zoomLens` back: the camera clamps to its own max
     * rather than refusing, so an over-ask reports the true limit. `0x0A`,
     * `0x69` (4x), `0x2D`, `0x6A` (3x), `0x10`, `0x6B` (2x) are measured; the
     * rest inherit from a measured sibling in the same size class.
     */
val VideoResolution.pocket3ZoomMax: Double?
        get() =
            when (rawValue) {
                0x0A, 0x0C, 0x42, 0x69 -> 4.0 // 1080; 0x0A, 0x69 measured
                0x2D, 0x43, 0x5F -> 3.0 // 2.7K; 0x2D measured
                0x6A -> 3.0 // 2160; measured
                0x10, 0x67, 0x7D -> 2.0 // 4K; 0x10 measured
                0x6B, 0x6C -> 2.0 // 3K; 0x6B measured
                else -> null
            }



object DjiCaptureCapabilityProfile {
    fun make(model: CameraModel): CameraCaptureProfile {
        val modes = CameraCommands.shootingModeCarousel(model.name)
        val labels = CameraLabelProfile(
            shootingModeLabels = if (CameraModel.looksLikePocket3(model.name))
                mapOf(CameraCommands.SHOOT_SUPER_NIGHT to "Low-Light") else emptyMap(),
            colorModeLabels = if (model.family == "nano") mapOf(
                CameraCommands.COLOR_NORMAL to "Normal 8-bit",
                CameraCommands.COLOR_DLOG_M to "D-Log M 10-bit")
                else if (model.family == "pocket") mapOf(CameraCommands.COLOR_DLOG_M to "D-Log M")
                else emptyMap(),
            colorModes = CameraModel.colorModesFor(model.name, model.family), shootingModes = modes,
        )
        val restricted = setOf(CameraCommands.SHOOT_SLOWMO, CameraCommands.SHOOT_TIMELAPSE,
            CameraCommands.SHOOT_SUPER_NIGHT)
        val ceilings = if (CameraModel.looksLikePocket3(model.name))
            (0..255).mapNotNull { raw -> VideoResolution(raw).pocket3ZoomMax?.let { VideoResolution(raw) to it } }.toMap()
            else emptyMap()
        val fallbacks = if (CameraModel.looksLikePocket3(model.name)) mapOf(
            CameraCommands.SHOOT_VIDEO to pocket3VideoFormats,
            CameraCommands.SHOOT_SLOWMO to pocket3SlowMoFormats,
            CameraCommands.SHOOT_SUPER_NIGHT to pocket3LowLightFormats,
        ) else emptyMap()
        return CameraCaptureProfile(labels = labels, supportsFocusMode = model.supportsFocusMode,
            supportsTapFocus = model.supportsTapFocus, supportsAperture = model.supportsAperture,
            hasGimbal = model.hasGimbal, supportsZoom = model.supportsZoom,
            isoAutoRangeFloor = CameraModel.isoAutoRangeFloorFor(model.name), videoFormatFallbacks = fallbacks,
            zoom = CameraZoomProfile(stops = namedZoomStops(model.name) ?: model.zoomStops, restrictedModes = restricted,
                restrictedStops = if (CameraModel.looksLikePocket4Pro(model.name)) listOf(1.0, 3.0) else listOf(1.0),
                resolutionCeilings = ceilings), looks = DjiCameraLUTProfile.make(model),
            controls = controls(model), nativeISO = nativeISO(model))
    }

    /**
     * Every Osmo body answers the Auto ISO ceiling (`0x02/0x8E` pid `0x000F`) and takes the native
     * ISO hop on a colour change (the hop itself only moves between curves with a base ISO). A
     * drone declares neither (unknown). Swift `DJICaptureCapabilityProfile.nativeISO`.
     */
    internal fun nativeISO(model: CameraModel): CaptureNativeISOCapabilities =
        if (model.isDrone) CaptureNativeISOCapabilities() else CaptureNativeISOCapabilities(hop = true, ceiling = true)

    /**
     * Families no setting descriptor carries (Swift `DJICaptureCapabilityProfile.controls`). Every
     * Osmo body records video in a format and colour mode the camera lists, takes photos, serves
     * its card and deletes from it, and has no built-in ND. Face metering and audio input follow
     * nothing declared here. Multiview lists the bodies the captured preview policy qualifies
     * (Swift `MulticamSupport.appears` and `hasPreview`); a listed body without a captured preview
     * is experimental, so unknown.
     */
    fun controls(model: CameraModel): Map<ControlFamily, SupportStatus> {
        if (model.isDrone) return emptyMap()
        val appears = model.name.lowercase().contains("osmo") || model.family != "other"
        val compact = model.name.lowercase().replace(" ", "")
        val preview = appears && model.usesCapturedLiveEnable &&
            (CameraModel.looksLikePocket3(model.name) || compact.contains("pocket4") || model.family == "nano")
        val multiview = when {
            !appears -> SupportStatus.UNSUPPORTED
            preview -> SupportStatus.SUPPORTED
            else -> SupportStatus.UNKNOWN
        }
        return mapOf(
            ControlFamily.ND_FILTER to SupportStatus.UNSUPPORTED,
            ControlFamily.RECORDING_FORMAT to SupportStatus.SUPPORTED,
            ControlFamily.CODEC_COLOR to
                if (CameraModel.colorModesFor(model.name, model.family).isEmpty()) SupportStatus.UNKNOWN else SupportStatus.SUPPORTED,
            ControlFamily.PHOTO to SupportStatus.SUPPORTED,
            ControlFamily.MEDIA to SupportStatus.SUPPORTED,
            ControlFamily.MEDIA_DELETE to SupportStatus.SUPPORTED,
            ControlFamily.MULTIVIEW to multiview,
        )
    }
        /** Accepted Pocket 3 Video `0x02/0x18` pairs. 9:16 was body Lock Portrait only. */
        private val pocket3VideoFormats = listOf(
            VideoResolution.P1080, VideoResolution.P2_7K, VideoResolution.P4K,
            VideoResolution.P1080_1X1, VideoResolution.P2160_1X1, VideoResolution.P3K_1X1,
        ).flatMap { res -> VideoFrameRate.labeledVideo.map { rate -> VideoFormat(res, rate) } }

        /** Documented Pocket 3 SlowMo menu. 4K240 is not in this fallback. */
        private val pocket3SlowMoFormats = listOf(
            VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS100),
            VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS120),
            VideoFormat(VideoResolution.P2_7K, VideoFrameRate.FPS120),
            VideoFormat(VideoResolution.P1080, VideoFrameRate.FPS120),
            VideoFormat(VideoResolution.P1080, VideoFrameRate.FPS240),
        )

        /** Pocket 3 Low-Light (`0x28`): 1080/4K at 24/25/30. No 2.7K or square. */
        private val pocket3LowLightFormats =
            listOf(VideoResolution.P1080, VideoResolution.P4K).flatMap { res ->
                listOf(VideoFrameRate.FPS24, VideoFrameRate.FPS25, VideoFrameRate.FPS30)
                    .map { rate -> VideoFormat(res, rate) }
            }

}
