package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The decoder's parameter-set blob (`LiveVideo.parameterSetAnnexB`, formerly `SwiftCore.hevcCsd`)
 * comes back for every access unit, not only parameter-set-bearing ones: on a Nano a keyframe yields 31 bytes of SPS+PPS and the next P-frame yields 16 KB carrying no
 * parameter sets at all. Comparing whole blobs alternated between the two and reported a change
 * on every access unit, so the decoder was rebuilt once a second to the same 1280x720.
 *
 * [LiveAccessUnit.parameterSetNals] is what lets the caller tell the two apart.
 */
class HevcParameterSetNalsTest {
    private val startCode = byteArrayOf(0, 0, 0, 1)

    private fun nal(lead: Int, vararg body: Int): ByteArray =
        startCode + byteArrayOf(lead.toByte()) + body.map { it.toByte() }.toByteArray()

    // Compare extraction against extraction, never against the raw input: annexBNals splits on
    // the 3-byte start code, so the first NAL of a blob written with 4-byte start codes comes
    // back one leading zero shorter. That is deterministic, which is all a comparison needs.
    @Test
    fun keepsAvcSpsAndPpsAndDropsEverythingElse() {
        val sps = nal(0x67, 0x42, 0x00)
        val pps = nal(0x68, 0xCE)
        val sei = nal(0x06, 0x05, 0x11)
        val aud = nal(0x09, 0x10)
        assertContentEquals(
            LiveAccessUnit.parameterSetNals(sps + pps),
            LiveAccessUnit.parameterSetNals(aud + sei + sps + pps),
        )
    }

    @Test
    fun keepsHevcVpsSpsPps() {
        val vps = nal(0x40, 0x01)
        val sps = nal(0x42, 0x01)
        val pps = nal(0x44, 0x01)
        val sei = nal(0x4E, 0x01)
        assertContentEquals(
            LiveAccessUnit.parameterSetNals(vps + sps + pps),
            LiveAccessUnit.parameterSetNals(vps + sei + sps + pps),
        )
    }

    /** The regression: same parameter sets, different SEI, must not be a change. */
    @Test
    fun sameParameterSetsWithADifferentSeiIsNotAChange() {
        val sps = nal(0x67, 0x42, 0x00)
        val pps = nal(0x68, 0xCE)
        val first = nal(0x06, 0x05, 0x01) + sps + pps
        val second = nal(0x06, 0x05, 0x02) + sps + pps

        assertTrue(EncoderPresentPath.parameterSetsChanged(true, first, second))
        assertFalse(
            EncoderPresentPath.parameterSetsChanged(
                true,
                LiveAccessUnit.parameterSetNals(first),
                LiveAccessUnit.parameterSetNals(second),
            )
        )
    }

    /** A real SPS change still has to rebuild the decoder. */
    @Test
    fun aChangedSpsIsStillAChange() {
        val pps = nal(0x68, 0xCE)
        val before = LiveAccessUnit.parameterSetNals(nal(0x67, 0x42, 0x00) + pps)
        val after = LiveAccessUnit.parameterSetNals(nal(0x67, 0x42, 0x28) + pps)
        assertTrue(EncoderPresentPath.parameterSetsChanged(true, before, after))
    }

    @Test
    fun aBlobWithNoParameterSetsIsEmpty() {
        assertContentEquals(ByteArray(0), LiveAccessUnit.parameterSetNals(nal(0x06, 0x05)))
    }

    @Test
    fun privateMetadataCannotSupplyParameterSetsOrACodec() {
        val metadata = ByteArray(25) { 0x22 }
        byteArrayOf(0, 0, 1, 0x67, 0x42).copyInto(metadata, 4)
        byteArrayOf(0, 0, 1, 0x40, 0x01).copyInto(metadata, 12)
        val privateSei = byteArrayOf(0, 0, 1, 6, 0xF0.toByte(), 25) +
            metadata + byteArrayOf(0x80.toByte())
        assertContentEquals(ByteArray(0), LiveAccessUnit.parameterSetNals(privateSei))
        kotlin.test.assertNull(LiveAccessUnit.detectCodec(privateSei, ""))
        kotlin.test.assertNull(LiveAccessUnit.detectCodec(byteArrayOf(0x22, 0x22, 0x22, 0x40, 1), ""))
        val real = nal(0x67, 0x42, 0x28) + nal(0x68, 0xCE)
        assertContentEquals(
            LiveAccessUnit.parameterSetNals(real),
            LiveAccessUnit.parameterSetNals(privateSei + real),
        )
        kotlin.test.assertEquals(LiveVideoCodec.AVC, LiveAccessUnit.detectCodec(privateSei + real, ""))
    }
}
