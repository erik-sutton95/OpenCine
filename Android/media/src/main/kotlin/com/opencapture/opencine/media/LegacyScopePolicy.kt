package com.opencapture.opencine.media

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

// Match Swift Comparable min/max operand order, including non-finite readout clamps.
private fun legacyMin(a: Double, b: Double): Double = if (b < a) b else a
private fun legacyMax(a: Double, b: Double): Double = if (a < b) b else a

/** Resolved host values for the legacy anchored axis and toe/clip meter. No source selection. */
data class LegacyScopeCalibration(
    val blackNative: Double,
    val middleGrayNative: Double,
    val clipNative: Double,
    val defaultClipNative: Double,
    val crushUpperNative: Double,
)

data class LegacyHistogramTrafficLights(
    var crushRed: Boolean, var crushGreen: Boolean, var crushBlue: Boolean,
    var clipRed: Boolean, var clipGreen: Boolean, var clipBlue: Boolean,
) {
    companion object {
        // Fresh value: this mutable compatibility record is never shared process state.
        val none: LegacyHistogramTrafficLights
            get() = LegacyHistogramTrafficLights(false, false, false, false, false, false)
    }
}

/** Legacy compatibility math only. The current scope engine never selects this policy. */
object LegacyScopePolicy {
    const val legalBlackCode = 16.0
    const val legalWhiteCode = 235.0
    const val crushLineLevel = .05
    const val clipLineLevel = .95

    fun nativeCodeLevel(signalNative: Double): Double = legacyMin(255.0, legacyMax(0.0, signalNative)) / 255.0

    fun middleGrayLevel(calibration: LegacyScopeCalibration): Double {
        val black = calibration.blackNative
        val mid = calibration.middleGrayNative
        val defaultClip = legacyMax(calibration.defaultClipNative, mid + 1)
        return crushLineLevel + (mid - black) / (defaultClip - black) * (clipLineLevel - crushLineLevel)
    }

    fun waveformLevel(signalNative: Double, calibration: LegacyScopeCalibration): Double {
        val native = legacyMin(255.0, legacyMax(0.0, signalNative))
        val black = calibration.blackNative
        val mid = calibration.middleGrayNative
        val clip = legacyMax(calibration.clipNative, mid + 1)
        val midLevel = middleGrayLevel(calibration)
        if (native < black) return if (black > 0) native / black * crushLineLevel else crushLineLevel
        if (native <= mid) return crushLineLevel + (native - black) / (mid - black) * (midLevel - crushLineLevel)
        if (native <= clip) return midLevel + (native - mid) / (clip - mid) * (clipLineLevel - midLevel)
        val headroom = 255 - clip
        return if (headroom > 0) clipLineLevel + (native - clip) / headroom * (1 - clipLineLevel) else clipLineLevel
    }

    fun remapHistogram(histogram: IntArray, calibration: LegacyScopeCalibration): DoubleArray {
        val out = DoubleArray(256)
        if (histogram.size != 256) return out
        for (native in 0 until 256) {
            val bucket = (waveformLevel(native.toDouble(), calibration) * 255).roundToInt().coerceIn(0, 255)
            out[bucket] += histogram[native].toDouble()
        }
        return out
    }

    fun medianWaveformLevel(points: List<ScopePoint>, calibration: LegacyScopeCalibration,
        channel: (ScopePoint) -> Int): Double {
        if (points.isEmpty()) return 0.0
        val levels = DoubleArray(points.size) { waveformLevel(channel(points[it]).toDouble(), calibration) }
        val mid = levels.size / 2
        if (levels.size % 2 == 0) {
            val lower = orderStatistic(levels, mid - 1)
            val upper = orderStatistic(levels, mid)
            return (lower + upper) / 2
        }
        return orderStatistic(levels, mid)
    }

    private fun orderStatistic(values: DoubleArray, rank: Int): Double {
        var low = 0
        var high = values.size - 1
        while (low < high) {
            val pivotIndex = partition(values, low, high)
            if (pivotIndex == rank) return values[pivotIndex]
            if (pivotIndex < rank) low = pivotIndex + 1 else high = pivotIndex - 1
        }
        return values[low]
    }

    private fun partition(values: DoubleArray, low: Int, high: Int): Int {
        val pivotValue = values[high]
        var storeIndex = low
        fun swap(a: Int, b: Int) { val held = values[a]; values[a] = values[b]; values[b] = held }
        for (index in low until high) if (values[index] < pivotValue) { swap(index, storeIndex); storeIndex += 1 }
        swap(storeIndex, high)
        return storeIndex
    }

    fun medianWaveformLevel(histogram: IntArray, calibration: LegacyScopeCalibration): Double {
        if (histogram.size != 256) return 0.0
        val total = histogram.sumOf { it.toLong() }
        if (total <= 0) return 0.0
        val target = total / 2L
        var cumulative = 0L
        for (native in 0 until 256) {
            cumulative += histogram[native]
            if (cumulative > target || (cumulative == target && total % 2L == 0L))
                return waveformLevel(native.toDouble(), calibration)
        }
        return waveformLevel(255.0, calibration)
    }

    fun trafficLights(samples: ScopeSamples, calibration: LegacyScopeCalibration,
        threshold: Double = .10): LegacyHistogramTrafficLights = trafficLights(
        samples.histogramRed, samples.histogramGreen, samples.histogramBlue, calibration, threshold)

    fun trafficLights(red: IntArray, green: IntArray, blue: IntArray,
        calibration: LegacyScopeCalibration, threshold: Double = .10): LegacyHistogramTrafficLights {
        val clipEdge = trafficClipEdge(calibration)
        val crushFloor = trafficCrushFloor(calibration)
        val crushEdge = trafficCrushEdge(calibration)
        fun clips(histogram: IntArray) = edgeEnergy(histogram, clipEdge, 255) > threshold
        fun crushes(histogram: IntArray) = edgeEnergy(histogram, crushFloor, crushEdge) > threshold
        return LegacyHistogramTrafficLights(crushes(red), crushes(green), crushes(blue), clips(red), clips(green), clips(blue))
    }

    fun trafficClipEdge(calibration: LegacyScopeCalibration): Int = ceil(calibration.clipNative).toInt().coerceIn(0, 255)
    fun trafficCrushFloor(calibration: LegacyScopeCalibration): Int = floor(calibration.blackNative).toInt().coerceIn(0, 255)
    fun trafficCrushEdge(calibration: LegacyScopeCalibration): Int = ceil(calibration.crushUpperNative).toInt().coerceIn(0, 255)

    private fun edgeEnergy(histogram: IntArray, from: Int, to: Int): Double {
        if (histogram.size != 256 || from > to || from < 0 || to > 255) return 0.0
        val total = histogram.sumOf { it.toLong() }
        if (total <= 0) return 0.0
        var selected = 0L
        for (index in from..to) selected += histogram[index]
        return selected.toDouble() / total.toDouble()
    }
}

enum class LegacyTrafficLightsBarSide { NEUTRAL, OVER, UNDER }
class LegacyTrafficLightsChannelDisplay(side: LegacyTrafficLightsBarSide, barFill: Double) {
    val side = side
    val barFill = legacyMin(1.0, legacyMax(0.0, barFill))
    override fun equals(other: Any?) = other is LegacyTrafficLightsChannelDisplay && side == other.side && barFill == other.barFill
    override fun hashCode() = 31 * side.hashCode() + barFill.hashCode()
    companion object { val neutral = LegacyTrafficLightsChannelDisplay(LegacyTrafficLightsBarSide.NEUTRAL, 0.0) }
}
class LegacyTrafficLightsChannelReading(level: Double, val clip: Boolean, val crush: Boolean) {
    val level = legacyMin(1.0, legacyMax(0.0, level))
    override fun equals(other: Any?) = other is LegacyTrafficLightsChannelReading && level == other.level && clip == other.clip && crush == other.crush
    override fun hashCode() = (31 * level.hashCode() + clip.hashCode()) * 31 + crush.hashCode()
}
data class LegacyTrafficLightsReading(
    val red: LegacyTrafficLightsChannelReading, val green: LegacyTrafficLightsChannelReading,
    val blue: LegacyTrafficLightsChannelReading,
) {
    companion object { val empty = LegacyTrafficLightsReading(
        LegacyTrafficLightsChannelReading(0.0, false, false), LegacyTrafficLightsChannelReading(0.0, false, false),
        LegacyTrafficLightsChannelReading(0.0, false, false)) }
}
enum class LegacyTrafficLightsChannel { RED, GREEN, BLUE }

object LegacyTrafficLightsMeter {
    const val balanceCenter = .5
    const val balanceDeadZone = .03
    fun measure(samples: ScopeSamples, noiseFloorCompensation: MonitorCrushClipCompensation,
        calibration: LegacyScopeCalibration): LegacyTrafficLightsReading {
        val lights = LegacyScopePolicy.trafficLights(samples, calibration, noiseFloorCompensation.pixelFractionThreshold)
        return LegacyTrafficLightsReading(
            LegacyTrafficLightsChannelReading(channelLevel(samples, LegacyTrafficLightsChannel.RED, calibration), lights.clipRed, lights.crushRed),
            LegacyTrafficLightsChannelReading(channelLevel(samples, LegacyTrafficLightsChannel.GREEN, calibration), lights.clipGreen, lights.crushGreen),
            LegacyTrafficLightsChannelReading(channelLevel(samples, LegacyTrafficLightsChannel.BLUE, calibration), lights.clipBlue, lights.crushBlue))
    }
    fun channelLevel(samples: ScopeSamples, channel: LegacyTrafficLightsChannel, calibration: LegacyScopeCalibration): Double {
        val histogram = when (channel) { LegacyTrafficLightsChannel.RED -> samples.histogramRed
            LegacyTrafficLightsChannel.GREEN -> samples.histogramGreen; LegacyTrafficLightsChannel.BLUE -> samples.histogramBlue }
        if (histogram.any { it > 0 }) return channelLevel(histogram, calibration)
        if (samples.points.isNotEmpty()) {
            val level = LegacyScopePolicy.medianWaveformLevel(samples.points, calibration) { point ->
                when (channel) { LegacyTrafficLightsChannel.RED -> point.red
                    LegacyTrafficLightsChannel.GREEN -> point.green; LegacyTrafficLightsChannel.BLUE -> point.blue } }
            return balanceLevel(level, calibration)
        }
        return 0.0
    }
    fun channelLevel(histogram: IntArray, calibration: LegacyScopeCalibration): Double =
        balanceLevel(LegacyScopePolicy.medianWaveformLevel(histogram, calibration), calibration)
    private fun balanceLevel(scopeLevel: Double, calibration: LegacyScopeCalibration): Double {
        val middle = LegacyScopePolicy.middleGrayLevel(calibration)
        if (scopeLevel <= middle) return if (middle > 0) (scopeLevel / middle) * .5 else 0.0
        val upperSpan = legacyMax(1 - middle, java.lang.Double.MIN_VALUE)
        return .5 + ((scopeLevel - middle) / upperSpan) * .5
    }
    fun channelDisplay(reading: LegacyTrafficLightsChannelReading, balanceCenter: Double = this.balanceCenter,
        deadZone: Double = balanceDeadZone): LegacyTrafficLightsChannelDisplay {
        val deviation = reading.level - balanceCenter
        if (abs(deviation) <= deadZone) return LegacyTrafficLightsChannelDisplay.neutral
        if (deviation > 0) return LegacyTrafficLightsChannelDisplay(LegacyTrafficLightsBarSide.OVER,
            legacyMin(1.0, deviation / legacyMax(1 - balanceCenter, java.lang.Double.MIN_VALUE)))
        return LegacyTrafficLightsChannelDisplay(LegacyTrafficLightsBarSide.UNDER,
            legacyMin(1.0, abs(deviation) / legacyMax(balanceCenter, java.lang.Double.MIN_VALUE)))
    }
}
