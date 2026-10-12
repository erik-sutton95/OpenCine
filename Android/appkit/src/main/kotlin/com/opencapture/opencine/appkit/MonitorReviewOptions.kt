package com.opencapture.opencine.appkit

/** How long a captured picture remains visible after its full image is ready. */
public enum class MonitorReviewDuration(public val seconds: Int, public val label: String) {
    THREE_SECONDS(3, "3s"), FIVE_SECONDS(5, "5s"), SEVEN_SECONDS(7, "7s"), UNTIL_DISMISSED(0, "∞");

    /** No deadline means the operator closes the review explicitly. */
    public val automaticDismissMillis: Long? get() = seconds.takeIf { it > 0 }?.times(1_000L)

    public companion object {
        /** Restore only a declared duration; malformed preferences use the shared default. */
        public fun fromSeconds(seconds: Int): MonitorReviewDuration =
            entries.firstOrNull { it.seconds == seconds } ?: FIVE_SECONDS
    }
}

/** Operator preferences for the captured-picture review, independent of camera or app identity. */
public data class MonitorReviewOptions(
    public val duration: MonitorReviewDuration = MonitorReviewDuration.FIVE_SECONDS,
    public val showsFocusPoint: Boolean = true,
    public val showsCaptureInfo: Boolean = true,
)
