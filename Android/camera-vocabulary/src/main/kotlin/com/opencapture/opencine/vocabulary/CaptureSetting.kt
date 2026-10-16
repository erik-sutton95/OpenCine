package com.opencapture.opencine.vocabulary

/**
 * One setting a capture sheet sends to the camera. Every sheet commit goes through this one typed
 * entry; each app routes it to its own session path, so the sheets never name an integration.
 */
sealed interface CaptureSetting {
    /** ISO by camera index; index 0 is Auto. */
    data class IsoIndex(val index: Int) : CaptureSetting
    /** Auto ISO ceiling, as [IsoLimit.rawValue]. */
    data class IsoLimitRaw(val raw: Int) : CaptureSetting
    data class Ev(val thirds: Int) : CaptureSetting
    data class ShutterDenom(val denom: Int) : CaptureSetting
    data class ShutterAngle(val degrees: Double) : CaptureSetting
    /** A Custom Kelvin from the white balance rows or drum. */
    data class WhiteBalance(val kelvin: Int, val tint: Int) : CaptureSetting
    /** Auto from the white balance rows. */
    data object WhiteBalanceAuto : CaptureSetting
    /** A tint from the tint drum: on Auto when [kelvin] is null, else on that Custom Kelvin. */
    data class WhiteBalanceTint(val tint: Int, val kelvin: Int?) : CaptureSetting
    /** Pin the live Auto Kelvin as Custom. */
    data object AutoWhiteBalanceLock : CaptureSetting
    data class Format(val format: VideoFormat) : CaptureSetting
    data class ColorMode(val code: Int) : CaptureSetting
    /** A shooting mode drum label; the app resolves it against its live report and body. */
    data class ShootingMode(val label: String) : CaptureSetting
    data class Aperture(val raw: Int) : CaptureSetting
    data class ExpoMode(val mode: Int) : CaptureSetting
    /** A focus row label (AF-S, AF-C or a track), chosen against the report the sheet showed. */
    data class Focus(val label: String) : CaptureSetting
}

/**
 * What the capture sheets read from the session besides its [CameraStatus]: exposure and white
 * balance locks, the format pin and what the connected session supports. The session keeps these
 * apart from the camera's report, so the host supplies them here and [CameraStatus] never carries
 * a value the camera did not report. Read where needed: [formatPinned] expires on time.
 */
interface CaptureSessionState {
    val aeLocked: Boolean
    /** The locked Custom Kelvin while AWB lock holds. */
    val awbLockKelvin: Int?
    /** Whether AWB lock can pin the live Auto Kelvin now. */
    val awbLockOffered: Boolean
    /** The FORMAT sheet does not reseat while a format change waits for the camera. */
    val formatPinned: Boolean
    val focusModeSupported: Boolean
    val irisSupported: Boolean
    val nativeIsoHopSupported: Boolean
    /** Original hosts remain compatible; new sources preserve unknown declarations explicitly. */
    val nativeISO: CaptureNativeISOCapabilities
        get() = CaptureNativeISOCapabilities(hop = nativeIsoHopSupported)
    /**
     * The integration's one control model for the connected camera (its static body facts merged
     * with the live snapshot). Null keeps the flags above, for hosts that have not adopted it.
     */
    val controlCapabilities: ControlCapabilities? get() = null
}

/**
 * What the shared capture UI reads: the host's [CaptureSessionState.controlCapabilities], else the
 * legacy flags (Swift `ControlCapabilities.overlaying(_:)`). A legacy host's tiles followed its
 * [layout] sections and its sheets the session flags, so [layout] decides focus, iris, audio,
 * zoom and gimbal where it is given. A flag that is off is unknown, never unsupported.
 */
fun CaptureSessionState.controls(layout: com.opencapture.opencine.core.MonitorLayoutCapabilities? = null): ControlCapabilities {
    controlCapabilities?.let { return it }
    fun <T> flag(on: Boolean?): ControlCapability<T> =
        if (on == true) ControlCapability.supported() else ControlCapability.unknown()
    return ControlCapabilities(
        iso = ControlCapability(com.opencapture.opencine.core.SupportStatus.UNKNOWN, offer = ISOOffer(nativeISO = nativeISO)),
        focus = flag(layout?.focus ?: focusModeSupported),
        iris = flag(layout?.iris ?: irisSupported),
        audio = flag(layout?.audio),
        // A legacy host showed its level meter wherever it offered the AUDIO tile.
        liveAudioLevels = flag(layout?.audio),
        zoom = flag(layout?.zoom),
        gimbal = flag(layout?.gimbal),
        headTracking = flag(layout?.headTracking),
    )
}
