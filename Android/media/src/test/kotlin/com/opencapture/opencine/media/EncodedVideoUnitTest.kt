package com.opencapture.opencine.media

import com.opencapture.opencine.core.StreamGeneration
import com.opencapture.opencine.core.StreamID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Mirrors Swift `EncodedVideoUnitTests`. */
class EncodedVideoUnitTest {
    private val sc = byteArrayOf(0, 0, 1)
    private val stream = StreamID()
    private val generation = StreamGeneration(3)

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    private fun assertSets(expected: List<ByteArray>, actual: List<ByteArray>) =
        assertEquals(expected.map { it.toList() }, actual.map { it.toList() })

    @Test
    fun hevcKeyframeCarriesItsParameterSets() {
        val vps = bytes(0x40, 0x01, 0x0C)
        val sps = bytes(0x42, 0x01, 0x01)
        val pps = bytes(0x44, 0x01, 0xC1)
        val idr = bytes(0x28, 0x01, 0xAA) // IDR_N_LP
        val au = sc + vps + sc + sps + sc + pps + sc + idr
        val unit = EncodedVideoUnit.fromAnnexB(
            stream, generation, au, LiveVideoCodec.HEVC,
            previousParameterSets = listOf(bytes(0x40, 0x09)), hostArrival = 10.0,
        )
        assertEquals(EncodedVideoUnit.Codec.HEVC, unit.codec)
        assertTrue(unit.isRandomAccess)
        assertSets(listOf(vps, sps, pps), unit.parameterSets)
        assertTrue(unit.payload.contentEquals(au) && unit.generation == generation && unit.stream == stream)
        assertNull(unit.presentationTime)
        assertNull(unit.format)

        // A P-slice joins mid-GOP: not random access, decodes against the stream's sets.
        val p = EncodedVideoUnit.fromAnnexB(
            stream, generation, sc + bytes(0x02, 0x01, 0xBB), LiveVideoCodec.HEVC,
            previousParameterSets = unit.parameterSets, hostArrival = 10.04, presentationTime = 1.5,
        )
        assertFalse(p.isRandomAccess)
        assertSets(listOf(vps, sps, pps), p.parameterSets)
        assertEquals(1.5, p.presentationTime)
    }

    @Test
    fun avcUsesAvcNalTypes() {
        val sps = bytes(0x67, 0x64, 0x00, 0x1F)
        val pps = bytes(0x68, 0xEE, 0x06)
        val idr = bytes(0x65, 0x88)
        val unit = EncodedVideoUnit.fromAnnexB(
            stream, generation, sc + sps + sc + pps + sc + idr, LiveVideoCodec.AVC,
            previousParameterSets = emptyList(), hostArrival = 0.0,
        )
        assertEquals(EncodedVideoUnit.Codec.AVC, unit.codec)
        assertTrue(unit.isRandomAccess)
        assertSets(listOf(sps, pps), unit.parameterSets)
        // 0x41 is an AVC P-slice, not an HEVC VPS.
        val p = EncodedVideoUnit.fromAnnexB(
            stream, generation, sc + bytes(0x41, 0x9A), LiveVideoCodec.AVC,
            previousParameterSets = unit.parameterSets, hostArrival = 0.0,
        )
        assertFalse(p.isRandomAccess)
        assertSets(listOf(sps, pps), p.parameterSets)
    }

    @Test
    fun jpegIsSelfContained() {
        val unit = EncodedVideoUnit(
            stream, generation, EncodedVideoUnit.Codec.JPEG, bytes(0xFF, 0xD8, 0xFF, 0xD9),
            isRandomAccess = true, parameterSets = emptyList(), hostArrival = 2.0,
            format = EncodedVideoUnit.Format(width = 1024, height = 576),
        )
        assertTrue(unit.isRandomAccess && unit.parameterSets.isEmpty())
        assertEquals(1024 to 576, unit.format?.uprightSize)
    }

    @Test
    fun uprightSizeSwapsOnQuarterTurns() {
        val format = EncodedVideoUnit.Format(1280, 720, EncodedVideoUnit.Rotation.CLOCKWISE_90)
        assertEquals(720 to 1280, format.uprightSize)
        assertEquals(1280 to 720, EncodedVideoUnit.Format(1280, 720, EncodedVideoUnit.Rotation.UPSIDE_DOWN).uprightSize)
        assertFalse(format.mirrored)
    }

    /** Kotlin only: arrays would otherwise compare by identity. */
    @Test
    fun equalityComparesBytesByContent() {
        fun unit(payload: ByteArray) = EncodedVideoUnit(
            stream, generation, EncodedVideoUnit.Codec.HEVC, payload,
            isRandomAccess = false, parameterSets = listOf(bytes(0x42, 1)), hostArrival = 1.0,
        )
        assertEquals(unit(bytes(1, 2)), unit(bytes(1, 2)))
        assertEquals(unit(bytes(1, 2)).hashCode(), unit(bytes(1, 2)).hashCode())
        assertNotEquals(unit(bytes(1, 2)), unit(bytes(1, 3)))
    }
}
