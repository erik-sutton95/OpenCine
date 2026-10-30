package com.opencapture.opencine.media

import com.opencapture.opencine.core.MonotonicInstant
import kotlin.math.roundToLong
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.DurationUnit

/** What a download's speed readout says at one instant. Swift twin: `MediaTransferRate`. */
public sealed interface MediaTransferRate {
    /** Too little data yet for an honest number: the readout shows nothing. */
    public data object Measuring : MediaTransferRate
    /** Bytes per second over the sliding window. */
    public data class BytesPerSecond(public val rate: Long) : MediaTransferRate
    /** No byte arrived for [MediaTransferRateEstimator.STALL_AFTER]. */
    public data object Stalled : MediaTransferRate

    /** "42 MB/s", "Stalled", or null while measuring. */
    public val label: String? get() = when (this) {
        Measuring -> null
        Stalled -> "Stalled"
        is BytesPerSecond -> label(rate)
    }

    public companion object {
        /** Decimal units, like [ByteCountLabel]: KB/s under 1 MB/s, MB/s with one decimal under
         * 10 MB/s, whole MB/s above. Integer half-up rounding, so both platforms agree. */
        public fun label(bytesPerSecond: Long): String {
            val rate = bytesPerSecond.coerceAtLeast(0L)
            val kilobytes = (rate + 500L) / 1000L
            if (kilobytes < 1000L) return "$kilobytes KB/s"
            val tenths = (rate + 50_000L) / 100_000L
            if (tenths < 100L) return "${tenths / 10}.${tenths % 10} MB/s"
            return "${(rate + 500_000L) / 1_000_000L} MB/s"
        }

        /** The progress line every download surface shows: "18% · 42 MB/s", or "18%" without a
         * rate. Null when there is no progress. */
        public fun caption(fraction: Double?, rate: String?): String? {
            if (fraction == null || !fraction.isFinite()) return null
            val percent = "${(fraction.coerceIn(0.0, 1.0) * 100).toInt()}%"
            return if (rate != null) "$percent · $rate" else percent
        }
    }
}

/**
 * A download's speed: bytes over a sliding window, measured on instants the owner passes in (its
 * injected clock), so tests never read the wall clock. The window average is the smoothing.
 * Swift twin: `MediaTransferRateEstimator`.
 *
 * @param startedAt when the transfer began (time to first byte counts as measured time).
 * @param bytes bytes already present, such as a resumed download's offset; they are not speed.
 */
public class MediaTransferRateEstimator(startedAt: MonotonicInstant, bytes: Long = 0L) {
    private class Sample(val instant: MonotonicInstant, val total: Long)

    private var start = startedAt
    private var startBytes = bytes
    private val samples = ArrayDeque<Sample>().apply { add(Sample(startedAt, bytes)) }
    private var lastArrival = startedAt

    /** The transfer's running byte total at [instant]. A smaller total (a retried attempt starting
     * over) restarts the measurement there. */
    public fun record(totalBytes: Long, instant: MonotonicInstant) {
        val latest = samples.last()
        if (totalBytes < latest.total) {
            start = instant; startBytes = totalBytes; lastArrival = instant
            samples.clear(); samples.add(Sample(instant, totalBytes))
            return
        }
        if (totalBytes == latest.total) return
        samples.add(Sample(instant, totalBytes))
        lastArrival = instant
        // Keep one sample at or before the window's start: it anchors the interpolation.
        val windowStart = MonotonicInstant(instant.sinceReference - WINDOW)
        while (samples.size > 2 && samples[1].instant <= windowStart) samples.removeFirst()
    }

    public fun rate(now: MonotonicInstant): MediaTransferRate {
        val first = samples.first()
        val latest = samples.last()
        if (now - lastArrival >= STALL_AFTER) return MediaTransferRate.Stalled
        val elapsed = now - start
        val received = latest.total - startBytes
        if (received <= 0L) return MediaTransferRate.Measuring
        val settled = elapsed >= SETTLE_TIME || (elapsed >= EARLY_TIME && received >= SETTLE_BYTES)
        if (!settled) return MediaTransferRate.Measuring
        // Bytes at the window's start, interpolated between the samples around it.
        val windowStart = MonotonicInstant(now.sinceReference - WINDOW)
        val from: MonotonicInstant
        val base: Double
        if (first.instant >= windowStart) {
            from = first.instant
            base = first.total.toDouble()
        } else {
            val next = samples.firstOrNull { it.instant > windowStart } ?: latest
            from = windowStart
            base = if (next.instant <= first.instant) next.total.toDouble() else {
                val part = seconds(windowStart - first.instant) / seconds(next.instant - first.instant)
                first.total + (next.total - first.total) * minOf(1.0, part)
            }
        }
        val span = seconds(now - from)
        if (span <= 0.0) return MediaTransferRate.Measuring
        return MediaTransferRate.BytesPerSecond(maxOf(0.0, (latest.total - base) / span).roundToLong())
    }

    private fun seconds(duration: Duration): Double = duration.toDouble(DurationUnit.SECONDS)

    public companion object {
        public val WINDOW: Duration = 2.seconds
        /** No reading until this long has passed since the start... */
        public val SETTLE_TIME: Duration = 500.milliseconds
        /** ...unless this many bytes arrived over at least [EARLY_TIME]. */
        public const val SETTLE_BYTES: Long = 256_000L
        public val EARLY_TIME: Duration = 250.milliseconds
        public val STALL_AFTER: Duration = 3.seconds
    }
}
