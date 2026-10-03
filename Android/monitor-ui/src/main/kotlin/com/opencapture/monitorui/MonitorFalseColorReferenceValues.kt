package com.opencapture.monitorui

data class MonitorFalseColorReferenceSegment(
    val id: Int, val lowerFraction: Double, val upperFraction: Double,
    val red: Double, val green: Double, val blue: Double,
)
data class MonitorFalseColorReferenceMarker(val id: Int, val label: String, val fraction: Double)

/** A resolved key for one sampled source/profile. UI never selects a camera curve. */
class MonitorFalseColorReferenceValues(
    val subtitle: String,
    segments: List<MonitorFalseColorReferenceSegment>,
    markers: List<MonitorFalseColorReferenceMarker> = emptyList(),
    axisLabels: List<String> = emptyList(),
) {
    val segments: List<MonitorFalseColorReferenceSegment> = segments.toList()
    val markers: List<MonitorFalseColorReferenceMarker> = markers.toList()
    val axisLabels: List<String> = axisLabels.toList()
}
