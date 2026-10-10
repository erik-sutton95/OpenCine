package com.opencapture.opencine.media

/**
 * Annex-B access-unit classification the Android live decoder keys on: IRAP detection, codec
 * detection with the NAL-type fallback, AVC SPS/PPS split and parameter-set extraction. Moved
 * from `HevcDecoder`'s companion; NAL units here keep their start codes.
 */
object LiveAccessUnit {
    /**
     * HEVC IRAP pictures (BLA 16–18, IDR 19–20, CRA 21) start a GOP.
     * Pocket 4 Pro live view uses BLA_W_LP (16), not only IDR_N_LP (20).
     * AVC IDR is 5.
     */
    fun isIdrPicture(nalTypes: String, accessUnit: ByteArray? = null): Boolean {
        val types = nalTypes.split(',').mapNotNull { it.trim().toIntOrNull() }
        if (types.any { it in 16..21 || it == 5 }) return true
        if (accessUnit == null) return false
        for (nal in annexBNals(accessUnit)) {
            val skip = startCodeLength(nal)
            if (nal.size <= skip) continue
            val first = nal[skip].toInt() and 0xFF
            val hevcType = (first shr 1) and 0x3F
            if (hevcType in 16..21) return true
            if (first and 0x1F == 5) return true
        }
        return false
    }

    /**
     * Pocket HEVC param sets are 0x40/0x42/0x44. Nano AVC SPS/PPS are 0x67/0x68.
     * Matches OpenPocketViewCore `LiveVideo.codec(ofNAL:)`. HEVC IDR_N_LP is 0x28;
     * do not treat `(first & 0x1f) ∈ {5,7,8}` as AVC or leftover P-frames configure
     * as AVC and WAITING FOR LIVE VIEW never drops.
     */
    fun detectCodec(csd: ByteArray, nalTypes: String): LiveVideoCodec? {
        var sawHevc = false
        var sawAvc = false
        for (nal in annexBNals(csd)) {
            // This detector only admits framed NALs; other legacy callers
            // retain the scanner's raw-buffer fallback.
            if (nal.size < 4 || nal[0] != 0.toByte() ||
                nal[1] != 0.toByte() || nal[2] != 1.toByte()
            ) continue
            val skip = startCodeLength(nal)
            if (nal.size <= skip) continue
            when (nal[skip].toInt() and 0xFF) {
                0x40, 0x42, 0x44 -> sawHevc = true
                0x67, 0x68 -> sawAvc = true
            }
        }
        if (sawHevc) return LiveVideoCodec.HEVC
        if (sawAvc) return LiveVideoCodec.AVC
        val types = nalTypes.split(',').mapNotNull { it.trim().toIntOrNull() }.toSet()
        if (32 in types || 33 in types || 34 in types) return LiveVideoCodec.HEVC
        return null
    }

    fun splitAvcCsd(csd: ByteArray): Pair<ByteArray, ByteArray?> {
        val nals = annexBNals(csd)
        val sps = nals.firstOrNull { nalTypeAfterStartCode(it) == 7 }
        val pps = nals.firstOrNull { nalTypeAfterStartCode(it) == 8 }
        if (sps != null) return sps to pps
        return csd to null
    }

    private fun annexBNals(data: ByteArray): List<ByteArray> {
        val starts = ArrayList<Int>()
        val privateMetadata = HashSet<Int>()
        var i = 0
        while (i + 3 <= data.size) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte()) {
                starts.add(i)
                // Match Hevc.nalRanges: the recognized raw metadata has no
                // emulation prevention, so embedded start codes are not NALs.
                if (i + 32 <= data.size && data[i + 3] == 6.toByte() &&
                    data[i + 4] == 0xF0.toByte() && data[i + 5] == 25.toByte() &&
                    data[i + 31] == 0x80.toByte()
                ) {
                    privateMetadata.add(i)
                    i += 32
                } else {
                    i += 3
                }
            } else {
                i += 1
            }
        }
        if (starts.isEmpty()) return listOf(data)
        val out = ArrayList<ByteArray>(starts.size)
        for (k in starts.indices) {
            val from = starts[k]
            if (from in privateMetadata) continue
            val to = if (k + 1 < starts.size) starts[k + 1] else data.size
            if (to > from) out.add(data.copyOfRange(from, to))
        }
        return out
    }

    private fun startCodeLength(nal: ByteArray): Int =
        if (nal.size >= 4 && nal[0] == 0.toByte() && nal[1] == 0.toByte() &&
            nal[2] == 0.toByte() && nal[3] == 1.toByte()
        ) {
            4
        } else {
            3
        }

    /**
     * The parameter-set NALs in [csd], start codes kept, in wire order.
     *
     * Only VPS/SPS/PPS decide whether MediaCodec has to be reconfigured, so only those may
     * count as a parameter-set change. Comparing whole CSD blobs makes anything else riding
     * along (an SEI whose payload varies per keyframe, a differing NAL order) look like a
     * format change: a Nano rebuilt the decoder once a second, on every IDR, to the same
     * 1280x720. This matches OpenPocketViewCore `EncoderPresentPath.parameterSetsChanged`,
     * which already compares VPS/SPS/PPS separately.
     *
     * HEVC VPS/SPS/PPS lead with 0x40/0x42/0x44; AVC SPS/PPS with 0x67/0x68, the same bytes
     * [detectCodec] keys on.
     */
    fun parameterSetNals(csd: ByteArray): ByteArray {
        val sets = ArrayList<ByteArray>()
        for (nal in annexBNals(csd)) {
            val skip = startCodeLength(nal)
            if (nal.size <= skip) continue
            when (nal[skip].toInt() and 0xFF) {
                0x40, 0x42, 0x44, 0x67, 0x68 -> sets.add(nal)
            }
        }
        if (sets.isEmpty()) return ByteArray(0)
        val merged = ByteArray(sets.sumOf { it.size })
        var at = 0
        for (nal in sets) {
            nal.copyInto(merged, at)
            at += nal.size
        }
        return merged
    }

    private fun nalTypeAfterStartCode(nal: ByteArray): Int {
        val skip = startCodeLength(nal)
        if (nal.size <= skip) return -1
        return nal[skip].toInt() and 0x1F
    }
}
