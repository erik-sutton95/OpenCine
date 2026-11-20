package com.opencapture.opencine.streaming

/** One unit of encoded media for the run controller: the twin of Swift `StreamMediaPacket`. */
sealed interface StreamMediaPacket {
    /** H.264 parameter sets without start codes. */
    class VideoConfig(val sps: ByteArray, val pps: ByteArray) : StreamMediaPacket

    /** One access unit in Annex-B form; times in ms since the stream started. */
    class Video(val annexB: ByteArray, val isKeyframe: Boolean, val decodeMs: Int, val presentMs: Int) :
        StreamMediaPacket

    class AudioConfig(val audioSpecificConfig: ByteArray) : StreamMediaPacket

    /** One raw AAC frame, without an ADTS header. */
    class Audio(val raw: ByteArray, val presentMs: Int) : StreamMediaPacket
}

/** Pure helpers over MediaCodec's encoded output. */
object StreamEncodedMedia {
    /**
     * Splits an H.264 codec-config buffer (Annex-B SPS then PPS, as MediaCodec emits it) into the
     * two parameter sets without start codes. Null when either is missing.
     */
    fun splitParameterSets(config: ByteArray): Pair<ByteArray, ByteArray>? {
        val units = nalUnits(config)
        val sps = units.firstOrNull { it.isNotEmpty() && (it[0].toInt() and 0x1F) == 7 } ?: return null
        val pps = units.firstOrNull { it.isNotEmpty() && (it[0].toInt() and 0x1F) == 8 } ?: return null
        return sps to pps
    }

    /** Whether the access unit holds an IDR slice. */
    fun hasIdr(annexB: ByteArray): Boolean = nalUnits(annexB).any { it.isNotEmpty() && (it[0].toInt() and 0x1F) == 5 }

    /** Milliseconds from [startUs] to [presentationUs], never negative. */
    fun ms(presentationUs: Long, startUs: Long): Int = ((presentationUs - startUs).coerceAtLeast(0) / 1000).toInt()

    /** The NAL units between Annex-B start codes, without trailing zero bytes. */
    fun nalUnits(bytes: ByteArray): List<ByteArray> {
        val starts = mutableListOf<Pair<Int, Int>>()
        var index = 0
        while (index + 2 < bytes.size) {
            if (bytes[index].toInt() == 0 && bytes[index + 1].toInt() == 0 && bytes[index + 2].toInt() == 1) {
                starts += index to index + 3
                index += 3
            } else {
                index += 1
            }
        }
        return starts.mapIndexedNotNull { position, (_, payload) ->
            var end = if (position + 1 < starts.size) starts[position + 1].first else bytes.size
            while (end > payload && bytes[end - 1].toInt() == 0) end -= 1
            if (end > payload) bytes.copyOfRange(payload, end) else null
        }
    }
}

/** AAC frame times from the sample count, so audio never drifts against the stream clock. */
class AacTimeline(private val sampleRate: Int) {
    fun ms(sampleIndex: Long): Int = (sampleIndex * 1000 / sampleRate).toInt()
}
