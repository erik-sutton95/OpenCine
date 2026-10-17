package com.opencapture.monitorui

/** Existing pill sizes and typography. A declared fixture does not inherit its host's form factor. */
enum class MonitorTelemetryMetrics(
    val pillWidth: Float,
    val iconlessWidth: Float,
    val pillHeight: Float,
    val iconSize: Float,
    val fontSize: Float,
    val barHeight: Float,
    val stackSpacing: Float,
) {
    PHONE(58f, 40f, MonitorLayoutPolicy.telemetryGaugeHeight(false), 11f, 10f, 9f, 4f),
    TABLET(64f, 44f, MonitorLayoutPolicy.telemetryGaugeHeight(true), 12f, 11f, 10f, 5f),
}
