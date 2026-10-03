package com.opencapture.monitorui

enum class MonitorWaveformMode(val label: String) {
    LUMA("Luma"),
    RGB("RGB"),
    ;

    companion object {
        fun fromPersisted(raw: String): MonitorWaveformMode =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: RGB
    }
}

enum class MonitorParadeMode(val label: String) {
    RGB("RGB"),
    YRGB("YRGB"),
    ;

    val laneCount: Int
        get() = if (this == YRGB) 4 else 3

    companion object {
        fun fromPersisted(raw: String): MonitorParadeMode =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: RGB
    }
}

enum class MonitorVectorscopeZoom(val label: String, val gain: Double) {
    X1("1x", 1.0),
    X2("2x", 2.0),
    X4("4x", 4.0),
    ;

    companion object {
        fun fromPersisted(raw: String): MonitorVectorscopeZoom =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: X1
    }
}
