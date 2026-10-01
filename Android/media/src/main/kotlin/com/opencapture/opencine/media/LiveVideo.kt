package com.opencapture.opencine.media

import java.io.ByteArrayOutputStream

/** Which live-view codec an Annex-B access unit is. Pocket is HEVC; Nano is AVC. */
enum class LiveVideoCodec { HEVC, AVC }

/**
 * HEVC / H.265 Annex-B NAL math. Mirrors Swift `OpenCineMedia.Hevc`; vendor framing is stripped
 * by the integration before units reach these helpers.
 */
object Hevc {
    const val VPS = 32
    const val SPS = 33
    const val PPS = 34

    /** HEVC NAL unit type from the first header byte: `(b >> 1) & 0x3f`. */
    fun nalType(firstByte: Byte): Int = (firstByte.toInt() shr 1) and 0x3F

    /** IRAP pictures: BLA 16 to 18, IDR 19 and 20, CRA 21. */
    fun isIrap(type: Int): Boolean = type in 16..21

    fun isKeyframeNal(type: Int): Boolean = type == VPS || type == SPS || type == PPS || isIrap(type)

    /**
     * Non-empty NAL payload ranges (start codes removed). A 4-byte start code's leading zero is
     * trimmed from the previous NAL. Nano SEI payload 0xF0 carries 25 raw DJI metadata bytes
     * without emulation prevention, so its contents are skipped by length.
     */
    fun nalRanges(annexB: ByteArray): List<IntRange> {
        val starts = ArrayList<Int>()
        val privateMetadata = HashSet<Int>()
        var i = 0
        while (i + 3 <= annexB.size) {
            if (annexB[i] == ZERO && annexB[i + 1] == ZERO && annexB[i + 2] == ONE) {
                starts.add(i + 3)
                if (i + 32 <= annexB.size && annexB[i + 3] == 6.toByte() &&
                    annexB[i + 4] == 0xF0.toByte() && annexB[i + 5] == 25.toByte() &&
                    annexB[i + 31] == 0x80.toByte()
                ) {
                    privateMetadata.add(i + 3)
                    i += 32
                } else {
                    i += 3
                }
            } else {
                i += 1
            }
        }
        val nals = ArrayList<IntRange>(starts.size)
        for ((k, s) in starts.withIndex()) {
            if (s in privateMetadata) continue
            var e = if (k + 1 < starts.size) starts[k + 1] - 3 else annexB.size
            while (e > s && annexB[e - 1] == ZERO) e -= 1 // ponytail: also drops a genuine trailing 0x00; harmless for decode
            if (e > s) nals.add(s until e)
        }
        return nals
    }

    /** First header byte of every NAL [nalRanges] finds. */
    fun nalHeaders(annexB: ByteArray): List<Byte> = nalRanges(annexB).map { annexB[it.first] }

    private const val ZERO: Byte = 0
    private const val ONE: Byte = 1
}

/** H.264 / AVC NAL math. Mirrors Swift `OpenCineMedia.Avc`. */
object Avc {
    const val IDR = 5
    const val SPS = 7
    const val PPS = 8

    fun nalType(firstByte: Byte): Int = firstByte.toInt() and 0x1F

    fun isKeyframeNal(type: Int): Boolean = type == SPS || type == PPS || type == IDR
}

/** Per-unit codec classification. Mirrors Swift `OpenCineMedia.LiveVideo`. */
object LiveVideo {
    /**
     * Parameter sets are unambiguous; slices alone are not classified. HEVC IDR_N_LP (0x28) is
     * also AVC PPS with nal_ref_idc=1, and AVC P-slice 0x41 reads as HEVC type 32.
     */
    fun codecOfNal(firstByte: Byte): LiveVideoCodec? =
        when (firstByte.toInt() and 0xFF) {
            0x40, 0x42, 0x44 -> LiveVideoCodec.HEVC
            0x67, 0x68 -> LiveVideoCodec.AVC
            else -> null
        }

    fun detect(annexB: ByteArray): LiveVideoCodec? = detectHeaders(Hevc.nalHeaders(annexB))

    private fun detectHeaders(headers: List<Byte>): LiveVideoCodec? = headers.firstNotNullOfOrNull(::codecOfNal)

    /** Parameter sets or a random-access picture under [codec]. */
    fun accessUnitCarriesKeyframe(annexB: ByteArray, codec: LiveVideoCodec): Boolean =
        Hevc.nalHeaders(annexB).any { isKeyframe(it, codec) }

    // The three below replace the app's `SwiftCore.hevcCsd`, `hevcNalTypes` and `hevcIsKeyframe`
    // JNI calls. Each reads the codec from the unit itself, HEVC when it carries no parameter set.
    // Fixtures/live-video-nal-vectors.tsv pins them to the Swift answers.

    /** Parameter sets or a random-access picture, typed by the unit's own codec. */
    fun accessUnitCarriesKeyframe(annexB: ByteArray): Boolean =
        accessUnitCarriesKeyframe(annexB, detect(annexB) ?: LiveVideoCodec.HEVC)

    /**
     * The unit's parameter-set NALs (HEVC VPS/SPS/PPS, or AVC SPS/PPS), each behind a 4-byte
     * start code, in stream order; null when it carries none.
     */
    fun parameterSetAnnexB(annexB: ByteArray): ByteArray? {
        val ranges = Hevc.nalRanges(annexB)
        val avc = detectHeaders(ranges.map { annexB[it.first] }) == LiveVideoCodec.AVC
        val out = ByteArrayOutputStream()
        for (range in ranges) {
            val first = annexB[range.first]
            val keep =
                if (avc) Avc.nalType(first).let { it == Avc.SPS || it == Avc.PPS }
                else Hevc.nalType(first).let { it == Hevc.VPS || it == Hevc.SPS || it == Hevc.PPS }
            if (keep) {
                out.write(START_CODE)
                out.write(annexB, range.first, range.last - range.first + 1)
            }
        }
        return if (out.size() == 0) null else out.toByteArray()
    }

    /** Distinct NAL types in ascending order, comma separated (`"1,32,33"`). */
    fun nalTypeSummary(annexB: ByteArray): String {
        val headers = Hevc.nalHeaders(annexB)
        val avc = detectHeaders(headers) == LiveVideoCodec.AVC
        return headers.map { if (avc) Avc.nalType(it) else Hevc.nalType(it) }.toSortedSet().joinToString(",")
    }

    private fun isKeyframe(header: Byte, codec: LiveVideoCodec): Boolean =
        when (codec) {
            LiveVideoCodec.AVC -> Avc.isKeyframeNal(Avc.nalType(header))
            LiveVideoCodec.HEVC -> Hevc.isKeyframeNal(Hevc.nalType(header))
        }

    private val START_CODE = byteArrayOf(0, 0, 0, 1)
}
