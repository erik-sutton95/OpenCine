package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.TrackingBox

fun TrackingBox.Companion.parseNormalized(
    bytes: ByteArray,
    offset: Int = 0,
    minimum: Double = MINIMUM_NORMALIZED_SIZE,
    requireOriginFits: Boolean = true,
): TrackingBox? {
    if (bytes.size < offset + 16) return null
    val x = f32(bytes, offset) ?: return null
    val y = f32(bytes, offset + 4) ?: return null
    val width = f32(bytes, offset + 8) ?: return null
    val height = f32(bytes, offset + 12) ?: return null
    if (width < minimum || height < minimum) return null
    if (requireOriginFits && (x + width > 1.02 || y + height > 1.02)) return null
    return TrackingBox(x, y, width, height)
}

/** `0x02/0x89` notify. 23 B: 5×`00` + tag + 4×f32 LE @7, centre + size. */
fun TrackingBox.Companion.parseLivePush(payload: ByteArray): TrackingBox? {
    if (payload.size < 23) return null
    if (payload[0] != 0.toByte() || payload[1] != 0.toByte() || payload[2] != 0.toByte() ||
        payload[3] != 0.toByte() || payload[4] != 0.toByte()
    ) {
        return null
    }
    val raw = parseNormalized(payload, offset = 7, minimum = 0.02, requireOriginFits = false)
        ?: return null
    return fromCenter(raw.x, raw.y, raw.width, raw.height)
}

private fun f32(bytes: ByteArray, offset: Int): Double? {
    if (bytes.size < offset + 4) return null
    val bits =
        (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)
    val value = Float.fromBits(bits).toDouble()
    if (!value.isFinite() || value < 0.0 || value > 1.0) return null
    return value
}

sealed class TrackingPoll {
    data class Locked(val box: TrackingBox?) : TrackingPoll()
    data object Idle : TrackingPoll()

    companion object {
        fun parse(payload: ByteArray): TrackingPoll? {
            if (payload.size < 4) return null
            if (payload[0] != 0.toByte() || payload[2] != 0.toByte() || payload[3] != 0.toByte()) {
                return null
            }
            return when (payload[1].toInt() and 0xFF) {
                0x01 -> {
                    val extra = if (payload.size >= 20) payload.copyOfRange(4, payload.size) else byteArrayOf()
                    val raw = TrackingBox.parseNormalized(extra, requireOriginFits = false)
                    Locked(
                        raw?.let { TrackingBox.fromCenter(it.x, it.y, it.width, it.height) },
                    )
                }
                0x00 -> Idle
                else -> null
            }
        }
    }
}
