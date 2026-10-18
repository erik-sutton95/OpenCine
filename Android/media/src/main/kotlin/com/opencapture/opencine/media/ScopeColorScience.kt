package com.opencapture.opencine.media

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.log2
import kotlin.math.pow
import kotlin.math.round
import kotlin.math.sqrt

enum class MonitorTransfer {
    REC709,
    HDR,
    DLOG,
    DLOG2,
    DLOGM,
    ILOG,
    /** Display-referred stills curve (IEC 61966-2-1). */
    SRGB,
    NLOG,
    LOG3G10,
    ;

    val peakLinear: Double
        get() =
            when (this) {
                REC709 -> 1.0
                HDR -> Hlg.decode(1.0)
                DLOG -> DLog.PEAK_LINEAR
                DLOG2 -> DLog2.PEAK_LINEAR
                DLOGM -> DLogM.decode(1.0)
                ILOG -> ILog.PEAK_LINEAR
                SRGB -> 1.0
                NLOG -> NLog.PEAK_LINEAR
                LOG3G10 -> Log3G10.PEAK_LINEAR
            }

    val middleGrayEncoded: Double
        get() = LiveColorScience.encode(0.18, this)

    val middleGrayPaperIRE: Double
        get() = LiveColorScience.paperIRE(middleGrayEncoded)

    fun scopeAnchors(iso: Int? = null, ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED): ScopeAnchors =
        ScopeAnchors.make(this, iso, ceiling)

    companion object {}
}

/** Per-transfer anchors on the tap's curve-fraction axis (`byte / 255`). */
data class ScopeAnchors(
    val black: Double,
    val mid: Double,
    val clip: Double,
    val midLevel: Double,
    val clipEdgeByte: Int,
    val clipFloorByte: Int,
    val crushFloorByte: Int,
    val crushEdgeByte: Int,
) {
    companion object {
        fun make(transfer: MonitorTransfer, iso: Int? = null, ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED): ScopeAnchors {
            val black = if (transfer == MonitorTransfer.DLOGM) 0.0 else LiveColorScience.encode(0.0, transfer)
            val mid = LiveColorScience.encode(0.18, transfer)
            val clip = ceiling.clipEncoded(transfer, iso)
            val midLevel =
                ScopeDisplayScale.CRUSH_LEVEL +
                    LiveColorScience.paperIRE(mid) / 100.0 *
                        (ScopeDisplayScale.CLIP_LEVEL - ScopeDisplayScale.CRUSH_LEVEL)
            val clipEdge = ceiling.clipByte(transfer, iso)
            val span = maxOf(0.0, clip - black) * 255
            val crushFloor = floor(black * 255).toInt()
            val crushEdge = ceil(black * 255 + 0.02 * span).toInt()
            // iOS `ScopeAnchors.make`: the clip shelf every clip tool shares, not WAVE 95.
            val clipFloor = maxOf(0, clipEdge - ScopeExposureCeiling.CLIP_SHELF_CODES)
            return ScopeAnchors(
                black = black,
                mid = mid,
                clip = clip,
                midLevel = midLevel,
                clipEdgeByte = clipEdge,
                clipFloorByte = clipFloor,
                crushFloorByte = crushFloor,
                crushEdgeByte = crushEdge,
            )
        }
    }
}

/**
 * HISTO / PARADE / ZEBRA / FALSE / LIGHTS axis. WAVE drawing uses [WaveformIre]
 * (0 / 100 on the plot edges) instead of the leftover 5% shelf.
 */
object ScopeDisplayScale {
    const val CRUSH_LEVEL = 0.05
    const val CLIP_LEVEL = 0.95

    fun waveformLevel(c: Double, transfer: MonitorTransfer, iso: Int? = null, ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED): Double {
        val a = ScopeAnchors.make(transfer, iso, ceiling)
        val v = minOf(1.0, maxOf(0.0, c))
        if (v < a.black) {
            return if (a.black <= 0) CRUSH_LEVEL else v / a.black * CRUSH_LEVEL
        }
        if (a.clip <= a.mid || a.mid <= a.black) {
            if (v <= a.clip) {
                return CRUSH_LEVEL +
                    (v - a.black) / maxOf(a.clip - a.black, 1e-9) * (CLIP_LEVEL - CRUSH_LEVEL)
            }
            return overshoot(v, a.clip)
        }
        if (v <= a.mid) {
            return CRUSH_LEVEL + (v - a.black) / (a.mid - a.black) * (a.midLevel - CRUSH_LEVEL)
        }
        if (v <= a.clip) {
            return a.midLevel + (v - a.mid) / (a.clip - a.mid) * (CLIP_LEVEL - a.midLevel)
        }
        return overshoot(v, a.clip)
    }

    fun level(scaleIRE: Double): Double = CRUSH_LEVEL + scaleIRE / 100.0 * (CLIP_LEVEL - CRUSH_LEVEL)

    fun monitorPercent(
        c: Double,
        transfer: MonitorTransfer,
        iso: Int? = null,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
    ): Double {
        val level = waveformLevel(c, transfer, iso, ceiling)
        return minOf(100.0, maxOf(0.0, (level - CRUSH_LEVEL) / (CLIP_LEVEL - CRUSH_LEVEL) * 100))
    }

    /** Normalized tap code whose [monitorPercent] equals `percent`. iOS `ScopeDisplayScale.signalNative`. */
    fun signalNative(
        monitorPercent: Double,
        transfer: MonitorTransfer,
        iso: Int? = null,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
    ): Double {
        val a = ScopeAnchors.make(transfer, iso, ceiling)
        val p = minOf(100.0, maxOf(0.0, monitorPercent))
        if (p <= 0.0) return a.black
        if (p >= 100.0) return a.clip
        val target = CRUSH_LEVEL + p / 100.0 * (CLIP_LEVEL - CRUSH_LEVEL)
        if (a.clip <= a.mid || a.mid <= a.black) {
            return a.black + p / 100.0 * (a.clip - a.black)
        }
        if (target <= a.midLevel) {
            val t = (target - CRUSH_LEVEL) / maxOf(a.midLevel - CRUSH_LEVEL, 1e-9)
            return a.black + t * (a.mid - a.black)
        }
        val t = (target - a.midLevel) / maxOf(CLIP_LEVEL - a.midLevel, 1e-9)
        return a.mid + t * (a.clip - a.mid)
    }

    private fun overshoot(v: Double, clip: Double): Double {
        val headroom = 1.0 - clip
        if (headroom <= 0) return CLIP_LEVEL
        return CLIP_LEVEL + (v - clip) / headroom * (1.0 - CLIP_LEVEL)
    }
}

/**
 * WAVE plot IRE: 0 = paper black, 100 = live-tap clip, 18% grey = paper IRE.
 * Native-code histogram remap lands paper black on bucket 0 and clip on 255.
 */
object WaveformIre {
    fun ire(encoded: Double, transfer: MonitorTransfer, iso: Int? = null, ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED): Double {
        val a = ScopeAnchors.make(transfer, iso, ceiling)
        val blackByte = round(a.black * 255)
        if (!encoded.isFinite() || encoded * 255 <= blackByte) return 0.0
        if (encoded >= a.clip) return 100.0
        val midIRE = LiveColorScience.paperIRE(a.mid)
        if (a.mid <= a.black || a.clip <= a.mid) {
            return (encoded - a.black) / maxOf(a.clip - a.black, 1e-9) * 100
        }
        if (encoded <= a.mid) {
            return (encoded - a.black) / (a.mid - a.black) * midIRE
        }
        return midIRE + (encoded - a.mid) / (a.clip - a.mid) * (100 - midIRE)
    }

    fun remapHistogram(
        bins: IntArray,
        transfer: MonitorTransfer,
        iso: Int? = null,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
    ): IntArray = ScopeLevelAxis.of(transfer, iso, ceiling).remapHistogram(bins)

    fun levelTable(transfer: MonitorTransfer, iso: Int? = null, ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED): FloatArray {
        return FloatArray(256) { ire(it / 255.0, transfer, iso, ceiling).toFloat() }
    }

    fun middleGrayIRE(transfer: MonitorTransfer): Double = transfer.middleGrayPaperIRE
}

/**
 * Where each tap code lands on the 0..100 WAVE axis, and where the mid-grey guide sits. A shared
 * transfer builds it from its anchors; a source that owns a measured placement supplies the table
 * and grey line itself. iOS `ScopeLevelAxis`.
 */
class ScopeLevelAxis(val table: FloatArray, val middleGrayIre: Double, val supportsCalibratedReferences: Boolean = true) {
    init {
        require(table.size == 256) { "ScopeLevelAxis needs one axis value per tap code" }
    }

    /** Native-code histogram counts onto this axis. Conserves total count. */
    fun remapHistogram(bins: IntArray): IntArray {
        val out = IntArray(256)
        for (code in 0 until minOf(bins.size, 256)) {
            val count = bins[code]
            if (count == 0) continue
            val bucket = round(table[code] / 100.0 * 255).toInt().coerceIn(0, 255)
            out[bucket] += count
        }
        return out
    }

    override fun equals(other: Any?): Boolean =
        other is ScopeLevelAxis && middleGrayIre == other.middleGrayIre &&
            supportsCalibratedReferences == other.supportsCalibratedReferences && table.contentEquals(other.table)

    override fun hashCode(): Int = 31 * (31 * table.contentHashCode() + middleGrayIre.hashCode()) + supportsCalibratedReferences.hashCode()

    companion object {
        /** Encoded-code percentage. The unused grey field cannot supply a calibrated reference. */
        val rawCodes: ScopeLevelAxis get() = ScopeLevelAxis(FloatArray(256) { it / 255f * 100f }, 0.0, false)
        fun of(
            transfer: MonitorTransfer,
            iso: Int? = null,
            ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
        ): ScopeLevelAxis =
            ScopeLevelAxis(WaveformIre.levelTable(transfer, iso, ceiling), WaveformIre.middleGrayIRE(transfer))
    }
}

data class ScopeChannelLight(
    val clip: Boolean,
    val crush: Boolean,
    val level: Double,
) {
    val isNeutral: Boolean
        get() = abs(level - 0.5) <= 0.03
}

data class ScopeTrafficLightsReading(
    val red: ScopeChannelLight,
    val green: ScopeChannelLight,
    val blue: ScopeChannelLight,
) {
    val anyClip: Boolean
        get() = red.clip || green.clip || blue.clip
    val anyCrush: Boolean
        get() = red.crush || green.crush || blue.crush

    companion object {
        val NONE =
            ScopeTrafficLightsReading(
                ScopeChannelLight(clip = false, crush = false, level = 0.5),
                ScopeChannelLight(clip = false, crush = false, level = 0.5),
                ScopeChannelLight(clip = false, crush = false, level = 0.5),
            )
    }
}

object ScopeTrafficLights {
    const val DEFAULT_THRESHOLD = 0.0
    const val HOLD_RATIO = 0.5

    fun reading(
        red: IntArray,
        green: IntArray,
        blue: IntArray,
        transfer: MonitorTransfer,
        threshold: Double = DEFAULT_THRESHOLD,
        previous: ScopeTrafficLightsReading? = null,
        luma: IntArray? = null,
        ceiling: ScopeClipSource = ScopeExposureCeiling.UNOBSERVED,
    ): ScopeTrafficLightsReading {
        val a = transfer.scopeAnchors(ceiling = ceiling)
        val redClip = edgeEnergy(red, a.clipFloorByte, 255)
        val greenClip = edgeEnergy(green, a.clipFloorByte, 255)
        val blueClip = edgeEnergy(blue, a.clipFloorByte, 255)
        val lumaClip = luma?.let { edgeEnergy(it, a.clipFloorByte, 255) } ?: 0.0
        val pictureClip =
            lumaClip > threshold || redClip > threshold || greenClip > threshold || blueClip > threshold
        val pictureEnergy = maxOf(lumaClip, redClip, greenClip, blueClip)
        return ScopeTrafficLightsReading(
            channel(red, transfer, threshold, redClip, pictureEnergy, pictureClip, previous?.red, ceiling),
            channel(green, transfer, threshold, greenClip, pictureEnergy, pictureClip, previous?.green, ceiling),
            channel(blue, transfer, threshold, blueClip, pictureEnergy, pictureClip, previous?.blue, ceiling),
        )
    }

    private fun channel(
        bins: IntArray,
        transfer: MonitorTransfer,
        threshold: Double,
        ownClipEnergy: Double,
        pictureEnergy: Double,
        pictureClip: Boolean,
        previous: ScopeChannelLight?,
        ceiling: ScopeClipSource,
    ): ScopeChannelLight {
        val a = transfer.scopeAnchors(ceiling = ceiling)
        if (bins.size < 256) return ScopeChannelLight(false, false, 0.5)
        var total = 0
        for (count in bins) total += count
        if (total <= 0) return ScopeChannelLight(false, false, 0.5)
        var crushed = 0
        for (code in a.crushFloorByte..a.crushEdgeByte) {
            if (code in 0..255) crushed += bins[code]
        }
        val crushEnergy = crushed.toDouble() / total
        var seen = 0
        var median = 0
        val half = (total + 1) / 2
        for (code in 0 until 256) {
            seen += bins[code]
            if (seen >= half) {
                median = code
                break
            }
        }
        val rawClip = ownClipEnergy > threshold || pictureClip
        val clip =
            latched(rawClip, previous?.clip == true, maxOf(ownClipEnergy, pictureEnergy), threshold)
        val crush = latched(crushEnergy > threshold, previous?.crush == true, crushEnergy, threshold)
        val level =
            balance(
                ScopeDisplayScale.waveformLevel(median / 255.0, transfer, ceiling = ceiling),
                a.midLevel,
            )
        return ScopeChannelLight(clip, crush, level)
    }

    fun edgeEnergy(bins: IntArray, from: Int, to: Int): Double {
        if (bins.size < 256 || from > to || from < 0 || to > 255) return 0.0
        var total = 0
        var band = 0
        for (code in 0 until 256) {
            total += bins[code]
            if (code in from..to) band += bins[code]
        }
        if (total <= 0) return 0.0
        return band.toDouble() / total
    }

    fun latched(now: Boolean, was: Boolean, energy: Double, threshold: Double): Boolean {
        if (now) return true
        if (!was) return false
        return energy > threshold * HOLD_RATIO
    }

    fun balance(level: Double, midLevel: Double): Double {
        if (level <= midLevel) {
            if (midLevel <= 0) return 0.5
            return 0.5 * level / midLevel
        }
        val span = 1.0 - midLevel
        if (span <= 0) return 0.5
        return 0.5 + 0.5 * (level - midLevel) / span
    }
}

object LiveColorScience {
    const val SCENE_STOP_DEFAULT_CLIP = 10.5
    fun linearize(encoded: Double, transfer: MonitorTransfer): Double {
        val linear = decode(clamp01(encoded), transfer)
        if (!linear.isFinite()) return 0.0
        return maxOf(0.0, linear)
    }

    fun encode(linear: Double, transfer: MonitorTransfer): Double {
        val encoded = encodeRaw(maxOf(0.0, linear), transfer)
        if (!encoded.isFinite()) return 0.0
        return clamp01(encoded)
    }

    fun paperIRE(encoded: Double): Double = encoded * 100

    /** Stops relative to 18% grey. Zero light is −∞, never NaN. */
    fun stops(linear: Double): Double {
        val y = maxOf(0.0, linear)
        if (y <= 0.0 || !y.isFinite()) return Double.NEGATIVE_INFINITY
        return log2(y / 0.18)
    }

    fun stops(encoded: Double, transfer: MonitorTransfer): Double = stops(linearize(encoded, transfer))

    fun lumaWeights(transfer: MonitorTransfer): Triple<Double, Double, Double> =
        when (transfer) {
            MonitorTransfer.REC709, MonitorTransfer.DLOG, MonitorTransfer.DLOGM, MonitorTransfer.SRGB ->
                Triple(0.2126, 0.7152, 0.0722)
            MonitorTransfer.HDR, MonitorTransfer.DLOG2, MonitorTransfer.ILOG, MonitorTransfer.NLOG ->
                Triple(0.2627, 0.6780, 0.0593)
            // REDWideGamutRGB luminance row.
            MonitorTransfer.LOG3G10 -> Triple(0.286694, 0.842979, -0.129673)
        }

    fun monitorIRE(encoded: Double, transfer: MonitorTransfer, iso: Int? = null): Double {
        val ire = ScopeDisplayScale.monitorPercent(encoded, transfer, iso)
        if (!ire.isFinite()) return 0.0
        return ire.coerceIn(0.0, 100.0)
    }

    private fun decode(encoded: Double, transfer: MonitorTransfer): Double =
        when (transfer) {
            MonitorTransfer.REC709 -> Rec709.decode(encoded)
            MonitorTransfer.HDR -> Hlg.decode(encoded)
            MonitorTransfer.DLOG -> DLog.decode(encoded)
            MonitorTransfer.DLOG2 -> DLog2.decode(encoded)
            MonitorTransfer.DLOGM -> DLogM.decode(encoded)
            MonitorTransfer.ILOG -> ILog.decode(encoded)
            MonitorTransfer.SRGB -> Srgb.decode(encoded)
            MonitorTransfer.NLOG -> NLog.decode(encoded)
            MonitorTransfer.LOG3G10 -> Log3G10.decode(encoded)
        }

    private fun encodeRaw(linear: Double, transfer: MonitorTransfer): Double =
        when (transfer) {
            MonitorTransfer.REC709 -> Rec709.encode(linear)
            MonitorTransfer.HDR -> Hlg.encode(linear)
            MonitorTransfer.DLOG -> DLog.encode(linear)
            MonitorTransfer.DLOG2 -> DLog2.encode(linear)
            MonitorTransfer.DLOGM -> DLogM.encode(linear)
            MonitorTransfer.ILOG -> ILog.encode(linear)
            MonitorTransfer.SRGB -> Srgb.encode(linear)
            MonitorTransfer.NLOG -> NLog.encode(linear)
            MonitorTransfer.LOG3G10 -> Log3G10.encode(linear)
        }

    private fun clamp01(x: Double): Double = x.coerceIn(0.0, 1.0)
}

private object Rec709 {
    fun decode(encoded: Double): Double {
        val e = encoded
        return if (e < 0.081) e / 4.5 else ((e + 0.099) / 1.099).pow(1 / 0.45)
    }

    fun encode(linear: Double): Double {
        val l = minOf(1.0, linear)
        return if (l < 0.018) 4.5 * l else 1.099 * l.pow(0.45) - 0.099
    }
}

object Hlg {
    private const val A = 0.178_832_77
    private const val B = 0.284_668_92
    private const val C = 0.559_910_73
    private val diffuseWhite = inverseOETF(0.75)

    fun decode(encoded: Double): Double = inverseOETF(encoded.coerceIn(0.0, 1.0)) / diffuseWhite

    fun encode(linear: Double): Double = oetf((linear * diffuseWhite).coerceIn(0.0, 1.0))

    private fun oetf(scene: Double): Double =
        if (scene <= 1.0 / 12.0) sqrt(3 * scene) else A * ln(12 * scene - B) + C

    private fun inverseOETF(e: Double): Double =
        if (e <= 0.5) e * e / 3 else (exp((e - C) / A) + B) / 12
}

object DLog {
    const val PEAK_LINEAR = 42.0

    fun decode(encoded: Double): Double =
        if (encoded <= 0.14) {
            (encoded - 0.0929) / 6.025
        } else {
            (10.0.pow(3.89616 * encoded - 2.27752) - 0.0108) / 0.9892
        }

    fun encode(linear: Double): Double =
        if (linear <= 0.0078) {
            6.025 * linear + 0.0929
        } else {
            log10(linear * 0.9892 + 0.0108) * 0.256663 + 0.584555
        }
}

object DLog2 {
    const val PEAK_LINEAR = 475.0
    private const val A = 16.285_770_761_945_304
    private const val K1 = 0.059_439_938_321_493
    private const val B1 = 0.304_985_337_243_402
    private const val K2 = 2.960_935_245_492_250
    private const val B2 = 0.148_314_799_066_323
    private const val IN_LIMIT_1 = 0.18
    private const val IN_LIMIT_2 = 0.028_961_695_254_132

    fun decode(encoded: Double): Double =
        if (encoded >= B1) {
            (PEAK_LINEAR / (2.0.pow(A) - 1)) * (2.0.pow(A * encoded) - 1)
        } else if (encoded >= B2) {
            2.0.pow((encoded - B1) / K1 + log2(IN_LIMIT_1))
        } else {
            (encoded - B2) / K2 + IN_LIMIT_2
        }

    fun encode(linear: Double): Double =
        if (linear >= IN_LIMIT_1) {
            (1 / A) * log2(linear * (2.0.pow(A) - 1) / PEAK_LINEAR + 1)
        } else if (linear >= IN_LIMIT_2) {
            K1 * (log2(maxOf(linear, 1e-15)) - log2(IN_LIMIT_1)) + B1
        } else {
            K2 * (linear - IN_LIMIT_2) + B2
        }
}

/** Empirical Pocket 3 neutral fit; see docs/pocket3-dlogm-curve.md. Not sensor limits. */
private object DLogM {
    fun decode(encoded: Double): Double {
        val t = 2.0.pow(encoded * 5.612990379333496 + 0.9327186346054077) - 2.428226947784424
        val value = if (t < 0.6034245491027832) {
            t * 1.0151796340942383 + 0.5178895592689514
        } else {
            t * 1.8734303712844849
        }
        return value * (0.18 / 12.4054)
    }

    fun encode(linear: Double): Double {
        val value = linear / (0.18 / 12.4054)
        val t = if (value < 0.6034245491027832 * 1.8734303712844849) {
            (value - 0.5178895592689514) / 1.0151796340942383
        } else {
            value / 1.8734303712844849
        }
        return (log2(t + 2.428226947784424) - 0.9327186346054077) / 5.612990379333496
    }
}

/** Insta360 10-bit I-Log White Paper (June 2026), forward and inverse equations. RGB gamut is BT.2020. */
object ILog {
    const val LINEAR_CUT = 0.01104854
    const val ENCODED_CUT = 0.154402
    const val BLACK = 0.09055934
    private const val SLOPE = 5.77837328
    private const val LOG_SCALE = 0.280055
    private const val LOG_OFFSET = 0.623992
    private const val TOE_OFFSET = 0.01
    val PEAK_LINEAR = decode(1.0)

    fun decode(encoded: Double): Double =
        if (encoded < ENCODED_CUT) (encoded - BLACK) / SLOPE
        else 10.0.pow((encoded - LOG_OFFSET) / LOG_SCALE) - TOE_OFFSET

    fun encode(linear: Double): Double =
        if (linear <= LINEAR_CUT) SLOPE * linear + BLACK
        else LOG_OFFSET + LOG_SCALE * log10(linear + TOE_OFFSET)
}

/** IEC 61966-2-1 sRGB. Display-referred: linear 1.0 is display white and anything above clips. */
object Srgb {
    fun decode(encoded: Double): Double {
        val e = encoded.coerceIn(0.0, 1.0)
        return if (e <= 0.04045) e / 12.92 else ((e + 0.055) / 1.055).pow(2.4)
    }

    fun encode(linear: Double): Double {
        val l = linear.coerceIn(0.0, 1.0)
        return if (l <= 0.003_130_8) 12.92 * l else 1.055 * l.pow(1 / 2.4) - 0.055
    }
}

/** Nikon N-Log specification 1.0.0, on the 10-bit code divided by 1023. Gamut is BT.2020. */
object NLog {
    val PEAK_LINEAR = decode(1.0)

    fun decode(encoded: Double): Double {
        val code = encoded * 1023
        return if (code < 452) (code / 650).pow(3) - 0.0075 else exp((code - 619) / 150)
    }

    fun encode(linear: Double): Double =
        if (linear < 0.328) 650 * maxOf(0.0, linear + 0.0075).pow(1.0 / 3.0) / 1023
        else (150 * ln(linear) + 619) / 1023
}

/** RED Log3G10 (white paper 915-0187 Rev C). Gamut is REDWideGamutRGB. */
object Log3G10 {
    private const val A = 0.224282
    private const val B = 155.975327
    private const val C = 0.01
    private const val G = 15.1927
    val PEAK_LINEAR = decode(1.0)

    fun decode(encoded: Double): Double =
        if (encoded < 0) encoded / G - C else (10.0.pow(encoded / A) - 1) / B - C

    fun encode(linear: Double): Double =
        if (linear <= -C) (linear + C) * G else A * log10((linear + C) * B + 1)
}
