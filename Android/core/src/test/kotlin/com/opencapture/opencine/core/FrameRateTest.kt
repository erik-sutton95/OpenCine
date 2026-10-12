package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** Swift twin: `FrameRateTests`. Same vectors, same expectations. */
class FrameRateTest {
    /** A5-09: a decimal frame rate (Luna's schema table) becomes the exact Rational once, in Core. */
    @Test fun aDecimalRateBecomesTheExactRational() {
        val vectors = listOf(
            23.976 to Rational(24000, 1001), 23.98 to Rational(24000, 1001), 24.0 to Rational(24),
            25.0 to Rational(25), 29.97 to Rational(30000, 1001), 30.0 to Rational(30),
            47.95 to Rational(48000, 1001), 59.94 to Rational(60000, 1001), 119.88 to Rational(120000, 1001),
            240.0 to Rational(240), 12.5 to Rational(25, 2),
            0.0 to null, -24.0 to null, Double.NaN to null, Double.POSITIVE_INFINITY to null,
        )
        for ((fps, expected) in vectors) assertEquals(expected, Rational.frameRate(fps), "$fps")
    }
}
