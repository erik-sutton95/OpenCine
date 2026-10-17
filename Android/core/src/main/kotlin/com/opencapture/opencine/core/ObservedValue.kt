package com.opencapture.opencine.core

import kotlin.time.Duration

/** Where an observed value came from. An image estimate never stands in for a camera report. */
public enum class ObservationOrigin {
    CAMERA_REPORTED,
    PROTOCOL_DERIVED,
    IMAGE_ESTIMATED,
    CLOCK_DERIVED,
    OPERATOR_PROVIDED,
    /** Computed by the integration from other reported values (a model, not a reading). */
    ESTIMATED,
    UNKNOWN,
}

public sealed interface ObservationValidity {
    public data object Valid : ObservationValidity

    /** The value is kept for display but its assumptions no longer hold. */
    public data class Invalid(public val reason: String) : ObservationValidity
}

/** Only where meaningful. There are no uncalibrated confidence scores. */
public sealed interface ObservationPrecision {
    public data object Exact : ObservationPrecision

    /** The source reports in steps of this size, for example 0.25 for a four-bar battery. */
    public data class Quantized(public val step: Double) : ObservationPrecision

    public data class Approximate(public val plusOrMinus: Double) : ObservationPrecision
}

public enum class Freshness {
    FRESH,
    STALE,

    /** No value or no timestamp, so age cannot be known. */
    UNKNOWN,
}

/**
 * One observed value with its provenance.
 *
 * `value == null` is unknown, whatever else is set. A conversion preserves its provenance. Unknown
 * is never `false`, `0` or `""`: an unknown battery is not empty, unknown recording is not idle,
 * unknown charging is not unplugged. Freshness is computed against a caller-supplied `now` instead
 * of being stored, so a retained snapshot cannot claim to be fresh forever.
 */
@ConsistentCopyVisibility
public data class ObservedValue<out T : Any> private constructor(
    public val value: T?,
    public val origin: ObservationOrigin,
    public val observedAt: MonotonicInstant?,
    public val validity: ObservationValidity,
    public val precision: ObservationPrecision?,
) {
    public val isKnown: Boolean get() = value != null

    /** Convert only representable values, retaining every provenance and validity field. */
    public fun <R : Any> compactMap(transform: (T) -> R?): ObservedValue<R> =
        ObservedValue(value?.let(transform), origin, observedAt, validity, precision)


    public fun freshness(now: MonotonicInstant, maxAge: Duration): Freshness {
        val observedAt = observedAt
        if (value == null || observedAt == null) return Freshness.UNKNOWN
        return if (now - observedAt <= maxAge) Freshness.FRESH else Freshness.STALE
    }

    public companion object {
        /** Assignable to every `ObservedValue<T>`. */
        public val unknown: ObservedValue<Nothing> =
            ObservedValue(null, ObservationOrigin.UNKNOWN, null, ObservationValidity.Valid, null)

        /** A known value. */
        public operator fun <T : Any> invoke(
            value: T,
            origin: ObservationOrigin,
            at: MonotonicInstant?,
            validity: ObservationValidity = ObservationValidity.Valid,
            precision: ObservationPrecision? = null,
        ): ObservedValue<T> = ObservedValue(value, origin, observedAt = at, validity, precision)
    }
}
