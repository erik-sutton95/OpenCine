package com.opencapture.opencine.media

/** Source-independent encoded-image mask policy. No camera or UI types. */
data class MonitorZebraMaskPolicy(
    val highlightMeasure: HighlightMeasure = HighlightMeasure.MAXIMUM_COMPONENT,
    val rampBias: Double = 1.0,
) {
    enum class HighlightMeasure { MAXIMUM_COMPONENT, REC709_LUMA }
}

/** Already resolved code thresholds; null means that zone is absent. */
data class MonitorZebraCodeThresholds(
    val highlight: Double?,
    val midtoneLower: Double?,
    val midtoneUpper: Double?,
)
