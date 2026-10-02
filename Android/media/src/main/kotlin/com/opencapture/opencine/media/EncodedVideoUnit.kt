package com.opencapture.opencine.media

import com.opencapture.opencine.core.StreamGeneration
import com.opencapture.opencine.core.StreamID

/**
 * One compressed picture unit as an integration hands it to a decoder runtime (plan 6.1).
 * Mirrors Swift `OpenCineMedia.EncodedVideoUnit`.
 *
 * Vendor framing is already removed. A plain value with no platform objects: codec input buffers
 * and surfaces belong to the decoder that consumes it. A decoder drops units whose [generation]
 * is older than the stream's current one. Byte arrays compare by content.
 */
class EncodedVideoUnit(
    val stream: StreamID,
    val generation: StreamGeneration,
    val codec: Codec,
    /** H.26x: one Annex-B access unit, start codes kept. JPEG: one complete image. */
    val payload: ByteArray,
    /** A decoder can start here: H.26x parameter sets or an IRAP/IDR picture; every JPEG. */
    val isRandomAccess: Boolean,
    /**
     * The parameter sets this unit decodes against (HEVC VPS/SPS/PPS, AVC SPS/PPS), start codes
     * removed, in stream order. Equal sets mean the same decoder configuration. Empty for JPEG.
     */
    val parameterSets: List<ByteArray>,
    /** Seconds on the host monotonic clock when the unit was complete (`elapsedRealtimeNanos / 1e9`). */
    val hostArrival: Double,
    /** Source presentation time in seconds, or null when the transport carries none. */
    val presentationTime: Double? = null,
    /** Null until the integration or the decoder knows it. */
    val format: Format? = null,
) {
    enum class Codec {
        HEVC,
        AVC,

        /** One complete JPEG image per unit (network live view). */
        JPEG,
    }

    /** Clockwise rotation that makes the coded raster upright. */
    enum class Rotation(val degrees: Int) {
        NONE(0),
        CLOCKWISE_90(90),
        UPSIDE_DOWN(180),
        CLOCKWISE_270(270),
    }

    /** Coded raster size in pixels; [mirrored] is horizontal, after rotation. */
    data class Format(
        val width: Int,
        val height: Int,
        val rotation: Rotation = Rotation.NONE,
        val mirrored: Boolean = false,
    ) {
        /** Size of the picture once it is upright. */
        val uprightSize: Pair<Int, Int>
            get() = when (rotation) {
                Rotation.NONE, Rotation.UPSIDE_DOWN -> width to height
                Rotation.CLOCKWISE_90, Rotation.CLOCKWISE_270 -> height to width
            }
    }

    override fun equals(other: Any?): Boolean =
        other is EncodedVideoUnit &&
            stream == other.stream &&
            generation == other.generation &&
            codec == other.codec &&
            payload.contentEquals(other.payload) &&
            isRandomAccess == other.isRandomAccess &&
            parameterSets.size == other.parameterSets.size &&
            parameterSets.indices.all { parameterSets[it].contentEquals(other.parameterSets[it]) } &&
            hostArrival == other.hostArrival &&
            presentationTime == other.presentationTime &&
            format == other.format

    override fun hashCode(): Int =
        listOf(
            stream, generation, codec, payload.contentHashCode(), isRandomAccess,
            parameterSets.map { it.contentHashCode() }, hostArrival, presentationTime, format,
        ).hashCode()

    companion object {
        /**
         * An H.26x access unit. Random access and parameter sets come from its NAL headers; a unit
         * without in-band parameter sets keeps [previousParameterSets] (the stream's current ones).
         */
        fun fromAnnexB(
            stream: StreamID,
            generation: StreamGeneration,
            annexB: ByteArray,
            codec: LiveVideoCodec,
            previousParameterSets: List<ByteArray>,
            hostArrival: Double,
            presentationTime: Double? = null,
            format: Format? = null,
        ): EncodedVideoUnit {
            val sets = Hevc.nalRanges(annexB).filter { range ->
                val first = annexB[range.first]
                when (codec) {
                    LiveVideoCodec.HEVC -> Hevc.nalType(first) in setOf(Hevc.VPS, Hevc.SPS, Hevc.PPS)
                    LiveVideoCodec.AVC -> Avc.nalType(first) in setOf(Avc.SPS, Avc.PPS)
                }
            }.map { annexB.copyOfRange(it.first, it.last + 1) }
            return EncodedVideoUnit(
                stream = stream,
                generation = generation,
                codec = if (codec == LiveVideoCodec.AVC) Codec.AVC else Codec.HEVC,
                payload = annexB,
                isRandomAccess = LiveVideo.accessUnitCarriesKeyframe(annexB, codec),
                parameterSets = sets.ifEmpty { previousParameterSets },
                hostArrival = hostArrival,
                presentationTime = presentationTime,
                format = format,
            )
        }
    }
}
