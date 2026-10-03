package com.opencapture.opencine.runtime

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

enum class MonitorPcmSampleType(val sampleBytes: Int) { FLOAT32(4), SIGNED16(2), SIGNED24(3), SIGNED32(4), UNSIGNED8(1) }
data class MonitorPcmFormat(val sampleType: MonitorPcmSampleType, val channels: Int, val byteOrder: ByteOrder?)

/** Captures only complete interleaved frames; first two channels, mono mirrored to both meters. */
object MonitorPcmPeaks {
    fun ingest(buffer: ByteBuffer, format: MonitorPcmFormat): Pair<Float, Float>? {
        if (format.channels <= 0 || buffer.remaining().toLong() < format.sampleType.sampleBytes.toLong() * format.channels) return null
        val view = buffer.slice().order(format.byteOrder ?: buffer.order())
        return when (format.sampleType) {
            MonitorPcmSampleType.FLOAT32 -> ingestFloat(view, format.channels)
            MonitorPcmSampleType.SIGNED16 -> ingestInt16(view, format.channels)
            MonitorPcmSampleType.SIGNED24 -> ingestPacked24(view, format.channels)
            MonitorPcmSampleType.SIGNED32 -> ingestInt(view, format.channels, bits = 32)
            MonitorPcmSampleType.UNSIGNED8 -> ingestPcm8(view, format.channels)
        }
    }

    private fun ingestFloat(buffer: ByteBuffer, channelCount: Int): Pair<Float, Float> {
        val samples = buffer.asFloatBuffer()
        var left = 0f
        var right = 0f
        while (samples.remaining() >= channelCount) {
            val l = abs(samples.get())
            if (l > left) left = l
            if (channelCount == 1) {
                right = left
            } else {
                val r = abs(samples.get())
                if (r > right) right = r
                repeat(channelCount - 2) {
                    if (samples.hasRemaining()) samples.get()
                }
            }
        }
        if (channelCount == 1) right = left
        return left to right
    }

    private fun ingestInt16(buffer: ByteBuffer, channelCount: Int): Pair<Float, Float> {
        val samples = buffer.asShortBuffer()
        var left = 0f
        var right = 0f
        while (samples.remaining() >= channelCount) {
            val l = abs(samples.get().toInt()) / 32768f
            if (l > left) left = l
            if (channelCount == 1) {
                right = left
            } else {
                val r = abs(samples.get().toInt()) / 32768f
                if (r > right) right = r
                repeat(channelCount - 2) {
                    if (samples.hasRemaining()) samples.get()
                }
            }
        }
        if (channelCount == 1) right = left
        return left to right
    }

    private fun ingestInt(buffer: ByteBuffer, channelCount: Int, bits: Int): Pair<Float, Float> {
        val samples = buffer.asIntBuffer()
        val denom = if (bits == 32) 2147483648.0f else 8388608.0f
        var left = 0f
        var right = 0f
        while (samples.remaining() >= channelCount) {
            val l = abs(samples.get().toLong()) / denom
            if (l > left) left = l
            if (channelCount == 1) {
                right = left
            } else {
                val r = abs(samples.get().toLong()) / denom
                if (r > right) right = r
                repeat(channelCount - 2) {
                    if (samples.hasRemaining()) samples.get()
                }
            }
        }
        if (channelCount == 1) right = left
        return left to right
    }

    private fun ingestPacked24(buffer: ByteBuffer, channelCount: Int): Pair<Float, Float> {
        val big = buffer.order() == ByteOrder.BIG_ENDIAN
        var left = 0f
        var right = 0f
        val frameBytes = 3 * channelCount
        while (buffer.remaining() >= frameBytes) {
            val l = abs(readPcm24(buffer, big)) / 8388608f
            if (l > left) left = l
            if (channelCount == 1) {
                right = left
            } else {
                val r = abs(readPcm24(buffer, big)) / 8388608f
                if (r > right) right = r
                repeat(channelCount - 2) {
                    if (buffer.remaining() >= 3) readPcm24(buffer, big)
                }
            }
        }
        if (channelCount == 1) right = left
        return left to right
    }

    private fun ingestPcm8(buffer: ByteBuffer, channelCount: Int): Pair<Float, Float> {
        var left = 0f
        var right = 0f
        while (buffer.remaining() >= channelCount) {
            val l = abs((buffer.get().toInt() and 0xFF) - 128) / 128f
            if (l > left) left = l
            if (channelCount == 1) {
                right = left
            } else {
                val r = abs((buffer.get().toInt() and 0xFF) - 128) / 128f
                if (r > right) right = r
                repeat(channelCount - 2) {
                    if (buffer.hasRemaining()) buffer.get()
                }
            }
        }
        if (channelCount == 1) right = left
        return left to right
    }

    private fun readPcm24(buffer: ByteBuffer, bigEndian: Boolean): Int {
        val b0 = buffer.get().toInt() and 0xFF
        val b1 = buffer.get().toInt() and 0xFF
        val b2 = buffer.get().toInt() and 0xFF
        val packed = if (bigEndian) (b0 shl 16) or (b1 shl 8) or b2 else b0 or (b1 shl 8) or (b2 shl 16)
        return if (packed and 0x800000 != 0) packed or -0x1000000 else packed
    }
}
