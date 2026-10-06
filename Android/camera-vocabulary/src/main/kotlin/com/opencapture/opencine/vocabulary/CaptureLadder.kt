package com.opencapture.opencine.vocabulary

/**
 * One camera setting picked from a list of the camera's own labels, in camera order: the
 * settings with no typed meaning (focus area, codec, drive, picture control). Typed settings
 * (ISO, shutter, iris, white balance) stay on the core capability model.
 */
data class CaptureLadder(
    /** The camera's current label; null when it has not reported one. */
    val current: String?,
    val values: List<String>,
    /** Values the drum marks (native base ISOs). */
    val marked: Set<String> = emptySet(),
    /** Why this drum cannot change now; null when it can. */
    val lock: CaptureLock? = null,
)

/**
 * Why a setting cannot change now. [RECORDING] and [CAMERA_CONTROL] freeze the whole sheet;
 * [AUTO] and [EXPOSURE_PROGRAM] freeze only the drum, so the operator can still leave Auto.
 */
enum class CaptureLock {
    RECORDING,
    CAMERA_CONTROL,
    EXPOSURE_PROGRAM,
    AUTO,
    ;

    val freezesSheet: Boolean get() = this == RECORDING || this == CAMERA_CONTROL
}

/** A white balance fine-tune position in grid cells; [amberBlue] null is a green/magenta-only tune. */
data class CaptureTint(val greenMagenta: Int, val amberBlue: Int?, val range: IntRange)
