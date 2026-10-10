package com.opencapture.opencine.media

/** Source-supplied preview signature. Declaration order resolves overlapping ranges. */
data class MonitorTransferInferenceRule(val fallback: MonitorTransfer, val transfer: MonitorTransfer,
    val minByte: IntRange, val maxByte: IntRange) {
    init {
        require(!minByte.isEmpty() && minByte.first >= 0 && minByte.last <= 255)
        require(!maxByte.isEmpty() && maxByte.first >= 0 && maxByte.last <= 255)
    }
}

/** Source facts, supplied by an integration; absent calibration/look remains absent. */
data class MonitorColorSourceProfile(
    val clip: ScopeClipProfile = ScopeClipProfile(),
    val rec709LookCurves: Map<MonitorTransfer, List<Double>> = emptyMap(),
    val transferInference: List<MonitorTransferInferenceRule> = emptyList(),
) {
    init { require(rec709LookCurves.values.all { it.size >= 2 }) }
    fun inferredTransfer(minByte: Int, maxByte: Int, fallback: MonitorTransfer): MonitorTransfer =
        transferInference.firstOrNull { it.fallback == fallback && minByte in it.minByte && maxByte in it.maxByte }
            ?.transfer ?: fallback
}
