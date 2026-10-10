package com.opencapture.opencine.relayruntime

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class RelayDecodedPictureOwnerTest {
    private data class Picture(val bytes: ByteArray, val reading: RelayPictureReading, val metadata: Int)
    private class Decoder : RelayPictureDecoder<Int> {
        val sources: MutableList<UUID> = mutableListOf()
        val retired: MutableList<UUID> = mutableListOf()
        val input: MutableList<Triple<UUID, Int, ByteArray>> = mutableListOf()
        var closes: Int = 0
        var result: RelayPictureDecode? = null
        var beforeBegin: (() -> Unit)? = null
        var beforeDecode: (() -> Unit)? = null
        override fun beginSource(source: UUID): Unit { sources += source; beforeBegin?.invoke() }
        override fun decode(source: UUID, metadata: Int, bytes: ByteArray): RelayPictureDecode {
            input += Triple(source, metadata, bytes)
            beforeDecode?.invoke()
            return result ?: RelayPictureDecode(bytes)
        }
        override fun retireSource(source: UUID): Unit { retired += source }
        override fun close(): Unit { closes += 1 }
    }

    @Test
    fun jpegAndMeasuredCadenceKeepActualBytesAndTheOriginalWeights() {
        val native = Decoder()
        var nanos = 1_000_000_000L
        val owner = RelayDecodedPictureOwner(native, { metadata, bytes, reading -> Picture(bytes, reading, metadata) }, nowNanos = { nanos })
        val source = UUID.randomUUID()
        assertTrue(owner.beginSource(source))
        val bytes = byteArrayOf(1, 2, 3)
        assertTrue(owner.submit(source, 4, bytes))
        assertSame(bytes, owner.publications.replayCache.single().frame.bytes)
        assertNull(owner.publications.replayCache.single().frame.reading.framesPerSecond)
        assertEquals(source, native.input.single().first)
        assertEquals(4, owner.publications.replayCache.single().frame.metadata)
        nanos += 250_000_000L
        assertTrue(owner.submit(source, 5, bytes))
        assertEquals(4.0, owner.publications.replayCache.single().frame.reading.framesPerSecond)
        nanos += 125_000_000L
        assertTrue(owner.submit(source, 6, bytes))
        assertEquals(4.0 * 0.8 + 8.0 * 0.2, owner.publications.replayCache.single().frame.reading.framesPerSecond)
        nanos += 100_000L
        assertTrue(owner.submit(source, 7, bytes))
        assertEquals(4.0 * 0.8 + 8.0 * 0.2, owner.publications.replayCache.single().frame.reading.framesPerSecond,
            "The minimum delta is strict, as in the exercised source")
        assertTrue(owner.hasDecoded(source))
        owner.close()
    }

    @Test
    fun replacementDuringDecodeDropsOldBytesAndOldCadenceAndCannotRetireSuccessor() {
        val native = Decoder()
        val owner = RelayDecodedPictureOwner(native, { _: Int, bytes, reading -> Picture(bytes, reading, 0) }, nowNanos = { 2_000_000_000L })
        val old = UUID.randomUUID()
        val next = UUID.randomUUID()
        owner.beginSource(old)
        owner.submit(old, 1, byteArrayOf(1))
        native.beforeDecode = { native.beforeDecode = null; owner.beginSource(next) }
        assertFalse(owner.submit(old, 2, byteArrayOf(2)))
        assertTrue(owner.publications.replayCache.isEmpty())
        assertFalse(owner.hasDecoded(old))
        assertFalse(owner.hasDecoded(next))
        assertFalse(owner.retireSource(old))
        assertTrue(native.retired.isEmpty())
        assertTrue(owner.submit(next, 3, byteArrayOf(3)))
        assertContentEquals(byteArrayOf(3), owner.publications.replayCache.single().frame.bytes)
        assertNull(owner.publications.replayCache.single().frame.reading.framesPerSecond)
        assertEquals(next, owner.currentSource)
    }

    @Test
    fun projectionReplacementCannotCommitAnOldEmissionOrOverwriteNewCadence() {
        val native = Decoder()
        val old = UUID.randomUUID()
        val next = UUID.randomUUID()
        lateinit var owner: RelayDecodedPictureOwner<Int, Picture>
        var replace = false
        var nanos = 1_000_000_000L
        owner = RelayDecodedPictureOwner(native, { metadata, bytes, reading ->
            if (replace) { replace = false; owner.beginSource(next); owner.submit(next, 3, byteArrayOf(3)) }
            Picture(bytes, reading, metadata)
        }, nowNanos = { nanos })
        owner.beginSource(old)
        owner.submit(old, 1, byteArrayOf(1))
        nanos += 100_000_000L
        replace = true
        assertFalse(owner.submit(old, 2, byteArrayOf(2)))
        assertContentEquals(byteArrayOf(3), owner.publications.replayCache.single().frame.bytes)
        assertNull(owner.publications.replayCache.single().frame.reading.framesPerSecond)
        nanos += 250_000_000L
        owner.submit(next, 4, byteArrayOf(4))
        assertEquals(4.0, owner.publications.replayCache.single().frame.reading.framesPerSecond)
    }

    @Test
    fun actualExhaustionReportsOncePerSourceAndRetiredDecoderCannotLatchSuccessor() {
        val native = Decoder()
        val owner = RelayDecodedPictureOwner(native, { _: Int, bytes, reading -> Picture(bytes, reading, 0) })
        val old = UUID.randomUUID()
        val next = UUID.randomUUID()
        val reports = mutableListOf<UUID>()
        owner.onExhausted = { reports += it }
        native.result = RelayPictureDecode(null, exhausted = true)
        owner.beginSource(old)
        repeat(3) { assertFalse(owner.submit(old, 0, ByteArray(0))) }
        assertEquals(listOf(old), reports)
        native.beforeDecode = { native.beforeDecode = null; owner.beginSource(next) }
        assertFalse(owner.submit(old, 0, ByteArray(0)))
        assertEquals(listOf(old), reports)
        assertFalse(owner.submit(next, 0, ByteArray(0)))
        assertEquals(listOf(old, next), reports)
        assertFalse(owner.hasDecoded(next))
    }

    @Test
    fun reentrantBeginCannotClaimAnOlderSourceAndNativeRetirementIsScoped() {
        val native = Decoder()
        val owner = RelayDecodedPictureOwner(native, { _: Int, bytes, reading -> Picture(bytes, reading, 0) })
        val old = UUID.randomUUID()
        val next = UUID.randomUUID()
        native.beforeBegin = { native.beforeBegin = null; assertTrue(owner.beginSource(next)) }
        assertFalse(owner.beginSource(old))
        assertEquals(next, owner.currentSource)
        assertFalse(owner.retireSource(old))
        assertTrue(owner.retireSource(next))
        assertEquals(listOf(next), native.retired)
        assertNull(owner.currentSource)
        assertFalse(owner.submit(next, 0, ByteArray(0)))
        owner.close()
        owner.close()
        assertEquals(1, native.closes)
        assertFalse(owner.beginSource(UUID.randomUUID()))
    }

    @Test
    fun closeDuringFrameProjectionProducesNoLatePixelsOrDecodedEvidence() {
        val native = Decoder()
        lateinit var owner: RelayDecodedPictureOwner<Int, Picture>
        owner = RelayDecodedPictureOwner(native, { metadata, bytes, reading -> owner.close(); Picture(bytes, reading, metadata) })
        val source = UUID.randomUUID()
        owner.beginSource(source)
        assertFalse(owner.submit(source, 0, byteArrayOf(1)))
        assertTrue(owner.publications.replayCache.isEmpty())
        assertFalse(owner.hasDecoded(source))
        assertEquals(1, native.closes)
    }
}
