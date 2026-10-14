package com.opencapture.opencine.core

/** Recording facts retain individual source, report time and precision across partial updates. */
public data class CameraRecordingObservations(
    public val dimensions: ObservedValue<CameraRecordingFormat.Dimensions> = ObservedValue.unknown,
    public val profile: ObservedValue<String> = ObservedValue.unknown,
    public val codec: ObservedValue<String> = ObservedValue.unknown,
) {
    public companion object { public val unknown: CameraRecordingObservations = CameraRecordingObservations() }
}
