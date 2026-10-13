package com.opencapture.opencine.nikon

/**
 * The Kotlin twin of Swift `RecordDurationEstimator` (`Sources/OpenCineNikon`): remaining recording
 * minutes from codec, resolution, frame rate and free space. Per-codec base Mbps at UHD 24p, scaled
 * by pixel count and frame rate, rounded down so the "Min" readout under-promises. Both test suites
 * read the `estimate` rows of `Fixtures/nikon-monitor-text.tsv`.
 */
object RecordDurationEstimator {
    // Nikon ZR published bitrates at UHD 24p. Tune only this table (and its Swift twin).
    private val baseBitrateMbps =
        mapOf(
            "R3D NE" to 600.0,
            "N-RAW" to 470.0,
            "ProRes RAW HQ" to 1700.0,
            "ProRes 422 HQ" to 707.0,
            "H.265" to 190.0,
            "H.264" to 75.0,
        )
    private const val FALLBACK_BITRATE_MBPS = 250.0
    private const val REFERENCE_PIXELS = 3840.0 * 2160.0
    private const val REFERENCE_FRAME_RATE = 24.0

    /** A duration observation needs a supported codec and positive reported size and cadence. */
    fun estimateMinutes(codec: String?, resolution: String?, frameRate: Int?, freeBytes: Long): Int? {
        if (codec == null || resolution == null || frameRate == null || frameRate <= 0 || freeBytes < 0) return null
        val base = baseBitrateMbps[MonitorTextFormat.codecShortLabel(codec)] ?: return null
        val dimensions = resolution.split("x")
        if (dimensions.size != 2) return null
        val width = dimensions[0].toIntOrNull()?.takeIf { it > 0 } ?: return null
        val height = dimensions[1].toIntOrNull()?.takeIf { it > 0 } ?: return null
        val bitrate = base * width.toDouble() * height.toDouble() / REFERENCE_PIXELS * frameRate / REFERENCE_FRAME_RATE
        val minutes = freeBytes.toDouble() * 8 / (bitrate * 1_000_000 * 60)
        if (!bitrate.isFinite() || bitrate <= 0 || !minutes.isFinite() || minutes < 0 || minutes >= Int.MAX_VALUE.toDouble()) return null
        return minutes.toInt()
    }

    /** Estimated Mbps for a short codec label (`MonitorTextFormat.codecShortLabel`). */
    fun bitrateMbps(codec: String, resolutionWidth: Int, resolutionHeight: Int, frameRate: Int): Double {
        val base = baseBitrateMbps[codec] ?: FALLBACK_BITRATE_MBPS
        val pixelScale = (resolutionWidth.toDouble() * resolutionHeight.toDouble()) / REFERENCE_PIXELS
        val fpsScale = frameRate.toDouble() / REFERENCE_FRAME_RATE
        return base * pixelScale * fpsScale
    }

    /** Whole minutes left; `gigabytesFree` is decimal GB. 0 without space, size or rate. */
    fun minutesRemaining(
        codec: String,
        resolutionWidth: Int,
        resolutionHeight: Int,
        frameRate: Int,
        gigabytesFree: Int,
    ): Int {
        if (gigabytesFree <= 0) return 0
        val mbps = bitrateMbps(codec, resolutionWidth, resolutionHeight, frameRate)
        if (!(mbps > 0.0)) return 0
        val minutes = gigabytesFree.toDouble() * 8000 / mbps / 60
        return if (minutes.isFinite()) minutes.toInt() else 0
    }
}
