package com.opencapture.opencine.runtime

import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorRelayHevcJpegDecoderTest {
    @Test
    fun originalAvccBytesAndPaddedEightBitAndP010PlanesArePreserved() {
        val frame = byteArrayOf(0, 0, 0, 4, 0x26, 0, 0, 0, 0, 0, 0, 2, 0x02, 0)
        val expected = byteArrayOf(0, 0, 0, 1, 0x26, 0, 0, 0, 0, 0, 0, 1, 0x02, 0)
        assertContentEquals(expected, MonitorHevcJpegBytes.annexBFrame(frame))
        assertContentEquals(byteArrayOf(0, 0, 0, 1, 0x40, 0, 0, 0, 0, 1, 0x42),
            MonitorHevcJpegBytes.annexBParameterSets(listOf(byteArrayOf(0x40, 0), byteArrayOf(0x42))))
        assertContentEquals(expected, MonitorHevcJpegBytes.annexBFrame(frame + byteArrayOf(0, 0, 0, 9, 1)))
        assertContentEquals(ByteArray(0), MonitorHevcJpegBytes.annexBFrame(byteArrayOf(0, 0, 0, 0, 1)))
        assertContentEquals(ByteArray(0), MonitorHevcJpegBytes.annexBFrame(byteArrayOf(-1, -1, -1, -1)))
        val expectedPlanes = byteArrayOf(10, 20, 30, 40, 50, 60, 70, 80, 9, 1, 8, 2)
        assertContentEquals(expectedPlanes, MonitorHevcJpegBytes.yuv420ToNv21(4, 2,
            plane(byteArrayOf(10, 20, 30, 40, -1, -1, 50, 60, 70, 80, -1, -1), 6, 1),
            plane(byteArrayOf(1, -1, 2, -1), 4, 2), plane(byteArrayOf(9, -1, 8, -1), 4, 2)))
        assertContentEquals(expectedPlanes, MonitorHevcJpegBytes.yuv420ToNv21(4, 2,
            plane(byteArrayOf(-1, 10, -1, 20, -1, 30, -1, 40, -1, -1,
                -1, 50, -1, 60, -1, 70, -1, 80, -1, -1), 10, 2),
            plane(byteArrayOf(-1, 1, -1, -1, -1, 2, -1, -1), 8, 4),
            plane(byteArrayOf(-1, 9, -1, -1, -1, 8, -1, -1), 8, 4)))
    }

    @Test
    fun configuredDecoderWaitsForKeyframeInlinesParametersAndOnlyConvertsNewestOutput() {
        val factory = Factory()
        val decoder = owner(factory)
        val parameters = listOf(byteArrayOf(0x40, 1), byteArrayOf(0x42, 2))
        assertNull(decoder.decodeToJpeg(frame, false, parameters))
        val codec = factory.created.single()
        assertTrue(codec.inputs.isEmpty())
        codec.nextOutput.addAll(listOf(-2, 4, 5, -1))
        codec.images[5] = Picture(byteArrayOf(5))
        assertContentEquals(byteArrayOf(5), decoder.decodeToJpeg(frame, true, parameters))
        assertContentEquals(MonitorHevcJpegBytes.annexBParameterSets(parameters) +
            MonitorHevcJpegBytes.annexBFrame(frame), codec.inputs.single().bytes)
        assertEquals(40_000L, codec.inputs.single().pts)
        assertEquals(listOf(20_000L), codec.inputTimeouts)
        assertEquals(listOf(12_000L, 0L, 0L, 0L), codec.outputTimeouts)
        assertEquals(listOf(4, 5), codec.releasedOutputs)
        assertEquals(listOf(88), codec.images.getValue(5).qualities)
        assertEquals(1, codec.images.getValue(5).closes)
        assertNull(decoder.decodeToJpeg(frame, false, null))
        assertContentEquals(MonitorHevcJpegBytes.annexBFrame(frame), codec.inputs.last().bytes)
        assertEquals(80_000L, codec.inputs.last().pts)
        val profile = factory.policies.single()
        assertEquals(1920, profile.width)
        assertEquals(1080, profile.height)
        assertEquals("c2.android.hevc.decoder", profile.softwareDecoderName)
        assertFalse(factory.software.single())
        decoder.close()
    }

    @Test
    fun hardwareFallsBackStrictlyAfterSeventyFiveAndThreeSoftwareRebuildsPauseUntilNewParameters() {
        val factory = Factory()
        val decoder = owner(factory)
        repeat(75) { assertNull(decoder.decodeToJpeg(frame, true, parameters)) }
        val hardware = factory.created.single()
        assertEquals(0, hardware.stops)
        assertEquals(listOf(false), factory.software)
        assertNull(decoder.decodeToJpeg(frame, true, parameters))
        assertEquals(1, hardware.stops)
        assertEquals(1, hardware.releases)
        assertNull(decoder.decodeToJpeg(frame, true, null))
        assertEquals(1, factory.created.size, "Rebuild still requires a parameter-bearing keyframe")
        factory.failInputs = true
        repeat(3) { assertNull(decoder.decodeToJpeg(frame, true, parameters)) }
        assertEquals(listOf(false, true, true, true), factory.software)
        assertTrue(decoder.isPausedForStream)
        repeat(5) { assertNull(decoder.decodeToJpeg(frame, true, parameters)) }
        assertNull(decoder.decodeToJpeg(frame, true, null))
        assertEquals(4, factory.created.size)
        factory.failInputs = false
        factory.newPicture = byteArrayOf(9)
        assertContentEquals(byteArrayOf(9), decoder.decodeToJpeg(frame, true, listOf(byteArrayOf(0x40, 3))))
        assertFalse(decoder.isPausedForStream)
        assertEquals(5, factory.created.size)
        assertTrue(factory.software.last())
        decoder.close()
    }

    @Test
    fun sourceReleaseRefusesQueuedBytesRetainsPtsAndTerminalCloseCannotReopen() {
        val factory = Factory()
        val decoder = owner(factory)
        val old = decoder.sourceToken
        decoder.decodeToJpeg(frame, true, parameters, old)
        val prior = factory.created.single()
        decoder.release()
        assertEquals(1, prior.stops)
        assertEquals(1, prior.releases)
        assertNull(decoder.decodeToJpeg(frame, true, parameters, old))
        assertEquals(1, factory.created.size)
        decoder.decodeToJpeg(frame, true, parameters)
        val current = factory.created.last()
        assertEquals(80_000L, current.inputs.single().pts)
        decoder.close()
        decoder.close()
        decoder.release()
        assertNull(decoder.decodeToJpeg(frame, true, parameters))
        assertEquals(2, factory.created.size)
        assertEquals(1, current.stops)
        assertEquals(1, current.releases)
    }

    @Test
    fun suppliedProducerTokenAndOldPeerRetirementCannotReleaseSuccessorCodec() {
        val factory = Factory()
        val decoder = owner(factory)
        val old = java.util.UUID.randomUUID()
        val next = java.util.UUID.randomUUID()
        assertTrue(decoder.beginSource(old))
        decoder.decodeToJpeg(frame, true, parameters, old)
        val prior = factory.created.single()
        assertTrue(decoder.beginSource(next))
        decoder.decodeToJpeg(frame, true, parameters, next)
        val successor = factory.created.last()
        assertFalse(decoder.retireSource(old))
        assertNull(decoder.decodeToJpeg(frame, true, parameters, old))
        assertEquals(1, prior.releases)
        assertEquals(0, successor.releases)
        assertTrue(decoder.retireSource(next))
        assertEquals(1, successor.releases)
        decoder.close()
        assertFalse(decoder.beginSource(java.util.UUID.randomUUID()))
    }

    @Test
    fun replacementDuringNativeConfigurationClosesOnlyTheRetiredCreatedCodec() {
        val factory = Factory()
        val decoder = owner(factory)
        factory.onCreate = { factory.onCreate = null; decoder.release() }
        assertNull(decoder.decodeToJpeg(frame, true, parameters))
        val old = factory.created.single()
        assertEquals(1, old.stops)
        assertEquals(1, old.releases)
        decoder.decodeToJpeg(frame, true, parameters)
        assertEquals(2, factory.created.size)
        assertEquals(0, factory.created.last().stops)
        decoder.close()
    }

    @Test
    fun reentrantOutputReplacementCannotReturnOldPixelsOrReleaseSuccessorResources() {
        val factory = Factory()
        val decoder = owner(factory)
        decoder.decodeToJpeg(frame, true, parameters)
        val old = factory.created.single()
        val picture = Picture(byteArrayOf(1))
        old.nextOutput.addAll(listOf(7, -1))
        old.images[7] = picture
        var successorPixels: ByteArray? = null
        picture.onJpeg = {
            picture.onJpeg = null
            decoder.release()
            factory.newPicture = byteArrayOf(2)
            successorPixels = decoder.decodeToJpeg(frame, true, parameters)
        }
        assertNull(decoder.decodeToJpeg(frame, true, parameters))
        assertContentEquals(byteArrayOf(2), successorPixels)
        assertEquals(1, picture.closes)
        assertEquals(listOf(7), old.releasedOutputs)
        val successor = factory.created.last()
        assertEquals(0, successor.stops)
        assertEquals(0, successor.releases)
        assertEquals(1, successor.images.getValue(0).closes)
        decoder.close()
    }

    @Test
    fun nativeImageFailureStillClosesImageAndReleasesOutputAndInputRetirementNeverQueues() {
        val factory = Factory()
        val decoder = owner(factory)
        decoder.decodeToJpeg(frame, true, parameters)
        val codec = factory.created.single()
        val failed = Picture(byteArrayOf(1))
        failed.onJpeg = { throw IllegalStateException("native image conversion failed") }
        codec.nextOutput.addAll(listOf(3, -1))
        codec.images[3] = failed
        assertNull(decoder.decodeToJpeg(frame, true, parameters))
        assertEquals(1, failed.closes)
        assertEquals(listOf(3), codec.releasedOutputs)
        assertEquals(1, codec.releases)
        decoder.decodeToJpeg(frame, true, parameters)
        val replacement = factory.created.last()
        val before = replacement.inputs.size
        replacement.onInput = { replacement.onInput = null; decoder.close() }
        assertNull(decoder.decodeToJpeg(frame, true, parameters))
        assertEquals(before, replacement.inputs.size)
        assertNull(decoder.decodeToJpeg(frame, true, parameters))
        assertEquals(2, factory.created.size)
    }

    private fun owner(factory: Factory): MonitorRelayHevcJpegDecoder =
        MonitorRelayHevcJpegDecoder(factory = factory, log = { _, _, _ -> })
    private fun plane(bytes: ByteArray, row: Int, pixel: Int): MonitorHevcYuvPlane =
        MonitorHevcYuvPlane(ByteBuffer.wrap(bytes), row, pixel)
    private val frame: ByteArray = byteArrayOf(0, 0, 0, 2, 0x26, 1)
    private val parameters: List<ByteArray> = listOf(byteArrayOf(0x40, 1))
}

private class Factory : MonitorHevcJpegCodecFactory {
    val created: MutableList<Codec> = mutableListOf()
    val software: MutableList<Boolean> = mutableListOf()
    val policies: MutableList<MonitorHevcJpegDecodePolicy> = mutableListOf()
    var failInputs: Boolean = false
    var newPicture: ByteArray? = null
    var onCreate: (() -> Unit)? = null
    override fun create(software: Boolean, policy: MonitorHevcJpegDecodePolicy): MonitorHevcJpegCodec {
        this.software += software
        policies += policy
        val codec = Codec(failInputs)
        newPicture?.let { codec.nextOutput.addAll(listOf(0, -1)); codec.images[0] = Picture(it) }
        created += codec
        onCreate?.invoke()
        return codec
    }
}

private class Picture(private val bytes: ByteArray) : MonitorHevcJpegOutput {
    val qualities: MutableList<Int> = mutableListOf()
    var closes: Int = 0
    var onJpeg: (() -> Unit)? = null
    override fun jpeg(quality: Int): ByteArray { qualities += quality; onJpeg?.invoke(); return bytes }
    override fun close(): Unit { closes += 1 }
}

private class Codec(private val failInput: Boolean) : MonitorHevcJpegCodec {
    data class Input(val bytes: ByteArray, val pts: Long)
    override val name: String = "controlled-native"
    val inputs: MutableList<Input> = mutableListOf()
    val inputTimeouts: MutableList<Long> = mutableListOf()
    val outputTimeouts: MutableList<Long> = mutableListOf()
    val nextOutput: MutableList<Int> = mutableListOf()
    val images: MutableMap<Int, Picture> = mutableMapOf()
    val releasedOutputs: MutableList<Int> = mutableListOf()
    var onInput: (() -> Unit)? = null
    var stops: Int = 0
    var releases: Int = 0
    private val buffer: ByteBuffer = ByteBuffer.allocate(4096)
    override fun dequeueInputBuffer(timeoutMicros: Long): Int {
        inputTimeouts += timeoutMicros
        if (failInput) throw IllegalStateException("native decoder rejected Main10")
        return 0
    }
    override fun inputBuffer(index: Int): ByteBuffer { onInput?.invoke(); return buffer }
    override fun queueInputBuffer(index: Int, byteCount: Int, presentationMicros: Long): Unit {
        val bytes = ByteArray(byteCount)
        buffer.flip()
        buffer.get(bytes)
        inputs += Input(bytes, presentationMicros)
    }
    override fun dequeueOutputBuffer(timeoutMicros: Long): Int {
        outputTimeouts += timeoutMicros
        return if (nextOutput.isEmpty()) -1 else nextOutput.removeAt(0)
    }
    override fun outputImage(index: Int): MonitorHevcJpegOutput? = images[index]
    override fun releaseOutputBuffer(index: Int): Unit { releasedOutputs += index }
    override fun stop(): Unit { stops += 1 }
    override fun release(): Unit { releases += 1 }
}
