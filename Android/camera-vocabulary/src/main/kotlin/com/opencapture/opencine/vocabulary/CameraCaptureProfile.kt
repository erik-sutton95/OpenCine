package com.opencapture.opencine.vocabulary

/** Integration-supplied facts used by shared capture presentation. Null means unknown. */
data class CameraCaptureProfile(
    val labels: CameraLabelProfile = CameraLabelProfile.standard,
    val supportsFocusMode: Boolean? = null,
    val supportsTapFocus: Boolean? = null,
    val supportsAperture: Boolean? = null,
    val hasGimbal: Boolean? = null,
    val supportsZoom: Boolean? = null,
    val isoAutoRangeFloor: Int? = null,
    val videoFormatFallbacks: Map<Int, List<VideoFormat>> = emptyMap(),
    val zoom: CameraZoomProfile? = null,
    val looks: CameraLUTProfile? = null,
    val nativeISO: CaptureNativeISOCapabilities = CaptureNativeISOCapabilities(),
    /**
     * Static support of the families no setting descriptor or flag above carries (ND, face
     * metering, audio input, photo, camera media, clip delete, multiview, ...). A family not
     * listed is unknown. [ControlCapabilities.derive] merges this with the live snapshot.
     */
    val controls: Map<ControlFamily, com.opencapture.opencine.core.SupportStatus> = emptyMap(),
    /**
     * Which live header readout carries the app accent. The default keeps the shooting-mode
     * readout; a body with no shooting-mode readout declares the codec.
     */
    val headerAccent: MonitorHeaderAccent = MonitorHeaderAccent.SHOOTING_MODE,
)

data class CameraZoomProfile(
    val stops: List<Double>,
    val restrictedModes: Set<Int> = emptySet(),
    val restrictedStops: List<Double> = listOf(1.0),
    val resolutionCeilings: Map<VideoResolution, Double> = emptyMap(),
) {
    fun choices(resolution: VideoResolution?, shootingMode: Int): List<Double> {
        if (shootingMode in restrictedModes) return restrictedStops
        val ceiling = resolutionCeilings[resolution] ?: return stops
        return (stops.filter { it <= ceiling } + ceiling).distinct().sorted()
    }
}
