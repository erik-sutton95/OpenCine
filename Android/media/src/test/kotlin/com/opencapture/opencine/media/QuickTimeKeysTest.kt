package com.opencapture.opencine.media

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class QuickTimeKeysTest {
    private val key = "com.example.camera.Gamma"

    @Test
    fun readsTheWantedKeyFromKeysAndIlst() {
        assertEquals("Log", QuickTimeKeys.keys(movie("Log"), key)[key])
    }

    @Test
    fun findsKeysWhenOnlyTheMoovTailIsPresent() {
        val full = movie("Log", padMdat = 4096)
        val tail = full.copyOfRange(full.size - 2048, full.size)
        assertEquals("Log", QuickTimeKeys.keys(tail, key)[key])
    }

    @Test
    fun tailRangeCoversTheMoovTail() {
        assertEquals("bytes=-${QuickTimeKeys.TAIL_BYTES}", QuickTimeKeys.tailRange(0))
        assertEquals("bytes=0-99", QuickTimeKeys.tailRange(100))
        val size = QuickTimeKeys.TAIL_BYTES.toLong() + 50
        assertEquals("bytes=50-${size - 1}", QuickTimeKeys.tailRange(size))
    }

    @Test
    fun missingKeysIsEmpty() {
        assertTrue(QuickTimeKeys.keys(box("ftyp", "isomisom".toByteArray()), key).isEmpty())
    }

    @Test
    fun oversizedKeyEntryEndsTheKeyListInsteadOfThrowing() {
        val keysPayload = byteArrayOf(0, 0, 0, 0, 0, 0, 0, 1) + u32(Int.MAX_VALUE - 4) + "mdta".toByteArray()
        val hostile = box("moov", box("meta", box("keys", keysPayload)))
        assertTrue(QuickTimeKeys.keys(hostile, key).isEmpty())
    }

    @Test
    fun tailReadsTheFileEnd() {
        val bytes = movie("Log", padMdat = 4096)
        val file = File.createTempFile("opc-quicktime-keys", ".mp4")
        try {
            file.writeBytes(bytes)
            assertEquals("Log", QuickTimeKeys.keys(QuickTimeKeys.tail(file)!!, key)[key])
            file.writeBytes(ByteArray(0))
            assertNull(QuickTimeKeys.tail(file))
        } finally {
            file.delete()
        }
    }

    private fun movie(value: String, padMdat: Int = 0): ByteArray {
        var keysPayload = byteArrayOf(0, 0, 0, 0, 0, 0, 0, 1)
        val name = key.toByteArray()
        keysPayload += u32(8 + name.size) + "mdta".toByteArray() + name
        val keys = box("keys", keysPayload)
        val dataBox = box("data", u32(1) + u32(0) + value.toByteArray())
        val ilst = box("ilst", box(1, dataBox))
        val moov = box("moov", box("meta", keys + ilst))
        var file = box("ftyp", "isomisom".toByteArray())
        if (padMdat > 0) file += box("mdat", ByteArray(padMdat) { 0xAB.toByte() })
        return file + moov
    }

    private fun box(type: String, payload: ByteArray): ByteArray =
        u32(8 + payload.size) + type.toByteArray() + payload

    private fun box(fourCC: Int, payload: ByteArray): ByteArray =
        u32(8 + payload.size) + u32(fourCC) + payload

    private fun u32(value: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(value).array()
}
