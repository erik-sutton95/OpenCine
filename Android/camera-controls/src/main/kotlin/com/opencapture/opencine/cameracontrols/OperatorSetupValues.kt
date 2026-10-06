package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorLinkHealth
import com.opencapture.opencine.vocabulary.ConnectionPhase
import java.util.Locale

/** Live link health for the settings link tile and the FPS chip. */
object OperatorLinkHealth {
    const val TARGET_FPS = 25.0

    fun bars(
        isLive: Boolean,
        videoPackets: Int,
        hasVideoFormat: Boolean,
        measuredFps: Double = -1.0,
    ): Int {
        if (!isLive) return 0
        if (measuredFps > 0.0) {
            val score = ((measuredFps / TARGET_FPS) * 100.0).coerceIn(0.0, 100.0)
            val rounded = kotlin.math.round(score).toInt()
            if (rounded <= 0) return 1
            return ((rounded + 24) / 25).coerceIn(1, 4)
        }
        return when {
            hasVideoFormat && videoPackets > 0 -> 4
            videoPackets >= 400 -> 4
            videoPackets >= 120 -> 3
            videoPackets >= 1 -> 2
            else -> 1
        }
    }

    fun score(bars: Int): Int = MonitorLinkHealth.score(bars)

    fun caption(isLive: Boolean, bars: Int): String {
        if (!isLive) return "No live path."
        if (bars <= 0) return "Waiting for the link."
        return when (MonitorLinkHealth.band(score(bars))) {
            MonitorLinkHealth.Band.STABLE -> "Link is clean. · Stable"
            MonitorLinkHealth.Band.WATCH -> "Some loss on the link. · Watch"
            MonitorLinkHealth.Band.POOR -> "Link is weak. · Poor"
        }
    }

    fun compactFps(incoming: String): String {
        val compact = if (incoming.endsWith(".00")) incoming.dropLast(3) else incoming
        return compact.ifEmpty { "\u2014" }
    }

    fun formatMeasuredFps(fps: Double): String {
        if (fps <= 0.0) return ""
        val rounded = kotlin.math.round(fps)
        return if (kotlin.math.abs(fps - rounded) < 0.05) {
            rounded.toInt().toString()
        } else {
            String.format(Locale.US, "%.2f", fps)
        }
    }

    fun fpsChipLabel(
        isLive: Boolean,
        recovering: Boolean,
        measuredFps: Double,
        phase: ConnectionPhase,
    ): String {
        if (phase == ConnectionPhase.FAILED) return "FAIL"
        if (recovering) return "RECOV"
        if (measuredFps > 0.0) return compactFps(formatMeasuredFps(measuredFps))
        return if (!isLive && phase == ConnectionPhase.IDLE) "\u2014" else "LINK"
    }

    fun liveTileDetail(
        isLive: Boolean,
        cameraName: String,
        fpsLabel: String,
        phaseLabel: String,
    ): String = if (isLive) "$cameraName · BLE + Wi-Fi · $fpsLabel FPS" else phaseLabel
}

fun connectionPhaseLabel(phase: ConnectionPhase, failure: String?): String =
    when (phase) {
        ConnectionPhase.IDLE -> "Idle"
        ConnectionPhase.SCANNING -> "Scanning for camera…"
        ConnectionPhase.CONNECTING_GATT -> "Connecting (Bluetooth)…"
        ConnectionPhase.PAIRING -> "Pairing…"
        ConnectionPhase.AWAITING_APPROVAL -> "Approve on the camera screen"
        ConnectionPhase.READING_WIFI_CREDS -> "Reading Wi-Fi credentials…"
        ConnectionPhase.JOINING_WIFI -> "Joining camera Wi-Fi…"
        ConnectionPhase.OPENING_DATALINK -> "Opening datalink…"
        ConnectionPhase.LIVE -> "Connected"
        ConnectionPhase.FAILED ->
            if (failure.isNullOrBlank()) "Failed" else "Failed: $failure"
    }

/** The assists a clean view can keep pinned, by stored key. */
enum class CleanPinTool(val key: String, val title: String) {
    LUT("LUT", "LUT"),
    PEAKING("PEAK", "Peaking"),
    FALSE_COLOR("FALSE", "False Color"),
    ZEBRA("ZEBRA", "Zebra"),
    WAVEFORM("WAVE", "Waveform"),
    PARADE("PARADE", "Parade"),
    HISTOGRAM("HISTO", "Histogram"),
    VECTORSCOPE("VECTOR", "Vectorscope"),
    TRAFFIC_LIGHTS("LIGHTS", "Traffic Lights"),
    ND("ND", "ND Suggestion"),
    GUIDES("GUIDES", "Guides"),
    GRID("GRID", "Grid"),
    CROSSHAIR("CROSS", "Crosshair"),
    DESQUEEZE("DESQ", "Anamorphic Desqueeze"),
    MIRROR("MIRROR", "Mirror"),
    AUDIO("AUDIO", "Audio Levels"),
}

fun formatCacheSize(bytes: Long): String {
    if (bytes <= 0L) return "Empty"
    val units = arrayOf("B", "KB", "MB", "GB", "TB")
    var value = bytes.toDouble()
    var unit = 0
    while (value >= 1024.0 && unit < units.lastIndex) {
        value /= 1024.0
        unit++
    }
    return if (unit == 0) "$bytes B" else String.format(Locale.US, "%.1f %s", value, units[unit])
}

fun formatAppVersion(versionName: String, versionCode: Long): String = "$versionName ($versionCode)"
