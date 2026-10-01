package com.opencapture.opencine.insta360.luna

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.math.BigInteger
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Pure JVM codec, ported from this repository's hardware-verified Python lab. */
internal object LunaWire {
    val prefix = hex("11000000060000affaaffaaffaaffaaffa")
    val liveBody = hex("10012080f702382b500e6001")
    fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    fun checksum(data: ByteArray): Int {
        var crc = -1
        for (byte in data) {
            crc = crc xor (byte.toInt() and 255)
            repeat(32) { crc = (crc shl 1) xor (if (crc < 0) 0x04c11db7 else 0) }
        }
        return crc
    }
    fun le(size: Int): ByteBuffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
    fun intAt(bytes: ByteArray, offset: Int): Int = ByteBuffer.wrap(bytes, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int
    fun encode(sequence: Int, payload: ByteArray, key: ByteArray? = null, type: Int = 4): ByteArray {
        val header = "UCD2".toByteArray() + byteArrayOf(1, if (key == null) 12 else 43, type.toByte(), sequence.toByte()) + le(4).putInt(payload.size).array()
        val packet = if (key == null) header + payload else {
            require(key.size == 16)
            val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(header)
            val encrypted = cipher.doFinal(payload)
            header + byteArrayOf(0x40, 0x1d, 3) + nonce + encrypted.takeLast(16).toByteArray() + encrypted.dropLast(16).toByteArray()
        }
        return packet + le(4).putInt(checksum(packet)).array()
    }
    fun request(code: Int, id: Int, body: ByteArray): ByteArray = le(9).putShort(code.toShort()).put(2).putInt(id or Int.MIN_VALUE).putShort(0).array() + body
    data class Frame(val raw: ByteArray) {
        val type get() = raw[6].toInt() and 255
        val encrypted get() = raw[5].toInt() == 43
        val payload get() = raw.copyOfRange(raw[5].toInt() and 255, raw.size - 4)
        fun message(key: ByteArray?): Message? {
            if (type != 4) return null
            val bytes = if (!encrypted) { require(raw[5].toInt() == 12); payload } else {
                require(key?.size == 16 && raw.sliceArray(12..14).contentEquals(byteArrayOf(0x40, 0x1d, 3)))
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, raw.copyOfRange(15, 27)))
                cipher.updateAAD(raw.copyOfRange(0, 12))
                cipher.doFinal(payload + raw.copyOfRange(27, 43))
            }
            // Content type 2 is protobuf; 1 is raw bytes (cmd 11 NV12 thumbnail reply).
            require(bytes.size >= 9 && bytes[2].toInt() in 1..2)
            return Message((bytes[0].toInt() and 255) or ((bytes[1].toInt() and 255) shl 8), intAt(bytes, 3) and 0x3fffffff, bytes.copyOfRange(9, bytes.size), encrypted)
        }
    }
    data class Message(val code: Int, val id: Int, val body: ByteArray, val encrypted: Boolean)
    class Parser {
        private var pending = ByteArray(0)
        @Synchronized fun feed(data: ByteArray): List<Frame> {
            require(pending.size + data.size <= 8 * 1024 * 1024) { "Receive buffer exceeded limit" }
            pending += data
            val result = ArrayList<Frame>()
            while (pending.size >= 12) {
                if (!pending.copyOfRange(0, 4).contentEquals("UCD2".toByteArray())) { pending = pending.copyOfRange(1, pending.size); continue }
                val headerSize = pending[5].toInt() and 255
                val size = intAt(pending, 8).toLong() and 0xffffffffL
                require(pending[4].toInt() == 1 && headerSize >= 12 && size <= 4 * 1024 * 1024) { "Invalid UCD2 frame header" }
                val total = headerSize + size.toInt() + 4
                if (pending.size < total) break
                val packet = pending.copyOfRange(0, total)
                require(checksum(packet.copyOfRange(0, total - 4)) == intAt(packet, total - 4)) { "UCD2 checksum mismatch" }
                result += Frame(packet)
                pending = pending.copyOfRange(total, pending.size)
            }
            return result
        }
    }
    /** A negative number encodes as its unsigned 64-bit value (ten bytes), like protobuf int32/int64. */
    fun varint(number: Long): ByteArray {
        var value = number; val out = ByteArrayOutputStream()
        while (value !in 0..127) { out.write((value.toInt() and 127) or 128); value = value ushr 7 }
        out.write(value.toInt()); return out.toByteArray()
    }
    fun integer(field: Int, number: Long): ByteArray = varint((field.toLong() shl 3)) + varint(number)
    fun blob(field: Int, bytes: ByteArray): ByteArray = varint((field.toLong() shl 3) or 2) + varint(bytes.size.toLong()) + bytes
    fun options(vararg fields: Int): ByteArray = fields.fold(ByteArray(0)) { result, number -> result + integer(1, number.toLong()) }
    data class Field(val number: Int, val wire: Int, val value: Long = 0, val bytes: ByteArray = ByteArray(0))
    fun fields(data: ByteArray): List<Field> {
        var at = 0
        fun read(): Long {
            var value = 0L
            for (shift in 0..63 step 7) {
                require(at < data.size) { "Truncated protobuf varint" }
                val next = data[at++].toInt() and 255
                require(shift != 63 || next <= 1) { "Protobuf varint overflow" }
                value = value or ((next and 127).toLong() shl shift)
                if (next and 128 == 0) return value
            }
            error("Protobuf varint overflow")
        }
        val result = ArrayList<Field>()
        while (at < data.size) {
            val tag = read(); val number = (tag ushr 3).toInt(); val wire = (tag and 7).toInt()
            require(number in 1 until (1 shl 29))
            if (wire == 0) result += Field(number, wire, read()) else {
                val length = when (wire) { 1 -> 8L; 2 -> read(); 5 -> 4L; else -> error("Unsupported protobuf field") }
                require(length >= 0 && length <= data.size - at)
                result += Field(number, wire, bytes = data.copyOfRange(at, at + length.toInt())); at += length.toInt()
            }
        }
        return result
    }
    fun number(data: ByteArray, field: Int, default: Long = 0): Long = fields(data).lastOrNull { it.number == field && it.wire == 0 }?.value ?: default
    fun bytes(data: ByteArray, field: Int): ByteArray = fields(data).lastOrNull { it.number == field && it.wire == 2 }?.bytes ?: ByteArray(0)
    fun text(data: ByteArray, field: Int): String = bytes(data, field).toString(Charsets.UTF_8)
    fun schemes(data: ByteArray): List<Long> = fields(data).filter { it.number == 1 }.flatMap { field ->
        when (field.wire) {
            0 -> listOf(field.value)
            2 -> {
                // Packed repeated varints; reuse the bounded protobuf parser after tagging each value.
                val values = ArrayList<Long>(); var at = 0
                while (at < field.bytes.size) {
                    val start = at
                    do { require(at < field.bytes.size); val value = field.bytes[at++].toInt() and 255 } while (value and 128 != 0)
                    values += number(byteArrayOf(8) + field.bytes.copyOfRange(start, at), 1)
                }
                values
            }
            else -> error("Invalid encryption capability field")
        }
    }
    fun keyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    fun publicBytes(pair: KeyPair): ByteArray {
        val point = (pair.public as ECPublicKey).w
        fun fixed(value: BigInteger): ByteArray { val source = value.toByteArray(); return ByteArray(32).also { source.takeLast(32).toByteArray().copyInto(it, 32 - minOf(32, source.size)) } }
        return byteArrayOf(4) + fixed(point.affineX) + fixed(point.affineY)
    }
    fun derive(secret: ByteArray): ByteArray {
        fun hmac(key: ByteArray, body: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(key, "HmacSHA256")); doFinal(body) }
        return hmac(hmac("UCD2-ENCRYPT".toByteArray(), secret), "AES-SESSION-KEY".toByteArray() + byteArrayOf(1)).copyOfRange(0, 16)
    }
    fun exchange(pair: KeyPair, reply: ByteArray): ByteArray {
        require(number(reply, 1) == 1L) { "Camera rejected encryption key exchange" }
        val encoded = bytes(reply, 2); require(encoded.size == 65 && encoded[0].toInt() == 4)
        val point = ECPoint(BigInteger(1, encoded.copyOfRange(1, 33)), BigInteger(1, encoded.copyOfRange(33, 65)))
        val public = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, (pair.public as ECPublicKey).params))
        return derive(KeyAgreement.getInstance("ECDH").run { init(pair.private); doPhase(public, true); generateSecret() })
    }
}
