package com.opencapture.opencine.media

public enum class MonitorPlaybackAvailability { ORIGINAL, PROXY, CAMERA }
public enum class MonitorPlaybackClockStyle {
    ELAPSED, ROUNDED_MINUTES_SECONDS, ELAPSED_MINUTES_SECONDS;
    /** Null leaves the established product duration formatter in control. */
    public fun timeLabel(seconds: Double): String? {
        if (this == ELAPSED) return null
        val rounded = this == ROUNDED_MINUTES_SECONDS
        val value = kotlin.math.floor(seconds + if (rounded) 0.5 else 0.0)
        if (!value.isFinite() || value < 0.0 || value >= Long.MAX_VALUE.toDouble()) return if (rounded) "00:00" else "0:00"
        val total = value.toLong()
        return String.format(java.util.Locale.ROOT, if (rounded) "%02d:%02d" else "%d:%02d", total / 60, total % 60)
    }
}

/** Ordered source facts. No UI or native lifetime is retained. */
public data class MonitorPlaybackMetadataValue(public val title: String, public val value: String)
public data class MonitorPlaybackSourceValues(
    public val availability: MonitorPlaybackAvailability? = null,
    public val progress: Double? = null,
    /** Legacy Compose presentation fraction. New native adapters use bufferedThroughSeconds. */
    public val buffered: Double? = null,
    public val colorLabel: String? = null,
    public val transfer: MonitorTransfer? = null,
    public val clipByte: Int? = null,
    public val metadata: List<MonitorPlaybackMetadataValue> = emptyList(),
    public val clockStyle: MonitorPlaybackClockStyle = MonitorPlaybackClockStyle.ELAPSED,
    /** Furthest native loaded-time-range end in source seconds; null is unknown.
     * Not a continuous-range guarantee or a downloaded byte fraction. */
    public val bufferedThroughSeconds: Double? = null,
    /** Explicit unknown sources opt out of legacy player/effect transfer fallback. */
    public val allowsSignalFallback: Boolean = true,
    /** A source condition the operator should read now (a share waiting on the camera cache). */
    public val notice: String? = null,
) {
    /** The header line under the title: the source's notice while it has one, else the clip facts. */
    public fun headerSubtitle(facts: String): String = notice?.takeIf { it.isNotBlank() } ?: facts
    /** Maps only an actual native temporal observation with known actual native duration. */
    public fun bufferedTemporalFraction(nativeDuration: Double?): Double? {
        val through = bufferedThroughSeconds?.takeIf { it.isFinite() && it >= 0.0 } ?: return null
        val duration = nativeDuration?.takeIf { it.isFinite() && it > 0.0 } ?: return null
        return (through / duration).coerceIn(0.0, 1.0)
    }
    public fun resolvedTransfer(fallback: () -> MonitorTransfer?): MonitorTransfer? =
        transfer ?: if (allowsSignalFallback) fallback() else null
    public val sourceLabel: String? get() {
        val source = availability ?: return null
        if (source == MonitorPlaybackAvailability.ORIGINAL) return "ORIGINAL · ON PHONE"
        val label = if (source == MonitorPlaybackAvailability.PROXY) "PROXY" else "ON CAMERA"
        val fraction = progress?.takeIf { it.isFinite() } ?: return label
        return "$label · CACHING ORIGINAL ${(fraction.coerceIn(0.0, 1.0) * 100).toInt()}%"
    }
}
