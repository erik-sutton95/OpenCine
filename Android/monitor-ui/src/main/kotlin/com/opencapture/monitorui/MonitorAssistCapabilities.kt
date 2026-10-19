package com.opencapture.monitorui

/** How a camera's level assist draws. Swift mirror: `MonitorLevelStyle` in MonitorPresentation. */
enum class MonitorLevelStyle(val title: String) {
    /** A horizon line through the picture's centre that rolls with the camera. */
    HORIZON("Horizon"),
    /** The two-axis roll and tilt gauge. */
    GAUGE("Gauge"),
    ;

    companion object {
        /** A saved style name, or null when it is not one. */
        fun fromStoredName(value: String?): MonitorLevelStyle? = entries.firstOrNull { it.name == value }
    }
}

/**
 * The typed assist entries a camera declares beyond the shared cinema set. The standard
 * declaration is the list every app had before, so an app that declares nothing keeps it exactly.
 * Instant Playback is a camera's own chip on Android, so the standard photography-only set is
 * empty here (Swift keeps it in its selection list). No tool is video only by default.
 *
 * Swift mirror: `MonitorAssistCapabilities` in MonitorPresentation, same names.
 */
data class MonitorAssistCapabilities(
    /** Tools offered only while the camera shoots stills. */
    val photographyOnly: Set<MonitorAssistTool> = emptySet(),
    /** The level styles the operator chooses between; empty means the shared gauge only. */
    val levelStyles: List<MonitorLevelStyle> = emptyList(),
    /** Shared tools this camera has no source for. */
    val unavailable: Set<MonitorAssistTool> = emptySet(),
    /**
     * Tools offered and drawn only while the camera records video. A camera whose stills live view
     * is already display referred declares the LUT here, so a log look never grades it twice.
     */
    val videoOnly: Set<MonitorAssistTool> = emptySet(),
) {
    /** The level has a style to choose. */
    val hasLevelStyle: Boolean get() = levelStyles.size > 1

    fun isPhotographyOnly(tool: MonitorAssistTool): Boolean = tool in photographyOnly

    /** Whether this camera offers [tool] in the current capture mode. */
    fun offers(tool: MonitorAssistTool, photography: Boolean): Boolean =
        tool !in unavailable && (photography || tool !in photographyOnly) &&
            (!photography || tool !in videoOnly)

    companion object {
        /** The declaration of an app that adds nothing to the shared list. */
        val standard: MonitorAssistCapabilities = MonitorAssistCapabilities()
    }
}
