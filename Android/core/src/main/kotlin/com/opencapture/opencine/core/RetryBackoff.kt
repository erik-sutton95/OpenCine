package com.opencapture.opencine.core

import kotlin.math.pow

/**
 * Pure jittered exponential delay. Inputs and output use the caller's same time unit;
 * choosing a clock, sleeping, retry limits and random samples belongs to the owner.
 */
public data class RetryBackoff(
    public val initialDelay: Double,
    public val maximumDelay: Double,
    public val multiplier: Double = 2.0,
    public val jitterFraction: Double = 0.3,
) {
    public fun delay(attempt: Int, jitter: Double): Double {
        val exponent = maxOf(0, attempt).toDouble()
        val capped = minOf(maximumDelay, initialDelay * multiplier.pow(exponent))
        val clampedJitter = jitter.coerceIn(0.0, 1.0)
        val signedSpread = (clampedJitter * 2 - 1) * jitterFraction
        val jittered = capped * (1 + signedSpread)
        return minOf(maximumDelay, maxOf(0.0, jittered))
    }
}
