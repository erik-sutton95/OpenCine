package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorStatusPresentation
import com.opencapture.monitorui.MonitorTimecodeFormat
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.TimecodePrecision

/**
 * Elapsed capture time is optional integration telemetry; the common snapshot owns state and
 * timecode, formatted at the precision the source declares.
 */
public fun MonitorControlModel.statusPresentation(elapsedSeconds: Int? = null): MonitorStatusPresentation {
    val precision = state.value.snapshot?.capabilities?.timecode?.precision
    val label = timecode.value?.let { MonitorTimecodeFormat.label(it, precision) }
    return MonitorStatusPresentation(isRecording, if (isRecording == null) null else elapsedSeconds, label,
        MonitorTimecodeFormat.placeholder(precision))
}

/** A snapshot's clock at the precision its source declares; `null` until one is reported. */
public fun MonitorTimecodeFormat.label(snapshot: CameraSnapshot?): String? =
    snapshot?.timecode?.value?.let { label(it, snapshot.capabilities.timecode.precision) }

/** The empty clock for a declared precision; seconds when the source has not said. */
public fun MonitorTimecodeFormat.placeholder(precision: TimecodePrecision?): String =
    placeholder(frames = precision is TimecodePrecision.Frames)

/**
 * The one timecode label for a reported value: the frame field shows only when the source
 * declares frame precision and reported a frame count. Seconds-only otherwise, never derived.
 */
public fun MonitorTimecodeFormat.label(value: CameraTimecode, precision: TimecodePrecision?): String? {
    val frames = value.frames
    if (precision !is TimecodePrecision.Frames || frames == null) {
        return label(value.hours, value.minutes, value.seconds)
    }
    return label(value.hours, value.minutes, value.seconds, frames, value.dropFrame ?: precision.dropFrame)
}
