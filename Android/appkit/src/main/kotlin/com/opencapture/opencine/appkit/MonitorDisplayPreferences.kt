package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import org.json.JSONObject

public enum class MonitorDisplayMode(public val title: String, public val settingsTitle: String, public val settingsCaption: String) {
    LIVE(
        "Live",
        "DISP 1 · Live",
        "The full monitor. Set what it shows in Edit view.",
    ),
    CLEAN(
        "Clean",
        "DISP 2 · Clean",
        "A stripped-back image. Same elements as DISP 1; status, tool and capture bars start off. Pin which view assists stay on.",
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

/** Saved live/clean layouts in app-supplied legacy storage. Reads never migrate the file.
 * Android retains per-field fallback for incomplete JSON, unlike Apple's whole-value fallback. */
public class MonitorDisplayPreferences(
    private val storage: SharedPreferences,
    private val keys: Keys,
) {
    public data class Keys(public val live: String, public val clean: String) {
        init { require(live.isNotEmpty() && clean.isNotEmpty() && live != clean) }
    }

    public var live: MonitorDisplayChrome
        get() = MonitorDisplayChrome.fromJson(storage.getString(keys.live, null), MonitorDisplayChrome.liveDefaults)
        set(value) { storage.edit().putString(keys.live, value.toJson()).apply() }
    public var clean: MonitorDisplayChrome
        get() = MonitorDisplayChrome.fromJson(storage.getString(keys.clean, null), MonitorDisplayChrome.cleanDefaults)
        set(value) { storage.edit().putString(keys.clean, value.toJson()).apply() }
}
