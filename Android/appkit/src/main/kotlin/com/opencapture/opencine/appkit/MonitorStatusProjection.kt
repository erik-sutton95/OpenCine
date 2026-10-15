package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorStatusPresentation
import com.opencapture.monitorui.MonitorTimecodeFormat
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CameraTimecodeReading
import com.opencapture.opencine.core.TimecodePrecision

/**
 * Explicit integration duration takes precedence. Otherwise use the independent clock-derived
 * counter from a fresh camera-confirmed start; an unknown start or lost link stays unknown.
 * The common snapshot owns recording state and source-declared timecode precision.
 */
public fun MonitorControlModel.statusPresentation(elapsedSeconds: Int? = null): MonitorStatusPresentation {
    val precision = state.value.snapshot?.capabilities?.timecodeCapability?.precision
    val label = timecodeReading.value?.let { MonitorTimecodeFormat.label(it, precision) }
    return MonitorStatusPresentation(isRecording, if (isRecording == null) null else (elapsedSeconds ?: recordingElapsed.value), label,
        MonitorTimecodeFormat.placeholder(precision))
}

/** A snapshot's clock at the precision its source declares; `null` until one is reported. */
public fun MonitorTimecodeFormat.label(snapshot: CameraSnapshot?): String? =
    snapshot?.timecodeReading?.value?.let { label(it, snapshot.capabilities.timecodeCapability.precision) }

/** The empty clock for a declared precision; seconds when the source has not said. */
public fun MonitorTimecodeFormat.placeholder(precision: TimecodePrecision?): String =
    placeholder(frames = precision is TimecodePrecision.Frames)

/**
 * The one timecode label for a reported value: the frame field shows only when the source
 * declares frame precision and reported a frame count. Seconds-only otherwise, never derived.
 */
public fun MonitorTimecodeFormat.label(value: CameraTimecodeReading, precision: TimecodePrecision?): String? {
    val frames = value.frames
    if (precision !is TimecodePrecision.Frames || frames == null) {
        return label(value.hours, value.minutes, value.seconds)
    }
    return label(value.hours, value.minutes, value.seconds, frames, value.dropFrame ?: precision.dropFrame)
}

/** A known frame-complete value may use the same precision-aware formatter. */
public fun MonitorTimecodeFormat.label(value: CameraTimecode, precision: TimecodePrecision?): String? =
    label(CameraTimecodeReading(value), precision)
