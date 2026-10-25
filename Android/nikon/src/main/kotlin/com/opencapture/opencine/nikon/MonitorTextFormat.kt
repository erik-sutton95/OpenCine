package com.opencapture.opencine.nikon

import java.util.Locale
import kotlin.math.roundToInt

/**
 * The Kotlin twin of Swift `MonitorTextFormat` (`Sources/OpenCineNikon/MonitorTextFormat.swift`):
 * compact monitor labels for camera-native values, e.g. `6K · 24p` rather than `6048 × 3402`.
 * Nothing links the two, so both test suites read `Fixtures/nikon-monitor-text.tsv`.
 */
object MonitorTextFormat {
    /**
     * A resolution plus frame rate as `6K · 24p`. The class (`8K`/`6K`/`4K`) comes from the pixel
     * width, smaller widths show the raw width, and the rate rounds to whole frames. An unknown
     * rate (zero or less) is left out rather than shown as `0p`.
     */
    fun resolutionLabel(pixelWidth: Int, pixelHeight: Int, frameRate: Double): String {
        val resolution = resolutionClass(pixelWidth)
        val rate = if (frameRate.isFinite()) frameRate.roundToInt() else 0
        return if (rate > 0) "$resolution · ${rate}p" else resolution
    }

    /** A PTP `"WxH"` property (`"6048x3402"`) plus rate; [fallback] when missing or unparsable. */
    fun resolutionLabel(fromProperty: String?, frameRate: Int, fallback: String = ""): String {
        val parts = fromProperty?.split("x")?.filter { it.isNotEmpty() } ?: return fallback
        val width = parts.getOrNull(0)?.toIntOrNull()
        val height = parts.getOrNull(1)?.toIntOrNull()
        if (parts.size != 2 || width == null || height == null) return fallback
        return resolutionLabel(width, height, frameRate.toDouble())
    }

    /**
     * The remaining-shots readout: the count below a thousand, then thousands with one decimal
     * (`6.7k`, `20.2k`) and no trailing zero (`12k`), whole thousands from 100k. Rounded down so
     * the header never promises a frame the card cannot hold (hardware pass 1.2). The header
     * pairs it with a picture glyph instead of a "SHOTS" word.
     */
    fun shotsRemainingCompactLabel(count: Int): String {
        val shots = maxOf(0, count)
        val tenths = shots / 100 % 10
        return when {
            shots < 1000 -> "$shots"
            shots < 100_000 && tenths != 0 -> "${shots / 1000}.${tenths}k"
            else -> "${shots / 1000}k"
        }
    }

    /** The complete count the compact readout stands for, as VoiceOver and TalkBack speak it. */
    fun shotsRemainingAccessibilityLabel(count: Int): String = "${maxOf(0, count)} shots remaining"

    /** Whether a codec label names a RAW format (R3D NE, N-RAW, ProRes RAW HQ). */
    fun isRawCodec(codec: String): Boolean {
        val upper = codec.uppercase(Locale.ROOT)
        return upper.contains("RAW") || upper.contains("R3D")
    }

    // Compiled once: the live readouts format the codec on every frame header (lane media-perf).
    private val trailingQualifier = Regex("""\s+\d+-bit\s+.+$""")
    private val trailingBitDepth = Regex("""\s+\d+-bit$""")

    /** The short family label: `"R3D NE 10-bit R3D"` becomes `"R3D NE"`. */
    fun codecShortLabel(codec: String): String {
        val stripped = codec.trim()
        val qualifier = trailingQualifier.find(stripped) ?: return stripped
        return stripped.substring(0, qualifier.range.first).trim()
    }

    /** For tight readouts: `ProRes` becomes `PR` and H.26x drops a trailing bit depth. */
    fun codecCompactLabel(codec: String): String {
        var label = codecShortLabel(codec).replace("ProRes", "PR")
        if (label.startsWith("H.26")) {
            trailingBitDepth.find(label)?.let { label = label.substring(0, it.range.first) }
        }
        return label.trim()
    }

    private fun resolutionClass(pixelWidth: Int): String =
        when {
            pixelWidth >= 7680 -> "8K"
            pixelWidth >= 5000 -> "6K"
            pixelWidth >= 3500 -> "4K"
            else -> "$pixelWidth"
        }
}
