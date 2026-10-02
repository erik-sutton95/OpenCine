package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorStatusPresentation
import java.util.Locale

/** Elapsed capture time is optional integration telemetry; the common snapshot owns state and timecode. */
public fun MonitorControlModel.statusPresentation(elapsedSeconds: Int? = null): MonitorStatusPresentation {
    val timecode = state.value.snapshot?.timecode?.value?.let {
        String.format(Locale.ROOT, "%02d:%02d:%02d", it.hours, it.minutes, it.seconds)
    }
    return MonitorStatusPresentation(isRecording, if (isRecording == null) null else elapsedSeconds, timecode)
}
