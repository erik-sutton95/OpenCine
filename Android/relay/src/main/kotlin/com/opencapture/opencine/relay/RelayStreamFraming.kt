package com.opencapture.opencine.relay

/** `[u32be length including kind][u8 kind][payload]`, shared by the deployed stream codecs. */
public object RelayStreamFraming {
    public const val HEADER_BYTES: Int = 5

    public data class Decoded(public val kind: Int, public val payload: ByteArray, public val consumedBytes: Int)

    public sealed class DecodeError(message: String) : Exception(message) {
        public class PayloadTooLarge(public val declared: Long) : DecodeError("Invalid relay length $declared")
        public class UnknownKind(public val kind: Int) : DecodeError("Unknown relay kind $kind")
    }

    public fun encode(kind: Int, payload: ByteArray): ByteArray {
        require(kind in 0..255)
        val declared = payload.size.toLong() + 1L
        require(declared <= Int.MAX_VALUE - 4L)
        val output = ByteArray(HEADER_BYTES + payload.size)
        writeLength(declared.toInt(), output)
        output[4] = kind.toByte()
        payload.copyInto(output, HEADER_BYTES)
        return output
    }

    public fun decode(buffer: ByteArray, profile: RelayWireProfile, available: Int = buffer.size): Decoded? {
        require(available in 0..buffer.size)
        if (available < HEADER_BYTES) return null
        val declared = readLength(buffer)
        if (declared < 1L) throw DecodeError.PayloadTooLarge(declared)
        if (declared - 1L > profile.maximumPayloadBytes) throw DecodeError.PayloadTooLarge(declared - 1L)
        val total = 4L + declared
        if (available.toLong() < total) return null
        val kind = buffer[4].toInt() and 0xFF
        if (kind !in profile.messageKinds) throw DecodeError.UnknownKind(kind)
        return Decoded(kind, buffer.copyOfRange(HEADER_BYTES, total.toInt()), total.toInt())
    }

    internal fun readLength(bytes: ByteArray): Long =
        ((bytes[0].toLong() and 0xFF) shl 24) or
            ((bytes[1].toLong() and 0xFF) shl 16) or
            ((bytes[2].toLong() and 0xFF) shl 8) or (bytes[3].toLong() and 0xFF)

    internal fun writeLength(length: Int, bytes: ByteArray): Unit {
        bytes[0] = (length ushr 24).toByte()
        bytes[1] = (length ushr 16).toByte()
        bytes[2] = (length ushr 8).toByte()
        bytes[3] = length.toByte()
    }
}

/** One stream's framing state; the socket owner confines it to one executor/receive batch. */
public class RelayStreamBuffer(public val profile: RelayWireProfile) {
    private var buffer: ByteArray = ByteArray(0)
    public val pendingByteCount: Int get() = buffer.size

    public fun append(bytes: ByteArray): List<RelayStreamFraming.Decoded> {
        buffer += bytes
        val messages = mutableListOf<RelayStreamFraming.Decoded>()
        while (true) {
            val message = RelayStreamFraming.decode(buffer, profile) ?: break
            buffer = buffer.copyOfRange(message.consumedBytes, buffer.size)
            messages += message
        }
        return messages
    }

    public fun reset(): Unit { buffer = ByteArray(0) }
}

/** SDK JSON codecs supply metadata bytes. The shared blob owner preserves opaque picture bytes. */
public object RelayFrameBlob {
    public class Truncated(public val declared: Long) : Exception("Truncated relay metadata $declared")
    public data class Decoded(public val metadata: ByteArray, public val image: ByteArray)

    public fun encode(metadata: ByteArray, image: ByteArray): ByteArray {
        val output = ByteArray(4 + metadata.size + image.size)
        RelayStreamFraming.writeLength(metadata.size, output)
        metadata.copyInto(output, 4)
        image.copyInto(output, 4 + metadata.size)
        return output
    }

    public fun decode(payload: ByteArray): Decoded {
        if (payload.size < 4) throw Truncated(payload.size.toLong())
        val count = RelayStreamFraming.readLength(payload)
        if (count > payload.size - 4L) throw Truncated(count)
        val split = 4 + count.toInt()
        return Decoded(payload.copyOfRange(4, split), payload.copyOfRange(split, payload.size))
    }
}

/** One-byte JSON envelope bytes; schemas and SDK JSON conversion remain typed codec adapters. */
public object RelayEnvelopeFraming {
    public sealed class DecodeError(message: String) : Exception(message) {
        public class Empty : DecodeError("Empty relay envelope")
        public class UnknownKind(public val kind: Int) : DecodeError("Unknown relay kind $kind")
    }
    public fun encode(kind: Int, payload: ByteArray): ByteArray {
        require(kind in 0..255)
        return byteArrayOf(kind.toByte()) + payload
    }
    public fun kind(envelope: ByteArray, admittedKinds: Set<Int>): Int {
        if (envelope.isEmpty()) throw DecodeError.Empty()
        val kind = envelope[0].toInt() and 0xFF
        if (kind !in admittedKinds) throw DecodeError.UnknownKind(kind)
        return kind
    }
    public fun payload(envelope: ByteArray): ByteArray {
        if (envelope.isEmpty()) throw DecodeError.Empty()
        return envelope.copyOfRange(1, envelope.size)
    }
}
