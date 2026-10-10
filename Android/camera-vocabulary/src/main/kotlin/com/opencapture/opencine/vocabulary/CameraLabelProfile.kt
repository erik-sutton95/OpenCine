package com.opencapture.opencine.vocabulary

/**
 * Per-session names for one camera: its own words for modes, the focus modes it offers and its
 * color wheel. A session value, never process-wide, so two sessions never read each other's names
 * (Swift twin `CameraLabelProfile`; the Swift one also carries the media route, which Kotlin keeps
 * with each app's media code).
 */
data class CameraLabelProfile(
    val shootingModeLabels: Map<Int, String> = emptyMap(),
    val colorModeLabels: Map<Int, String> = emptyMap(),
    val gimbalModeLabels: Map<GimbalMode, String> = emptyMap(),
    /** The FOCUS drum and chip list, in drum order. */
    val focusLabels: List<String> = FocusOption.entries.map { it.chip },
    /** The color wheel in drum order; null preserves the observed list. */
    val colorModes: List<Int>? = null,
    val shootingModes: List<Int>? = null,
) {
    companion object {
        /** The vocabulary's own names and each body's own color wheel. */
        val standard = CameraLabelProfile()
    }
}
