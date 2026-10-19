package com.opencapture.opencine.insta360.shell

import kotlin.math.abs

private val knownAspects = listOf(16 to 9, 9 to 16, 4 to 3, 3 to 4, 2 to 1, 1 to 2, 1 to 1, 3 to 2, 2 to 3)

/**
 * Nearest common ratio within 1%, else "r:1" (twin of Swift `LunaAspect.label`). The wide sizes
 * read "2.35:1" as the shared resolution readout names them (`MonitorCapturePresentation`).
 */
public fun aspectLabel(width: Int, height: Int): String {
    if (width <= 0 || height <= 0) return "?"
    val ratio = width.toDouble() / height
    if (abs(ratio - 2.35) < 0.03) return "2.35:1"
    knownAspects.firstOrNull { abs(it.first.toDouble() / it.second - ratio) / ratio < 0.01 }?.let { return "${it.first}:${it.second}" }
    return String.format(java.util.Locale.US, "%.2f:1", ratio)
}

/** The shape group a recordable format belongs to ("16:9", "9:16"), the same on every platform. */
public val CameraRecordFormat.aspectLabel: String get() = aspectLabel(width, height)

/** The colour name operators read (twin of Swift `LunaColorMode.label`). */
public val CameraColorProfile.label: String get() = when (this) {
    CameraColorProfile.STANDARD -> "Standard"
    CameraColorProfile.LOG -> "I-Log"
    CameraColorProfile.VIVID -> "Vivid"
    CameraColorProfile.HDR -> "HDR"
    CameraColorProfile.DOLBY_VISION -> "Dolby Vision"
}

/** The recording colour profiles offered as native choices, in drawer order. */
public val nativeRecordingColorProfiles: List<CameraColorProfile> =
    listOf(CameraColorProfile.STANDARD, CameraColorProfile.LOG, CameraColorProfile.DOLBY_VISION)

/**
 * The colour drum: the native choices plus the reported [current] colour when they lack it, so the
 * popup opens centred on the colour the header shows. That entry is shown, never sent: a SET goes
 * only to a native choice. Swift twin: `LunaColorMode.recordingDrum`.
 */
public fun nativeRecordingColorDrum(current: CameraColorProfile?): List<CameraColorProfile> =
    if (current == null || current in nativeRecordingColorProfiles) nativeRecordingColorProfiles
    else nativeRecordingColorProfiles + current
