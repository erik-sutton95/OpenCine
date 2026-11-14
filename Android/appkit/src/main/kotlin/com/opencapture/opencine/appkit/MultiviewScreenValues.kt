package com.opencapture.opencine.appkit

/**
 * One category of the Multiview camera settings popup's rail, in the order the popup offers them.
 * The app maps each to its own controls. Swift twin: `MultiviewSettingsCategory`.
 */
public enum class MultiviewSettingsCategory(public val id: String) {
    ISO("iso"),
    SHUTTER("shutter"),
    EXPOSURE("exposure"),
    WB("wb"),
    FOCUS("focus"),
    APERTURE("aperture"),
    MODE("mode"),
    RESOLUTION("resolution"),
    COLOR("color"),
    AUDIO("audio"),
    ;

    /** The rail's name for it (the tabs show it upper-cased). */
    public val title: String
        get() = when (this) {
            WB -> "WB"
            RESOLUTION -> "Format"
            else -> id.replaceFirstChar { it.uppercase() }
        }

    /** The rail tab's accessibility identifier (Compose test tag). */
    public val identifier: String get() = "multiview.settings.control.$id"

    /** Whether the category is read-only now: mode, format and color while the camera records. */
    public fun locked(recording: Boolean): Boolean = recording && this in listOf(MODE, RESOLUTION, COLOR)

    public companion object {
        /**
         * What a camera offers now, from its capabilities: focus mode and aperture where it has
         * them; format, color and (where it has audio controls) audio only in a video mode.
         */
        public fun offered(focus: Boolean, aperture: Boolean, photo: Boolean, audio: Boolean): List<MultiviewSettingsCategory> =
            buildList {
                addAll(listOf(ISO, SHUTTER, EXPOSURE, WB))
                if (focus) add(FOCUS)
                if (aperture) add(APERTURE)
                add(MODE)
                if (!photo) {
                    addAll(listOf(RESOLUTION, COLOR))
                    if (audio) add(AUDIO)
                }
            }
    }
}

/** The app's open settings editor on one camera, as the popup shows it. Swift twin: `MultiviewCameraSettingsState`. */
public data class MultiviewCameraSettingsState(
    /** The categories this camera offers now ([MultiviewSettingsCategory.offered]). */
    val categories: List<MultiviewSettingsCategory>,
    /** The camera records: mode, format and color are locked. */
    val recording: Boolean = false,
    /** The editor's last command note (a refusal or error), null when there is none. */
    val note: String? = null,
    /** The editor has described the camera once; the controls start again when it first does. */
    val described: Boolean = true,
)
