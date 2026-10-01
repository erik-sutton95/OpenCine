package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.CameraTrackState
import kotlin.test.*
import org.junit.Test
import kotlinx.coroutines.runBlocking

class LunaWireTest {
    private val getOptions = LunaWire.hex("55434432010c04100f0000000800020100008000000830080f080b7c008e7c")
    private val liveStart = LunaWire.hex("55434432010c0452150000000100024d000080000010012080f702382b500e6001e497c1ce")
    private val key = LunaWire.hex("25531003115702b3eb9e5327a35a97dd")
    private fun fixture(): ByteArray {
        val packet = LunaWire.hex("55434432012b04010d000000401d03000102030405060708090a0b7173624439c47060d937e9e93c8385a0dd28d4cce260a45d70b8a9e399")
        return packet + LunaWire.le(4).putInt(LunaWire.checksum(packet)).array()
    }
    @Test fun capturedChecksumAndCommand() {
        assertEquals(0x7c8e007c, LunaWire.checksum(getOptions.copyOfRange(0, getOptions.size - 4)))
        val message = LunaWire.Parser().feed(liveStart).single().message(null)!!
        assertEquals(1, message.code); assertEquals(77, message.id)
        assertContentEquals(LunaWire.liveBody, message.body)
        assertContentEquals(liveStart, LunaWire.encode(0x52, LunaWire.request(1, 77, LunaWire.liveBody)))
    }
    @Test fun everyTransportSplitAndCoalescedPackets() {
        for (cut in 1 until getOptions.size) {
            val parser = LunaWire.Parser()
            assertTrue(parser.feed(getOptions.copyOfRange(0, cut)).isEmpty())
            val frames = parser.feed(getOptions.copyOfRange(cut, getOptions.size) + liveStart)
            assertEquals(listOf(8, 1), frames.map { it.message(null)!!.code })
        }
    }
    @Test fun checksumAndLengthFailuresAreRejected() {
        val corrupt = getOptions.clone().also { it[20] = (it[20].toInt() xor 1).toByte() }
        assertFailsWith<IllegalArgumentException> { LunaWire.Parser().feed(corrupt) }
        val huge = getOptions.clone().also { LunaWire.le(4).putInt(-1).array().copyInto(it, 8) }
        assertFailsWith<IllegalArgumentException> { LunaWire.Parser().feed(huge) }
    }
    @Test fun independentHkdfAndAesGcmVector() {
        val shared = LunaWire.hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")
        assertContentEquals(key, LunaWire.derive(shared))
        val message = LunaWire.Parser().feed(fixture()).single().message(key)!!
        assertEquals(200, message.code); assertEquals(1, message.id)
        assertContentEquals(LunaWire.hex("12020801"), message.body)
    }
    @Test fun gcmRejectsTamperingWithRecomputedChecksum() {
        val packet = fixture().dropLast(4).toByteArray()
        packet[27] = (packet[27].toInt() xor 1).toByte()
        val raw = packet + LunaWire.le(4).putInt(LunaWire.checksum(packet)).array()
        assertFails { LunaWire.Parser().feed(raw).single().message(key) }
    }
    @Test fun exchangeRejectsIncorrectSuccessEnum() {
        val pair = LunaWire.keyPair()
        for (status in listOf(0L, 2L, 3L, 4L, 5L)) assertFailsWith<IllegalArgumentException> {
            LunaWire.exchange(pair, LunaWire.integer(1, status) + LunaWire.blob(2, LunaWire.publicBytes(pair)))
        }
    }
    @Test fun protobufRejectsMalformedAndKeepsLastSingularValue() {
        assertContentEquals(LunaWire.hex("08240825082b"), LunaWire.options(36, 37, 43))
        assertEquals(listOf(3L, 2L, 1L), LunaWire.schemes(LunaWire.hex("0a03030201")))
        assertEquals(listOf(3L, 2L, 1L), LunaWire.schemes(LunaWire.hex("080308020801")))
        assertFails { LunaWire.schemes(LunaWire.hex("0a0180")) }
        assertEquals(0L, LunaWire.number(LunaWire.hex("08010800"), 1))
        for (raw in listOf("0880", "120561", "00", "0b", "09616263", "08ffffffffffffffffff02")) assertFails { LunaWire.fields(LunaWire.hex(raw)) }
    }
    @Test fun encryptedRequestCannotBeSatisfiedByPlaintext() = runBlocking {
        lateinit var channel: LunaChannel
        channel = LunaChannel(send = {
            val reply = LunaWire.encode(1, LunaWire.request(200, 1, ByteArray(0)))
            channel.receive(reply)
        })
        channel.key = key.clone()
        assertFailsWith<IllegalArgumentException> { channel.request(8, encrypted = true) }
        channel.close()
    }
    @Test fun fragmentedEncryptedResponseCompletesCorrelatedRequest() = runBlocking {
        lateinit var channel: LunaChannel
        channel = LunaChannel(send = { val raw = fixture(); channel.receive(raw.copyOfRange(0, 20)); channel.receive(raw.copyOfRange(20, raw.size)) })
        channel.key = key.clone()
        assertContentEquals(LunaWire.hex("12020801"), channel.request(8, encrypted = true))
        channel.close()
    }
    @Test fun deepTrackStreamFrames() {
        // Captured 0x85 media payloads (fw 1.1.15), same vectors as Swift testDeepTrackStreamFrames.
        val frames = ArrayList<LunaTrackFrame>()
        val channel = LunaChannel(send = {}, track = { frames += it })
        for (payload in listOf(
            "85f83881020000000008c0919ac69c011005180022140d8988e03e1519357c3e1defee1e3e25dc14a33e", // idle before tracking
            "852a4c83020000000008908886879d011002180022140d2222b23e15316af83e1dabaa1a3e25b6608b3e", // locked
            "40ea4a830200000000277576f01b78843f", // not a track frame
        )) channel.receive(LunaWire.encode(0, LunaWire.hex(payload), type = 1))
        assertFalse(channel.failure.isCompleted)
        assertEquals(2, frames.size)
        assertEquals(CameraTrackState.IDLE, frames[0].shared?.state)
        val locked = assertNotNull(frames[1].shared)
        assertEquals(CameraTrackState.TRACKING, locked.state)
        assertEquals(0.348, locked.x, 0.001)
        assertEquals(0.485, locked.y, 0.001)
        assertEquals(0.151, locked.width, 0.001)
        assertEquals(0.272, locked.height, 0.001)
        assertEquals("0805", LunaControl.accessCameraFileState(LunaControl.SHOOTING_VIEW_ACCESS_STATE).body.joinToString("") { "%02x".format(it) })
    }
}
