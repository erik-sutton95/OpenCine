package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import org.json.JSONObject

/** DISP 1 Live, DISP 2 Clean and DISP 3 Command. A source declares which it offers
 * ([MonitorOperatorSessionModel.declare]): Command only where the source supplies a camera dashboard
 * in place of the picture. */
public enum class MonitorDisplayMode(public val title: String, public val settingsTitle: String, public val settingsCaption: String) {
    LIVE(
        "Live",
        "DISP 1 · Live",
        "The full monitor. Set what it shows in Edit view.",
    ),
    CLEAN(
        "Clean",
        "DISP 2 · Clean",
        "A stripped-back image. Same elements as DISP 1. Status, tool and capture bars start off. Pin which view assists stay on.",
    ),
    COMMAND(
        "Command",
        "DISP 3 · Command",
        "The camera dashboard in place of the picture. Only the rail is yours to arrange.",
    ),
}

public enum class MonitorDisplaySection(public val key: String, public val title: String) {
    STATUS_BAR("statusBar", "Status Bar"),
    TOOL_BAR("toolBar", "Tool Bar"),
    CAMERA_VALUES("cameraValues", "Camera Values"),
    LOCK_BUTTON("lockButton", "Lock Button"),
    BATTERIES("batteries", "Batteries"),
    RAIL_RECORD("railRecord", "Record"),
    RAIL_MEDIA("railMedia", "Media"),
    RAIL_SETTINGS("railSettings", "Settings"),
    ZOOM_CHIP("zoomChip", "Zoom Chip"),
    GIMBAL_STICK("gimbalStick", "Gimbal Stick"),
    FOCUS_BOX("focusBox", "Face Box"),
    REC_READOUT("recReadout", "REC"),
    TIMECODE("timecode", "Timecode"),
    FORMAT("format", "Format"),
    CODEC("codec", "Codec"),
    COLOR("color", "Color"),
    STORAGE("storage", "Storage"),
    FPS("fps", "FPS"),
}

public data class MonitorDisplayChrome(
    public val statusBar: Boolean = true,
    public val toolBar: Boolean = true,
    public val cameraValues: Boolean = true,
    public val lockButton: Boolean = true,
    public val batteries: Boolean = true,
    public val recReadout: Boolean = true,
    public val timecode: Boolean = true,
    public val format: Boolean = true,
    /** The recording codec chip, for sources that report one apart from the format. */
    public val codec: Boolean = true,
    public val color: Boolean = true,
    public val storage: Boolean = true,
    public val fps: Boolean = true,
    public val railRecord: Boolean = true,
    public val railMedia: Boolean = true,
    public val railSettings: Boolean = true,
    public val zoomChip: Boolean = true,
    public val gimbalStick: Boolean = true,
    public val focusBox: Boolean = true,
) {
    public fun isVisible(section: MonitorDisplaySection): Boolean =
        when (section) {
            MonitorDisplaySection.STATUS_BAR -> statusBar
            MonitorDisplaySection.TOOL_BAR -> toolBar
            MonitorDisplaySection.CAMERA_VALUES -> cameraValues
            MonitorDisplaySection.LOCK_BUTTON -> lockButton
            MonitorDisplaySection.BATTERIES -> batteries
            MonitorDisplaySection.RAIL_RECORD -> railRecord
            MonitorDisplaySection.RAIL_MEDIA -> railMedia
            MonitorDisplaySection.RAIL_SETTINGS -> railSettings
            MonitorDisplaySection.ZOOM_CHIP -> zoomChip
            MonitorDisplaySection.GIMBAL_STICK -> gimbalStick
            MonitorDisplaySection.FOCUS_BOX -> focusBox
            MonitorDisplaySection.REC_READOUT -> recReadout
            MonitorDisplaySection.TIMECODE -> timecode
            MonitorDisplaySection.FORMAT -> format
            MonitorDisplaySection.CODEC -> codec
            MonitorDisplaySection.COLOR -> color
            MonitorDisplaySection.STORAGE -> storage
            MonitorDisplaySection.FPS -> fps
        }

    public fun toggling(section: MonitorDisplaySection): MonitorDisplayChrome =
        when (section) {
            MonitorDisplaySection.STATUS_BAR -> copy(statusBar = !statusBar)
            MonitorDisplaySection.TOOL_BAR -> copy(toolBar = !toolBar)
            MonitorDisplaySection.CAMERA_VALUES -> copy(cameraValues = !cameraValues)
            MonitorDisplaySection.LOCK_BUTTON -> copy(lockButton = !lockButton)
            MonitorDisplaySection.BATTERIES -> copy(batteries = !batteries)
            MonitorDisplaySection.RAIL_RECORD -> copy(railRecord = !railRecord)
            MonitorDisplaySection.RAIL_MEDIA -> copy(railMedia = !railMedia)
            MonitorDisplaySection.RAIL_SETTINGS -> copy(railSettings = !railSettings)
            MonitorDisplaySection.ZOOM_CHIP -> copy(zoomChip = !zoomChip)
            MonitorDisplaySection.GIMBAL_STICK -> copy(gimbalStick = !gimbalStick)
            MonitorDisplaySection.FOCUS_BOX -> copy(focusBox = !focusBox)
            MonitorDisplaySection.REC_READOUT -> copy(recReadout = !recReadout)
            MonitorDisplaySection.TIMECODE -> copy(timecode = !timecode)
            MonitorDisplaySection.FORMAT -> copy(format = !format)
            MonitorDisplaySection.CODEC -> copy(codec = !codec)
            MonitorDisplaySection.COLOR -> copy(color = !color)
            MonitorDisplaySection.STORAGE -> copy(storage = !storage)
            MonitorDisplaySection.FPS -> copy(fps = !fps)
        }

    public fun toJson(): String =
        JSONObject()
            .put("statusBar", statusBar)
            .put("toolBar", toolBar)
            .put("cameraValues", cameraValues)
            .put("lockButton", lockButton)
            .put("batteries", batteries)
            .put("recReadout", recReadout)
            .put("timecode", timecode)
            .put("format", format)
            .put("codec", codec)
            .put("color", color)
            .put("storage", storage)
            .put("fps", fps)
            .put("railRecord", railRecord)
            .put("railMedia", railMedia)
            .put("railSettings", railSettings)
            .put("zoomChip", zoomChip)
            .put("gimbalStick", gimbalStick)
            .put("focusBox", focusBox)
            .toString()

    public companion object {
        public val liveDefaults: MonitorDisplayChrome = MonitorDisplayChrome()
        public val cleanDefaults: MonitorDisplayChrome =
            MonitorDisplayChrome(
                statusBar = false,
                toolBar = false,
                cameraValues = false,
                lockButton = false,
                batteries = true,
                recReadout = true,
                timecode = true,
                format = true,
                color = true,
                storage = true,
                fps = true,
                railRecord = true,
                railMedia = true,
                railSettings = true,
                zoomChip = true,
                gimbalStick = true,
                focusBox = true,
            )

        /** Live and clean offer the same list with different defaults. Command has no picture, so only
         * the rail cluster is the operator's to arrange there; the rest keeps its stock value. */
        public fun isConfigurable(section: MonitorDisplaySection, mode: MonitorDisplayMode): Boolean =
            when (mode) {
                MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN -> true
                MonitorDisplayMode.COMMAND -> section in COMMAND_SECTIONS
            }

        /** The stock layout of [mode]. */
        public fun defaults(mode: MonitorDisplayMode): MonitorDisplayChrome =
            if (mode == MonitorDisplayMode.CLEAN) cleanDefaults else liveDefaults

        public fun configurableSections(mode: MonitorDisplayMode): List<MonitorDisplaySection> =
            MonitorDisplaySection.entries.filter { isConfigurable(it, mode) }

        private val COMMAND_SECTIONS = setOf(MonitorDisplaySection.LOCK_BUTTON, MonitorDisplaySection.BATTERIES,
            MonitorDisplaySection.RAIL_RECORD, MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_SETTINGS)

        public fun fromJson(raw: String?, fallback: MonitorDisplayChrome): MonitorDisplayChrome {
            if (raw.isNullOrBlank()) return fallback
            return runCatching {
                val obj = JSONObject(raw)
                MonitorDisplayChrome(
                    statusBar = obj.optBoolean("statusBar", fallback.statusBar),
                    toolBar = obj.optBoolean("toolBar", fallback.toolBar),
                    cameraValues = obj.optBoolean("cameraValues", fallback.cameraValues),
                    lockButton = obj.optBoolean("lockButton", fallback.lockButton),
                    batteries = obj.optBoolean("batteries", fallback.batteries),
                    recReadout = obj.optBoolean("recReadout", fallback.recReadout),
                    timecode = obj.optBoolean("timecode", fallback.timecode),
                    format = obj.optBoolean("format", fallback.format),
                    codec = obj.optBoolean("codec", fallback.codec),
                    color = obj.optBoolean("color", fallback.color),
                    storage = obj.optBoolean("storage", fallback.storage),
                    fps = obj.optBoolean("fps", fallback.fps),
                    railRecord = obj.optBoolean("railRecord", fallback.railRecord),
                    railMedia = obj.optBoolean("railMedia", fallback.railMedia),
                    railSettings = obj.optBoolean("railSettings", fallback.railSettings),
                    zoomChip = obj.optBoolean("zoomChip", fallback.zoomChip),
                    gimbalStick = obj.optBoolean("gimbalStick", fallback.gimbalStick),
                    focusBox = obj.optBoolean("focusBox", fallback.focusBox),
                )
            }.getOrElse { fallback }
        }
    }
}

/** Saved per-mode layouts in app-supplied legacy storage. Reads never migrate the file.
 * Android retains per-field fallback for incomplete JSON, unlike Apple's whole-value fallback, so a
 * layout saved before the codec section shows the codec chip on both platforms. */
public class MonitorDisplayPreferences(
    private val storage: SharedPreferences,
    private val keys: Keys,
) {
    /** [command] is present only for an app whose sources offer DISP 3. */
    public data class Keys(public val live: String, public val clean: String, public val command: String? = null) {
        init {
            require(live.isNotEmpty() && clean.isNotEmpty() && live != clean)
            require(command == null || command.isNotEmpty() && command != live && command != clean)
        }
    }

    public var live: MonitorDisplayChrome
        get() = MonitorDisplayChrome.fromJson(storage.getString(keys.live, null), MonitorDisplayChrome.liveDefaults)
        set(value) { storage.edit().putString(keys.live, value.toJson()).apply() }
    public var clean: MonitorDisplayChrome
        get() = MonitorDisplayChrome.fromJson(storage.getString(keys.clean, null), MonitorDisplayChrome.cleanDefaults)
        set(value) { storage.edit().putString(keys.clean, value.toJson()).apply() }
    /** DISP 3's rail layout; stock (and not stored) when the app has no command key. */
    public var command: MonitorDisplayChrome
        get() = MonitorDisplayChrome.fromJson(keys.command?.let { storage.getString(it, null) }, MonitorDisplayChrome.liveDefaults)
        set(value) { keys.command?.let { storage.edit().putString(it, value.toJson()).apply() } }

    /** Whether [mode] has a stored layout, for an app that seeds one from an older store once. */
    public fun hasStoredLayout(mode: MonitorDisplayMode): Boolean {
        val key = when (mode) {
            MonitorDisplayMode.LIVE -> keys.live
            MonitorDisplayMode.CLEAN -> keys.clean
            MonitorDisplayMode.COMMAND -> keys.command
        }
        return key?.let { storage.getString(it, null) } != null
    }
}
