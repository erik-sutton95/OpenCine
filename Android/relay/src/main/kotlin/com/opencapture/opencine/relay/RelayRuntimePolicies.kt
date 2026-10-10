package com.opencapture.opencine.relay

public enum class RelayEncoderProfile(
    public val wireValue: String,
    public val title: String,
    public val maxKeyframeInterval: Int,
    public val maxInFlightFramesPerPeer: Int,
) {
    LOW_LATENCY("lowLatency", "Low latency", 50, 2),
    QUALITY("quality", "Quality", 120, 4);

    public companion object {
        public fun fromWireValue(value: String?): RelayEncoderProfile =
            entries.firstOrNull { it.wireValue == value } ?: LOW_LATENCY
    }
}

public class RelayBitratePolicy(
    ladder: List<Int> = listOf(10_000_000, 7_000_000, 4_500_000, 3_000_000),
    maxFrameQPLadder: List<Int> = listOf(36, 39, 42, 45),
    public val stepDownSaturation: Double = 0.3,
    public val stepUpSaturation: Double = 0.05,
    public val windowSeconds: Double = 5.0,
    public val stepUpAfterCleanSeconds: Double = 30.0,
) {
    public val ladder: List<Int> = ladder.toList()
    public val maxFrameQPLadder: List<Int> = maxFrameQPLadder.toList()
    init {
        require(this.ladder.isNotEmpty() && this.ladder.size == this.maxFrameQPLadder.size)
        require(windowSeconds > 0.0 && stepUpAfterCleanSeconds >= 0.0)
    }
}

/** Consecutive saturation, bounded windows and slow recovery exactly mirror shared Swift. */
public class RelayBitrate(
    ceilingIndex: Int = 0,
    now: Double = 0.0,
    public val policy: RelayBitratePolicy = RelayBitratePolicy(),
) {
    public var ceilingIndex: Int = ceilingIndex.coerceIn(0, policy.ladder.lastIndex)
    public var rungIndex: Int = this.ceilingIndex
        private set
    private var windowStartedAt: Double = now
    private var ticksInWindow: Int = 0
    private var saturatedTicksInWindow: Int = 0
    private var previousTickSaturated: Boolean = false
    private var cleanSince: Double = now
    private val effectiveIndex: Int get() = maxOf(rungIndex, ceilingIndex).coerceIn(0, policy.ladder.lastIndex)
    public val bitsPerSecond: Int get() = policy.ladder[effectiveIndex]
    public val maxFrameQP: Int get() = policy.maxFrameQPLadder[effectiveIndex]

    public fun recordTick(saturated: Boolean, cameraStarving: Boolean = false, now: Double): Int? {
        val full = saturated || cameraStarving
        ticksInWindow += 1
        if (full && previousTickSaturated) saturatedTicksInWindow += 1
        previousTickSaturated = full
        if (now - windowStartedAt < policy.windowSeconds || ticksInWindow <= 0) return null
        val saturation = saturatedTicksInWindow.toDouble() / ticksInWindow
        ticksInWindow = 0
        saturatedTicksInWindow = 0
        windowStartedAt = now
        ceilingIndex = ceilingIndex.coerceIn(0, policy.ladder.lastIndex)
        if (saturation > policy.stepDownSaturation) {
            cleanSince = now
            if (rungIndex < policy.ladder.lastIndex) {
                rungIndex += 1
                return bitsPerSecond
            }
            return null
        }
        if (saturation > policy.stepUpSaturation) {
            cleanSince = now
            return null
        }
        if (rungIndex > ceilingIndex && now - cleanSince >= policy.stepUpAfterCleanSeconds) {
            rungIndex -= 1
            cleanSince = now
            return bitsPerSecond
        }
        return null
    }
}

public class RelayCameraStarvationPolicy(
    public val absoluteFloorFPS: Double,
    public val baselineFraction: Double,
) {
    public fun threshold(soloBaselineFPS: Double): Double =
        if (soloBaselineFPS > 0.0) maxOf(absoluteFloorFPS, soloBaselineFPS * baselineFraction) else absoluteFloorFPS
}

public class RelayEncodePolicy(
    depth: Int = DEFAULT_DEPTH,
    public val minimumKeyframeSeconds: Double = 1.0,
) {
    public val depth: Int = depth.coerceAtLeast(1)
    public var inFlight: Int = 0
        private set
    private var lastKeyAt: Double = Double.NEGATIVE_INFINITY

    public fun admit(): Boolean {
        if (inFlight >= depth) return false
        inFlight += 1
        return true
    }
    public fun complete(): Unit { inFlight = (inFlight - 1).coerceAtLeast(0) }
    public fun forceKeyframe(requested: Boolean, now: Double): Boolean {
        if (!requested || now - lastKeyAt < minimumKeyframeSeconds) return false
        lastKeyAt = now
        return true
    }
    public companion object { public const val DEFAULT_DEPTH: Int = 2 }
}

/** Recognized control identity only; no command callback exists in lease retirement. */
public class RelayParkedControlLease(public val windowMillis: Long = DEFAULT_WINDOW_MILLIS) {
    private var parkedWatcherID: String? = null
    private var parkedUntilMillis: Long = 0L
    public fun isParked(nowMillis: Long): Boolean = parkedWatcherID != null && nowMillis < parkedUntilMillis
    public fun parkedWatcherID(nowMillis: Long): String? = if (isParked(nowMillis)) parkedWatcherID else null
    public fun park(watcherID: String?, nowMillis: Long): Boolean {
        if (watcherID.isNullOrEmpty()) { clear(); return false }
        parkedWatcherID = watcherID
        parkedUntilMillis = nowMillis + windowMillis
        return true
    }
    public fun claim(watcherID: String?, nowMillis: Long): Boolean {
        if (watcherID.isNullOrEmpty() || !isParked(nowMillis) || parkedWatcherID != watcherID) return false
        clear()
        return true
    }
    public fun clear(): Unit { parkedWatcherID = null; parkedUntilMillis = 0L }
    public companion object { public const val DEFAULT_WINDOW_MILLIS: Long = 20_000L }
}
