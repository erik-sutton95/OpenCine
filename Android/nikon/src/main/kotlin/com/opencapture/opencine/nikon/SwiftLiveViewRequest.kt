package com.opencapture.opencine.nikon

/** Swift-approved preview request that Android may pass unchanged to the live-view facade. */
public data class SwiftLiveViewRequest(
    val imageSize: Int,
    val compression: Int,
    val frameIntervalNanoseconds: Long,
) {
    init {
        require(imageSize in 1..3) { "Preview image size must be 1...3." }
        // 6-value Nikon enum (Basic/Normal/Fine x size/quality priority). The old 1..3 bound
        // silently discarded EVERY preview request whose bias resolved to 0 (latency) or 5
        // (detail); the require threw inside parseLiveViewRequest's runCatching, so size,
        // compression AND cadence were all dropped with no log. The Swift twin was widened for
        // exactly this reason; this bound must match it.
        require(compression in 0..5) { "Preview compression must be 0...5." }
        require(frameIntervalNanoseconds in MIN_FRAME_INTERVAL_NANOS..MAX_FRAME_INTERVAL_NANOS) {
            "Preview interval must be between ${MIN_FRAME_INTERVAL_NANOS}ns and ${MAX_FRAME_INTERVAL_NANOS}ns."
        }
    }

    /**
     * How often the monitor ASKS the body for a frame (always 60 Hz; see
     * [STANDARD_FRAME_INTERVAL_NANOS]).
     *
     * This is a request rate, not a production rate, so it is **not** the link-health target: the
     * body produces frames at its recording rate, and scoring a healthy 25p feed against 60 read
     * ~41 (two bars) where iOS reads 100 (four) beside an identical FPS number. The health target
     * is [LinkHealthInput.targetLiveViewFramesPerSecond], which iOS defines as the body's
     * recording rate (`NativeAppRoot.currentLinkHealthInputs`).
     */
    val targetFramesPerSecond: Double
        get() = NANOS_PER_SECOND.toDouble() / frameIntervalNanoseconds.toDouble()

    companion object {
        const val NANOS_PER_SECOND = 1_000_000_000L
        /** Fixed 60 Hz monitor pull target (always). */
        const val MIN_FRAME_INTERVAL_NANOS = NANOS_PER_SECOND / 60L
        /** Validation floor only; policy never emits slower than 60 Hz. */
        const val MAX_FRAME_INTERVAL_NANOS = 100_000_000L
        /** Always 60 Hz. */
        const val STANDARD_FRAME_INTERVAL_NANOS = MIN_FRAME_INTERVAL_NANOS
        /** Balanced-bias values the Swift policy actually emits (size 2, compression 3). */
        val DEFAULT = SwiftLiveViewRequest(2, 3, STANDARD_FRAME_INTERVAL_NANOS)
    }
}
