package com.opencapture.monitorui

import com.opencapture.monitorui.settings.MonitorSettingsTab

/**
 * Stages one screen with fake sources inside an app's production composition: the launch contract
 * the shared conformance kit speaks to every app. Debug only; each app decodes it in its existing
 * review harness. The Swift twin (`MonitorPresentation.ReviewLaunch`) has the same fields and keys.
 */
public data class ReviewLaunch(
    val screen: Screen,
    /** The app's cameras and pair page states (`empty`, `connecting`, `pair-join`, ...). */
    val state: String? = null,
    val layout: MonitorMediaLayout = MonitorMediaLayout.GRID,
    /** Enough clips by default to scroll a tablet landscape grid. */
    val mediaCount: Int = 96,
    /** Where staged clips come from: the phone's own cache, or a connected camera's card. */
    val source: Source = Source.LOCAL,
    /** A connected camera session, required for camera-only actions such as clip delete. */
    val connected: Boolean = false,
    val settingsTab: MonitorSettingsTab? = null,
    /** Writable simulated camera controls instead of the read-only native preview. */
    val commonControls: Boolean = true,
    /** The camera's metered exposure in stops, for example -2/3; null while the camera reports none. */
    val meteredEv: Double? = null,
) {
    public enum class Screen(public val wire: String) {
        CAMERAS("cameras"), PAIR("pair"), LIVE("live"), MEDIA("media"), PLAYBACK("playback"),
        SETTINGS("settings"), CHROME_EDIT("chrome-edit"),
    }

    public enum class Source(public val wire: String) { LOCAL("local"), CAMERA("camera") }

    /** Wire keys: intent string extras on Android, launch environment on iOS. */
    public object Key {
        public const val SCREEN: String = "OPV_UI_REVIEW_SCREEN"
        public const val STATE: String = "OPV_UI_REVIEW_STATE"
        public const val LAYOUT: String = "OPV_UI_REVIEW_MEDIA_LAYOUT"
        public const val MEDIA_COUNT: String = "OPV_UI_REVIEW_MEDIA_COUNT"
        public const val SOURCE: String = "OPV_UI_REVIEW_MEDIA_SOURCE"
        public const val CONNECTED: String = "OPV_UI_REVIEW_CONNECTED"
        public const val SETTINGS_TAB: String = "OPV_UI_REVIEW_SETTINGS_TAB"
        public const val COMMON_CONTROLS: String = "OPV_UI_REVIEW_COMMON_CONTROLS"
        public const val METERED_EV: String = "OPV_UI_REVIEW_METERED_EV"
    }

    public val extras: Map<String, String>
        get() = buildMap {
            put(Key.SCREEN, screen.wire)
            state?.let { put(Key.STATE, it) }
            put(Key.LAYOUT, layout.name.lowercase())
            put(Key.MEDIA_COUNT, mediaCount.toString())
            put(Key.SOURCE, source.wire)
            put(Key.CONNECTED, if (connected) "1" else "0")
            settingsTab?.let { put(Key.SETTINGS_TAB, it.title) }
            put(Key.COMMON_CONTROLS, if (commonControls) "1" else "0")
            meteredEv?.let { put(Key.METERED_EV, it.toString()) }
        }

    public companion object {
        /** Null when no review is staged or a value is malformed: a typo must not stage a default. */
        public fun decode(value: (String) -> String?): ReviewLaunch? {
            val screen = Screen.entries.firstOrNull { it.wire == value(Key.SCREEN) } ?: return null
            fun flag(raw: String): Boolean? = mapOf("1" to true, "0" to false)[raw]
            return ReviewLaunch(
                screen = screen,
                state = value(Key.STATE),
                layout = value(Key.LAYOUT)?.let { raw ->
                    MonitorMediaLayout.entries.firstOrNull { it.name.lowercase() == raw } ?: return null
                } ?: MonitorMediaLayout.GRID,
                mediaCount = value(Key.MEDIA_COUNT)?.let { it.toIntOrNull()?.takeIf { count -> count > 0 } ?: return null }
                    ?: 96,
                source = value(Key.SOURCE)?.let { raw -> Source.entries.firstOrNull { it.wire == raw } ?: return null }
                    ?: Source.LOCAL,
                connected = value(Key.CONNECTED)?.let { flag(it) ?: return null } ?: false,
                settingsTab = value(Key.SETTINGS_TAB)?.let { raw ->
                    MonitorSettingsTab.entries.firstOrNull { it.title == raw } ?: return null
                },
                commonControls = value(Key.COMMON_CONTROLS)?.let { flag(it) ?: return null } ?: true,
                meteredEv = value(Key.METERED_EV)?.let { it.toDoubleOrNull()?.takeIf(Double::isFinite) ?: return null },
            )
        }
    }
}
