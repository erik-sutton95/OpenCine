package com.opencapture.opencine.dji

data class DumlFrame(
    val sender: Int,
    val receiver: Int,
    val seq: Int,
    val flags: Int,
    val cmdSet: Int,
    val cmdId: Int,
    val payload: ByteArray,
) {
    val key: Int get() = ((cmdSet and 0xFF) shl 8) or (cmdId and 0xFF)

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is DumlFrame) return false
        return sender == other.sender &&
            receiver == other.receiver &&
            seq == other.seq &&
            flags == other.flags &&
            cmdSet == other.cmdSet &&
            cmdId == other.cmdId &&
            payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int =
        sender * 31 + receiver + seq + flags + cmdSet + cmdId + payload.contentHashCode()
}

object DumlCodec {
    fun unpackFrames(packed: ByteArray?): List<DumlFrame> {
        if (packed == null || packed.size < 2) return emptyList()
        val count = (packed[0].toInt() and 0xFF) or ((packed[1].toInt() and 0xFF) shl 8)
        var offset = 2
        val out = ArrayList<DumlFrame>(count)
        repeat(count) {
            if (offset + 2 > packed.size) return out
            val len = (packed[offset].toInt() and 0xFF) or ((packed[offset + 1].toInt() and 0xFF) shl 8)
            offset += 2
            if (offset + len > packed.size || len < 7) return out
            val slice = packed.copyOfRange(offset, offset + len)
            offset += len
            val seq = (slice[2].toInt() and 0xFF) or ((slice[3].toInt() and 0xFF) shl 8)
            out.add(
                DumlFrame(
                    sender = slice[0].toInt() and 0xFF,
                    receiver = slice[1].toInt() and 0xFF,
                    seq = seq,
                    flags = slice[4].toInt() and 0xFF,
                    cmdSet = slice[5].toInt() and 0xFF,
                    cmdId = slice[6].toInt() and 0xFF,
                    payload = if (len > 7) slice.copyOfRange(7, len) else ByteArray(0),
                )
            )
        }
        return out
    }
}
