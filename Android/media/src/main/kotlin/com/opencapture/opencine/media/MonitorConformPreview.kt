package com.opencapture.opencine.media

import java.util.Locale
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round

/**
 * Slow-motion conform preview: play a high-frame-rate clip at the rate it will
 * be conformed to in the edit. Preview only; never rewrites the file.
 *
 * Pure mirrored probe; native file/format queries remain in the platform player.
 */
public object MonitorConformPreview {
    val targetRates: List<Double> = listOf(23.976, 24.0, 25.0, 29.97, 30.0)
    const val rateTolerance: Double = 0.01
    const val conformFloor: Double = 0.99
    const val audioLabel: String = "Audio muted during conform preview"

    val cinemaRates: List<Double> =
        listOf(
            23.976, 24.0, 25.0, 29.97, 30.0, 47.952, 48.0, 50.0, 59.94, 60.0,
            100.0, 119.88, 120.0, 240.0,
        )

    data class Source(
        val captureRate: Double? = null,
        val isVariableFrameRate: Boolean = false,
        val isAlreadyConformed: Boolean = false,
    )

    sealed class Availability {
        data class Available(val rates: List<Double>) : Availability()
        data object UnknownRate : Availability()
        data object VariableRate : Availability()
        data object AlreadyConformed : Availability()
        data object NotHighFrameRate : Availability()

        val targets: List<Double>
            get() = (this as? Available)?.rates.orEmpty()

        val isAvailable: Boolean
            get() = targets.isNotEmpty()

        val unavailableReason: String?
            get() =
                when (this) {
                    is Available -> null
                    UnknownRate -> "Frame rate unavailable for this clip"
                    VariableRate -> "Variable frame rate: conform preview unavailable"
                    AlreadyConformed -> "Already conformed in camera"
                    NotHighFrameRate -> "Not a high-frame-rate clip"
                }
    }

    fun availability(source: Source): Availability {
        val rate = source.captureRate
        if (rate == null || !rate.isFinite() || rate <= 0.0) return Availability.UnknownRate
        if (source.isVariableFrameRate) return Availability.VariableRate
        if (source.isAlreadyConformed) return Availability.AlreadyConformed
        val targets = targetRates.filter { it < rate * conformFloor }
        return if (targets.isEmpty()) Availability.NotHighFrameRate else Availability.Available(targets)
    }

    fun probe(
        nominalFrameRate: Double? = null,
        minFrameDurationSeconds: Double? = null,
        listedRate: Double? = null,
    ): Source {
        val assetRates = ArrayList<Double>(2)
        usableRate(nominalFrameRate)?.let { assetRates.add(it) }
        if (minFrameDurationSeconds != null && minFrameDurationSeconds.isFinite() && minFrameDurationSeconds > 0) {
            usableRate(1.0 / minFrameDurationSeconds)?.let { assetRates.add(it) }
        }
        val snappedAsset = uniqueSnapped(assetRates)
        val capture = snappedAsset.maxOrNull()
        if (capture != null) {
            val varies =
                snappedAsset.any { candidate ->
                    !isIntegerMultiple(capture, candidate) &&
                        abs(capture - candidate) / max(capture, 1.0) > 0.08
                }
            return Source(captureRate = capture, isVariableFrameRate = varies)
        }
        val raw = assetRates.maxOrNull()
        if (raw != null) return Source(captureRate = raw)
        val listed = snap(listedRate) ?: usableRate(listedRate)
        if (listed != null) return Source(captureRate = listed)
        return Source()
    }

    fun probeLocal(nominalFrameRate: Double? = null, minFrameDurationSeconds: Double? = null,
        listedRate: Double? = null): Source = probe(nominalFrameRate, minFrameDurationSeconds, listedRate)

    fun snap(rate: Double?): Double? {
        val usable = usableRate(rate) ?: return null
        val nearest = cinemaRates.minByOrNull { abs(it - usable) } ?: return null
        val tolerance = max(0.51, nearest * 0.03)
        return if (abs(nearest - usable) <= tolerance) nearest else null
    }

    fun speed(captureRate: Double, targetRate: Double): Double {
        if (!captureRate.isFinite() || captureRate <= 0 || !targetRate.isFinite() || targetRate <= 0) {
            return 1.0
        }
        return targetRate / captureRate
    }

    fun conformedDuration(sourceSeconds: Double, speed: Double): Double {
        if (!sourceSeconds.isFinite() || sourceSeconds < 0 || !speed.isFinite() || speed <= 0) {
            return 0.0
        }
        return sourceSeconds / speed
    }

    /** Maps a conformed playhead to a source frame for finite, representable inputs. */
    fun sourceFrameIndex(conformedSeconds: Double, captureRate: Double, speed: Double): Int {
        if (!conformedSeconds.isFinite() || conformedSeconds < 0 || !(captureRate > 0) || !(speed > 0)) {
            return 0
        }
        return floor(conformedSeconds * speed * captureRate).toInt()
    }

    fun rateLabel(rate: Double): String {
        if (!rate.isFinite() || rate <= 0) return "\u2014"
        val whole = round(rate)
        return if (abs(rate - whole) < rateTolerance) {
            whole.toInt().toString()
        } else {
            String.format(Locale.US, "%.2f", rate)
        }
    }

    fun label(captureRate: Double, targetRate: Double): String {
        val percent = speed(captureRate, targetRate) * 100
        return "${rateLabel(captureRate)} → ${rateLabel(targetRate)} fps · ${percentLabel(percent)}%"
    }

    fun targetLabel(captureRate: Double, targetRate: Double): String {
        val percent = speed(captureRate, targetRate) * 100
        return "${rateLabel(targetRate)} fps · ${percentLabel(percent)}%"
    }

    fun menuHeader(captureRate: Double): String = "Conform ${rateLabel(captureRate)} fps to"

    private fun percentLabel(percent: Double): String =
        if (abs(percent - round(percent)) < 0.05) {
            round(percent).toInt().toString()
        } else {
            String.format(Locale.US, "%.1f", percent)
        }

    private fun usableRate(rate: Double?): Double? {
        if (rate == null || !rate.isFinite() || rate <= 1.0 || rate > 250.0) return null
        return rate
    }

    private fun uniqueSnapped(rates: List<Double>): List<Double> {
        val seen = HashSet<Double>()
        val out = ArrayList<Double>()
        for (rate in rates) {
            val snapped = snap(rate) ?: continue
            if (seen.add(snapped)) out.add(snapped)
        }
        return out
    }

    private fun isIntegerMultiple(a: Double, b: Double): Boolean {
        val hi = max(a, b)
        val lo = min(a, b)
        if (lo <= 0) return false
        val ratio = hi / lo
        val nearest = round(ratio)
        return nearest >= 1 && abs(ratio - nearest) < 0.06
    }

}
