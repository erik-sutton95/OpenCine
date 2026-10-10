package com.opencapture.opencine.media

import kotlin.math.log2
import kotlin.math.pow

enum class MonitorFalseColorReadingDomain { MONITOR_PERCENT, SCENE_STOPS }
enum class MonitorFalseColorBackground { MONITOR_GRAY, SOURCE }
enum class MonitorFalseColorCubeComponent { COMPOSITE, PAINT, WEIGHT }
enum class MonitorFalseColorPaintEncoding { DISPLAY_RGB, LINEAR_SRGB }

data class MonitorFalseColorPaint(val red: Double, val green: Double, val blue: Double, val weight: Double)

/** Supplied zones and treatment of gaps and scene detail, mirrored with the Swift Media builder. */
data class MonitorFalseColorPainting(
    val bands: List<LiveFalseColorBand>,
    val edgeSoftness: Double,
    val domain: MonitorFalseColorReadingDomain,
    val background: MonitorFalseColorBackground,
    val detailBlend: Double = 0.0,
) {
    init {
        require(edgeSoftness >= 0 && edgeSoftness.isFinite())
        require(detailBlend in 0.0..1.0)
    }

    fun paint(value: Double, monitorGray: Double): MonitorFalseColorPaint {
        if (background == MonitorFalseColorBackground.MONITOR_GRAY) {
            val color = compositeColor(value, monitorGray, Triple(0.0, 0.0, 0.0))
            return MonitorFalseColorPaint(color.first, color.second, color.third, 1.0)
        }
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var total = 0.0
        for (band in bands) {
            val weight = bandWeight(value, band)
            val color = bandColor(band, monitorGray)
            red += color.first * weight
            green += color.second * weight
            blue += color.third * weight
            total += weight
        }
        if (total <= 0) return MonitorFalseColorPaint(0.0, 0.0, 0.0, 0.0)
        return MonitorFalseColorPaint(red / total, green / total, blue / total, minOf(1.0, total))
    }

    fun compositeColor(value: Double, monitorGray: Double, source: Triple<Double, Double, Double>): Triple<Double, Double, Double> {
        val base = when (background) {
            MonitorFalseColorBackground.MONITOR_GRAY -> monitorGray.coerceIn(0.0, 1.0).let { Triple(it, it, it) }
            MonitorFalseColorBackground.SOURCE -> Triple(source.first.coerceIn(0.0, 1.0),
                source.second.coerceIn(0.0, 1.0), source.third.coerceIn(0.0, 1.0))
        }
        val weighted = bands.map { it to bandWeight(value, it) }
        val total = weighted.fold(0.0) { result, item -> result + item.second }
        if (total <= 0) return base
        val normalization = maxOf(1.0, total)
        val baseWeight = maxOf(0.0, 1 - total)
        val painted = weighted.fold(Triple(base.first * baseWeight, base.second * baseWeight,
            base.third * baseWeight)) { result, item ->
            val color = bandColor(item.first, monitorGray)
            Triple(result.first + color.first * item.second, result.second + color.second * item.second,
                result.third + color.third * item.second)
        }
        return Triple(painted.first / normalization, painted.second / normalization, painted.third / normalization)
    }

    private fun bandColor(band: LiveFalseColorBand, detailGray: Double): Triple<Double, Double, Double> {
        if (detailBlend <= 0) return Triple(band.red, band.green, band.blue)
        val gray = detailGray.coerceIn(0.0, 1.0)
        val colorWeight = 1 - detailBlend
        return Triple(band.red * colorWeight + gray * detailBlend, band.green * colorWeight + gray * detailBlend,
            band.blue * colorWeight + gray * detailBlend)
    }

    private fun bandWeight(value: Double, band: LiveFalseColorBand): Double {
        val rising = if (band.lowerBound.isFinite() && band.lowerBound != 0.0)
            smoothStep(band.lowerBound - edgeSoftness, band.lowerBound + edgeSoftness, value) else 1.0
        val falling = if (band.upperBound.isFinite())
            1 - smoothStep(band.upperBound - edgeSoftness, band.upperBound + edgeSoftness, value) else 1.0
        return rising * falling
    }

    private fun smoothStep(edge0: Double, edge1: Double, value: Double): Double {
        val span = edge1 - edge0
        if (span == 0.0) return if (value >= edge1) 1.0 else 0.0
        val progress = ((value - edge0) / span).coerceIn(0.0, 1.0)
        return progress * progress * (3 - 2 * progress)
    }
}

/** Portable lattice and byte producer. It has no native handle or source/session state. */
class MonitorFalseColorLattice private constructor(
    val size: Int,
    val painting: MonitorFalseColorPainting,
    private val source: Source,
) {
    private sealed interface Source {
        data class Signal(val transfer: MonitorTransfer, val clipByte: Int, val rec709ClipByte: Int,
            val lookCurve: List<Double>?, val readThroughLook: Boolean) : Source
        data class SceneLinear(val channels: List<Double>, val coefficients: Triple<Double, Double, Double>,
            val tone: MonitorSceneToneMap) : Source
    }

    init { require(size in 2..64) }

    /** Red-fastest Float triplets, before native RGBA8 quantization. */
    fun rgb(component: MonitorFalseColorCubeComponent = MonitorFalseColorCubeComponent.PAINT,
        paintEncoding: MonitorFalseColorPaintEncoding = MonitorFalseColorPaintEncoding.DISPLAY_RGB): FloatArray {
        val encoded = List(size) { it.toDouble() / (size - 1) }
        val rgb = FloatArray(size * size * size * 3)
        var index = 0
        for (b in 0 until size) for (g in 0 until size) for (r in 0 until size) {
            val read = reading(r, g, b, encoded)
            val color = when (component) {
                MonitorFalseColorCubeComponent.COMPOSITE -> painting.compositeColor(read.first, read.second,
                    Triple(encoded[r], encoded[g], encoded[b]))
                MonitorFalseColorCubeComponent.PAINT, MonitorFalseColorCubeComponent.WEIGHT -> {
                    val paint = painting.paint(read.first, read.second)
                    if (component == MonitorFalseColorCubeComponent.PAINT) Triple(paint.red, paint.green, paint.blue)
                        else Triple(paint.weight, paint.weight, paint.weight)
                }
            }
            val output = if (paintEncoding == MonitorFalseColorPaintEncoding.LINEAR_SRGB &&
                component != MonitorFalseColorCubeComponent.WEIGHT)
                Triple(srgbDecode(color.first), srgbDecode(color.second), srgbDecode(color.third)) else color
            rgb[index++] = output.first.toFloat()
            rgb[index++] = output.second.toFloat()
            rgb[index++] = output.third.toFloat()
        }
        return rgb
    }

    /** Snapshot bytes are independent even when the deterministic calculation is memoized. */
    fun packedCube(component: MonitorFalseColorCubeComponent = MonitorFalseColorCubeComponent.PAINT,
        paintEncoding: MonitorFalseColorPaintEncoding = MonitorFalseColorPaintEncoding.DISPLAY_RGB): MonitorLUTCube {
        val key = PackedKey(size, painting, source, component, paintEncoding)
        val hit = synchronized(packedCache) { packedCache[key] }
        if (hit != null) return MonitorLUTCube(size, hit.copyOf())
        val built = MonitorLUTCube.fromRGB(size, rgb(component, paintEncoding)).rgba
        synchronized(packedCache) {
            packedCache[key] = built
            while (packedCache.size > MAX_PACKED_CACHE_ENTRIES) packedCache.remove(packedCache.keys.first())
        }
        return MonitorLUTCube(size, built.copyOf())
    }

    private fun reading(r: Int, g: Int, b: Int, encoded: List<Double>): Pair<Double, Double> = when (val s = source) {
        is Source.Signal -> {
            val w = LiveColorScience.lumaWeights(s.transfer)
            val luminance = w.first * encoded[r] + w.second * encoded[g] + w.third * encoded[b]
            val read = LiveColorScience.falseColorReading(luminance, s.transfer, s.readThroughLook, s.lookCurve,
                if (painting.domain == MonitorFalseColorReadingDomain.SCENE_STOPS) LiveFalseColorScale.SCENE_STOPS else LiveFalseColorScale.IRE)
            val clip = if (read.transfer == s.transfer) s.clipByte else s.rec709ClipByte
            val percent = ScopeDisplayScale.monitorPercent(read.encoded, read.transfer,
                ceiling = ScopeClipSnapshot(read.transfer, clip))
            val value = if (painting.domain == MonitorFalseColorReadingDomain.SCENE_STOPS)
                LiveColorScience.stops(read.encoded, read.transfer) else percent
            value to percent / 100
        }
        is Source.SceneLinear -> {
            val luminance = s.coefficients.first * s.channels[r] + s.coefficients.second * s.channels[g] + s.coefficients.third * s.channels[b]
            val value = when (painting.domain) {
                MonitorFalseColorReadingDomain.SCENE_STOPS -> if (luminance > 0) log2(luminance / 0.18) else Double.NEGATIVE_INFINITY
                MonitorFalseColorReadingDomain.MONITOR_PERCENT -> s.tone.ire(luminance)
            }
            value to s.tone.displayCode(luminance)
        }
    }

    private data class PackedKey(val size: Int, val painting: MonitorFalseColorPainting,
        val source: Source, val component: MonitorFalseColorCubeComponent,
        val paintEncoding: MonitorFalseColorPaintEncoding)

    private fun srgbDecode(value: Double): Double {
        val v = value.coerceIn(0.0, 1.0)
        return if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
    }

    companion object {
        private const val MAX_PACKED_CACHE_ENTRIES = 16
        private val packedCache = LinkedHashMap<PackedKey, ByteArray>()

        fun signal(scale: LiveFalseColorScale, transfer: MonitorTransfer, clipByte: Int,
            rec709ClipByte: Int = 255, lookCurve: List<Double>? = null,
            readThroughLook: Boolean = false, size: Int = 64): MonitorFalseColorLattice {
            require(clipByte in 1..255 && rec709ClipByte in 1..255)
            require(lookCurve == null || lookCurve.size >= 2)
            val curve = lookCurve?.toList()
            val clip = LiveColorScience.falseColorClip(scale, transfer, readThroughLook, curve, clipByte / 255.0)
            val painting = MonitorFalseColorPainting(
                LiveColorScience.falseColorBands(scale, clip.transfer, clip.ceiling, size).toList(), scale.edgeSoftness,
                if (scale.usesSceneStops) MonitorFalseColorReadingDomain.SCENE_STOPS else MonitorFalseColorReadingDomain.MONITOR_PERCENT,
                if (scale == LiveFalseColorScale.LIMITS) MonitorFalseColorBackground.SOURCE else MonitorFalseColorBackground.MONITOR_GRAY)
            return MonitorFalseColorLattice(size, painting,
                Source.Signal(transfer, clipByte, rec709ClipByte, curve, readThroughLook))
        }

        fun sceneLinear(decodedChannels: List<Double>, luminanceCoefficients: Triple<Double, Double, Double>,
            tone: MonitorSceneToneMap, painting: MonitorFalseColorPainting): MonitorFalseColorLattice =
            MonitorFalseColorLattice(decodedChannels.size, painting.copy(bands = painting.bands.toList()),
                Source.SceneLinear(decodedChannels.toList(), luminanceCoefficients, tone))
    }
}
