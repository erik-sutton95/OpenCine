package com.opencapture.monitorui

import androidx.compose.runtime.Composable

/** These original public call forms must keep compiling, including trailing content lambdas. */
@Composable
private fun retainedTelemetryContentCalls(layout: MonitorFieldLayout) {
    MonitorStatusChrome(layout, MonitorStatusPresentation(false), format = {}) {}
    MonitorStatusChrome(layout, MonitorStatusPresentation(false), true, true, true, format = {}) {}
    MonitorCompactTelemetryRow(layout, 0f, 0f, MonitorTelemetryMetrics.PHONE,
        storage = {}, link = {}) {}
}
