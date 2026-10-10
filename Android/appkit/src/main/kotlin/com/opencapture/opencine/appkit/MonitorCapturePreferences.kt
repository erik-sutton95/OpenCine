package com.opencapture.opencine.appkit

/** The operator's capture choices the capture sheets read and change; the app persists and applies them. */
public data class MonitorCapturePreferences(
    public val nativeIsoHop: Boolean,
    public val facePriorityExposure: Boolean,
    public val shutterUsesAngle: Boolean,
    public val shutterAngleDegrees: Double,
)
