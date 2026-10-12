package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorStatusPresentation
import com.opencapture.monitorui.MonitorTimecodeFormat
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.TimecodePrecision

/**
 * Elapsed capture time is optional integration telemetry; the common snapshot owns state and
 * timecode, formatted at the precision the source declares.
 */
public fun MonitorControlModel.statusPresentation(elapsedSeconds: Int? = null): MonitorStatusPresentation {
    val label = timecode.value?.let {
        MonitorTimecodeFormat.label(it, state.value.snapshot?.capabilities?.timecode?.precision)
    }
    return MonitorStatusPresentation(isRecording, if (isRecording == null) null else elapsedSeconds, label)
}

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
