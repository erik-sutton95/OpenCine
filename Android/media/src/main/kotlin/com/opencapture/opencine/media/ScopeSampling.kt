package com.opencapture.opencine.media

import kotlin.math.ln
import kotlin.math.round
import kotlin.math.roundToInt

enum class MonitorScopeByteLayout { BGRA, RGBA }

/** One sampled pixel for WAVE / PARADE / VECTOR. Bytes are native curve codes. */
data class ScopePoint(
    val xRatio: Double,
    val yRatio: Double,
    val red: Int,
    val green: Int,
    val blue: Int,
    val luma: Int,
    val sampleX: Int? = null,
    val sampleY: Int? = null,
)

/** Shared tap product. Histograms are 256-bin native-code counts. */
data class ScopeSamples(
    val histogramLuma: IntArray,
    val histogramRed: IntArray,
    val histogramGreen: IntArray,
    val histogramBlue: IntArray,
    val points: List<ScopePoint>,
) {
    companion object {
        val EMPTY =
            ScopeSamples(
                IntArray(256),
                IntArray(256),
                IntArray(256),
                IntArray(256),
                emptyList(),
            )
    }
}

/** Remapped / blended / smoothed HISTO curves on the WAVE IRE axis. */
data class ScopeHistogramDisplay(
    val luma: FloatArray,
    val red: FloatArray,
    val green: FloatArray,
    val blue: FloatArray,
) {
    companion object {
        val EMPTY =
            ScopeHistogramDisplay(
                FloatArray(256),
                FloatArray(256),
                FloatArray(256),
                FloatArray(256),
            )
    }
}

/** One published tick for every scope surface. */
data class ScopeAssistBundle(
    val revision: Long = 0,
    val samples: ScopeSamples = ScopeSamples.EMPTY,
    val vectorscopePoints: List<ScopePoint> = emptyList(),
    val trailSamples: ScopeSamples = ScopeSamples.EMPTY,
    val trailVectorscopePoints: List<ScopePoint> = emptyList(),
    val traffic: ScopeTrafficLightsReading = ScopeTrafficLightsReading.NONE,
    val histogramDisplay: ScopeHistogramDisplay = ScopeHistogramDisplay.EMPTY,
    val transfer: MonitorTransfer = MonitorTransfer.REC709,
    val iso: Int? = null,
    /** The clip ceiling of the source that sampled this bundle. */
    val ceiling: ScopeClipSnapshot = ScopeClipSnapshot(),
    /** Measured code placement from the actual source publication. */
    val levelAxis: ScopeLevelAxis? = null,
) {
    val isEmpty: Boolean
        get() = revision == 0L && samples.points.isEmpty() && samples.histogramLuma.all { it == 0 }

    companion object {
        val EMPTY = ScopeAssistBundle()
    }
}

/**
 * One-pass sampler on the GLES tap. WAVE / PARADE / HISTO / LIGHTS
 * meter encoded camera codes; VECTOR maps the same walk through the display look.
 */
object ScopeSampler {
    const val MAX_WIDTH = 200
    const val POINT_STRIDE = 2
    const val BASE_MIN_INTERVAL_NS = 1_000_000_000L / 25
    const val DENSE_MIN_INTERVAL_NS = 1_000_000_000L / 10
    const val DENSE_ASSIST_THRESHOLD = 2
    const val TRAIL_DECAY = 0.35

    fun tapSize(srcW: Int, srcH: Int, maxWidth: Int = MAX_WIDTH): Pair<Int, Int> {
        val step = maxOf(1, srcW / maxOf(8, maxWidth))
        return maxOf(8, srcW / step) to maxOf(8, srcH / step)
    }

    fun minIntervalNs(activeScopeCount: Int, thermalMultiplier: Double = 1.0): Long {
        val base =
            if (activeScopeCount > DENSE_ASSIST_THRESHOLD) DENSE_MIN_INTERVAL_NS else BASE_MIN_INTERVAL_NS
        return (base * thermalMultiplier).toLong().coerceAtLeast(BASE_MIN_INTERVAL_NS)
    }

    /** Backdrop-only taps reuse the 25 Hz 213×120 well; inspector-only stays 5 Hz. */
    fun chromeSampleIntervalNs(
        activeScopeCount: Int, thermalMultiplier: Double, backdropDemand: Boolean,
        backdropMinimumIntervalNs: Long = BASE_MIN_INTERVAL_NS, inspectorMinimumIntervalNs: Long = 200_000_000L,
    ): Long {
        val heat = thermalMultiplier.coerceAtLeast(1.0)
        // The glass follows the feed (25 Hz tap) and is never thermal-scaled or
        // slowed by 3+ scopes; scope accumulation keeps its own admission.
        val backdropNs =
            maxOf(backdropMinimumIntervalNs, BASE_MIN_INTERVAL_NS)
        return when {
            activeScopeCount > 0 && backdropDemand ->
                minOf(minIntervalNs(activeScopeCount, heat), backdropNs)
            activeScopeCount > 0 -> minIntervalNs(activeScopeCount, heat)
            backdropDemand -> backdropNs
            else -> (inspectorMinimumIntervalNs * heat).toLong()
        }
    }

    fun thermalMultiplier(androidThermalStatus: Int): Double =
        when (androidThermalStatus) {
            // PowerManager.THERMAL_STATUS_SEVERE
            3 -> 3.0
            // CRITICAL / EMERGENCY / SHUTDOWN
            4, 5, 6 -> 5.0
            else -> 1.0
        }

    fun minMaxRGB(bytes: ByteArray): Pair<Int, Int> {
        var minC = 255
        var maxC = 0
        var i = 0
        while (i + 2 < bytes.size) {
            val r = bytes[i].toInt() and 0xFF
            val g = bytes[i + 1].toInt() and 0xFF
            val b = bytes[i + 2].toInt() and 0xFF
            val lo = minOf(r, g, b)
            val hi = maxOf(r, g, b)
            if (lo < minC) minC = lo
            if (hi > maxC) maxC = hi
            i += 4
        }
        return minC to maxC
    }

    /** Existing Android bundle sampling retains its actual RGBA/stride2 default. */
    fun sampleRaw(bytes: ByteArray, width: Int, height: Int, bytesPerRow: Int,
        transfer: MonitorTransfer, includePoints: Boolean,
        layout: MonitorScopeByteLayout = MonitorScopeByteLayout.RGBA,
        stride: Int = POINT_STRIDE, includeSampleCoordinates: Boolean = false,
        requireCompleteRows: Boolean = false): ScopeSamples {
        if (stride <= 0) return ScopeSamples.EMPTY
        if (requireCompleteRows && (width <= 0 || height <= 0 || width > Int.MAX_VALUE / 4 ||
                bytesPerRow < width * 4 || bytes.size.toLong() < bytesPerRow.toLong() * height)) {
            return ScopeSamples.EMPTY
        }
        val histY = IntArray(256)
        val histR = IntArray(256)
        val histG = IntArray(256)
        val histB = IntArray(256)
        val points =
            if (includePoints) {
                val columns = (width + stride - 1) / stride
                val rows = (height + stride - 1) / stride
                ArrayList<ScopePoint>(maxOf(0, columns * rows))
            } else {
                ArrayList()
            }
        val widthDivisor = maxOf(width, 1).toDouble()
        val heightDivisor = maxOf(height, 1).toDouble()
        val lumaW = LiveColorScience.lumaWeights(transfer)
        var y = 0
        while (y < height) {
            val rowStart = y * bytesPerRow
            var x = 0
            while (x < width) {
                val i = rowStart + x * 4
                if (i + 2 >= bytes.size) break
                val r = bytes[i + if (layout == MonitorScopeByteLayout.RGBA) 0 else 2].toInt() and 0xFF
                val g = bytes[i + 1].toInt() and 0xFF
                val b = bytes[i + if (layout == MonitorScopeByteLayout.RGBA) 2 else 0].toInt() and 0xFF
                val lumaValue = lumaW.first * r + lumaW.second * g + lumaW.third * b
                val luma = lumaValue.roundToInt().coerceIn(0, 255)
                histY[luma] += 1
                histR[r] += 1
                histG[g] += 1
                histB[b] += 1
                if (includePoints) {
                    points.add(
                        ScopePoint(
                            xRatio = x / widthDivisor,
                            yRatio = y / heightDivisor,
                            red = r,
                            green = g,
                            blue = b,
                            luma = luma,
                            sampleX = if (includeSampleCoordinates) x else null,
                            sampleY = if (includeSampleCoordinates) y else null,
                        ),
                    )
                }
                x += stride
            }
            y += stride
        }
        return ScopeSamples(histY, histR, histG, histB, points)
    }

    fun sample(
        bytes: ByteArray,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        transfer: MonitorTransfer,
        includePoints: Boolean,
        includeVectorPoints: Boolean = false,
        look: MonitorLUTCube? = null,
        trafficThreshold: Double = ScopeTrafficLights.DEFAULT_THRESHOLD,
        previous: ScopeAssistBundle = ScopeAssistBundle.EMPTY,
        ceiling: ScopeExposureCeiling = ScopeExposureCeiling.UNOBSERVED,
        iso: Int? = ceiling.resolvedISO(),
    ): ScopeAssistBundle =
        bundle(sampleRaw(bytes, width, height, bytesPerRow, transfer, includePoints || includeVectorPoints),
            transfer, includePoints, includeVectorPoints, look, trafficThreshold, previous,
            ScopeClipSnapshot(transfer, ceiling.clipByte(transfer, iso)), iso)

    /**
     * One published tick from raw samples a source already took (its own stride or tap), on the
     * shared traffic lights, histogram display and clip: Swift `ScopeSampler.bundle(samples:)`.
     */
    fun bundle(
        samples: ScopeSamples,
        transfer: MonitorTransfer,
        includePoints: Boolean,
        includeVectorPoints: Boolean = false,
        look: MonitorLUTCube? = null,
        trafficThreshold: Double = ScopeTrafficLights.DEFAULT_THRESHOLD,
        previous: ScopeAssistBundle = ScopeAssistBundle.EMPTY,
        ceiling: ScopeClipSnapshot = ScopeClipSnapshot(transfer),
        iso: Int? = null,
    ): ScopeAssistBundle {
        val kept = if (includePoints) samples else samples.copy(points = emptyList())
        return ScopeAssistBundle(
            revision = previous.revision + 1,
            samples = kept,
            vectorscopePoints = if (includeVectorPoints) monitorPoints(samples.points, look) else emptyList(),
            trailSamples = previous.samples,
            trailVectorscopePoints = previous.vectorscopePoints,
            traffic =
                ScopeTrafficLights.reading(
                    red = samples.histogramRed,
                    green = samples.histogramGreen,
                    blue = samples.histogramBlue,
                    transfer = transfer,
                    threshold = trafficThreshold,
                    previous = previous.traffic,
                    luma = samples.histogramLuma,
                    ceiling = ceiling,
                ),
            histogramDisplay = histogramDisplay(kept, previous.histogramDisplay, transfer, iso, ceiling),
            transfer = transfer,
            iso = iso,
            ceiling = ceiling,
        )
    }

    fun monitorPoints(points: List<ScopePoint>, look: MonitorLUTCube?): List<ScopePoint> {
        if (look == null) return points
        return points.map { point ->
            val mapped =
                look.map(
                    red = point.red / 255f,
                    green = point.green / 255f,
                    blue = point.blue / 255f,
                )
            val red = mapped.first.toDouble()
            val green = mapped.second.toDouble()
            val blue = mapped.third.toDouble()
            val luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            ScopePoint(
                xRatio = point.xRatio,
                yRatio = point.yRatio,
                red = displayByte(red),
                green = displayByte(green),
                blue = displayByte(blue),
                luma = displayByte(luma),
                sampleX = point.sampleX,
                sampleY = point.sampleY,
            )
        }
    }

    fun histogramDisplay(
        samples: ScopeSamples,
        previous: ScopeHistogramDisplay,
        transfer: MonitorTransfer,
        iso: Int? = null,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
    ): ScopeHistogramDisplay = histogramDisplay(samples, previous, ScopeLevelAxis.of(transfer, iso, ceiling))

    fun histogramDisplay(
        samples: ScopeSamples,
        previous: ScopeHistogramDisplay,
        axis: ScopeLevelAxis,
    ): ScopeHistogramDisplay =
        ScopeHistogramDisplay(
            luma = displayChannel(samples.histogramLuma, previous.luma, axis),
            red = displayChannel(samples.histogramRed, previous.red, axis),
            green = displayChannel(samples.histogramGreen, previous.green, axis),
            blue = displayChannel(samples.histogramBlue, previous.blue, axis),
        )

    fun displayChannel(
        native: IntArray,
        previous: FloatArray,
        transfer: MonitorTransfer,
        iso: Int? = null,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
    ): FloatArray = displayChannel(native, previous, ScopeLevelAxis.of(transfer, iso, ceiling))

    fun displayChannel(native: IntArray, previous: FloatArray, axis: ScopeLevelAxis): FloatArray {
        val remapped = axis.remapHistogram(native)
        val blended = FloatArray(256)
        val hasPrevious = previous.size == 256
        for (i in 0 until 256) {
            val current = remapped[i].toFloat()
            blended[i] = if (hasPrevious) 0.65f * current + 0.35f * previous[i] else current
        }
        return boxBlur(blended, radius = 2)
    }

    fun boxBlur(values: FloatArray, radius: Int): FloatArray {
        if (radius <= 0 || values.size <= 1) return values
        val out = FloatArray(values.size)
        for (i in values.indices) {
            val lo = maxOf(0, i - radius)
            val hi = minOf(values.lastIndex, i + radius)
            var sum = 0f
            for (j in lo..hi) sum += values[j]
            out[i] = sum / (hi - lo + 1)
        }
        return out
    }

    private fun displayByte(value: Double): Int = (value * 255).roundToInt().coerceIn(0, 255)
}

/** BT.709 chroma used by both VECTOR binning and the 75% graticule targets. */
object ScopeChroma {
    fun rec709(red: Double, green: Double, blue: Double): Pair<Double, Double> {
        val y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return (blue - y) / 1.8556 to (red - y) / 1.5748
    }

    fun rec709(red: Int, green: Int, blue: Int): Pair<Double, Double> =
        rec709(red / 255.0, green / 255.0, blue / 255.0)

    fun traceTint(red: Double, green: Double, blue: Double): Triple<Double, Double, Double> {
        val low = minOf(red, green, blue)
        val high = maxOf(red, green, blue)
        val span = high - low
        if (high <= 0.000_001 || span <= 0.000_001) return Triple(1.0, 1.0, 1.0)
        val saturation = (span / high).coerceIn(0.0, 1.0)
        fun tint(component: Double): Double {
            val pure = (component - low) / span
            return (1 - saturation) + pure * saturation
        }
        return Triple(tint(red), tint(green), tint(blue))
    }
}

/** 128-bin CbCr density raster. */
object VectorscopeRaster {
    const val BINS = 128

    fun binIndex(red: Int, green: Int, blue: Int, gain: Double = 1.0): Pair<Int, Int>? {
        val chroma = ScopeChroma.rec709(red, green, blue)
        val x = chroma.first * gain + 0.5
        val y = chroma.second * gain + 0.5
        if (x < 0 || x > 1 || y < 0 || y > 1) return null
        val scale = (BINS - 1).toDouble()
        return round(x * scale).toInt() to round(y * scale).toInt()
    }

    /** Premultiplied RGBA8, +Cr flipped up. Null when nothing lands. */
    fun pixels(points: List<ScopePoint>, gain: Double, intensity: Double): ByteArray? {
        if (points.isEmpty()) return null
        val n = BINS
        val counts = IntArray(n * n)
        val sumRed = LongArray(n * n)
        val sumGreen = LongArray(n * n)
        val sumBlue = LongArray(n * n)
        for (point in points) {
            val bin = binIndex(point.red, point.green, point.blue, gain) ?: continue
            val idx = bin.second * n + bin.first
            counts[idx] += 1
            sumRed[idx] += point.red.toLong()
            sumGreen[idx] += point.green.toLong()
            sumBlue[idx] += point.blue.toLong()
        }
        var peak = 0
        for (c in counts) if (c > peak) peak = c
        if (peak <= 0) return null
        val logPeak = ln(1.0 + peak)
        val pixels = ByteArray(n * n * 4)
        for (index in 0 until n * n) {
            val count = counts[index]
            if (count <= 0) continue
            val density = ln(1.0 + count) / logPeak
            val alpha = ((0.4 + 0.6 * density) * intensity).coerceIn(0.0, 1.0)
            val tint =
                ScopeChroma.traceTint(
                    sumRed[index].toDouble() / (count * 255.0),
                    sumGreen[index].toDouble() / (count * 255.0),
                    sumBlue[index].toDouble() / (count * 255.0),
                )
            val row = n - 1 - index / n
            val column = index % n
            val offset = (row * n + column) * 4
            pixels[offset] = (255 * tint.first * alpha).roundToInt().toByte()
            pixels[offset + 1] = (255 * tint.second * alpha).roundToInt().toByte()
            pixels[offset + 2] = (255 * tint.third * alpha).roundToInt().toByte()
            pixels[offset + 3] = (255 * alpha).roundToInt().toByte()
        }
        return pixels
    }
}
