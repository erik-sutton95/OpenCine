package com.opencapture.opencine.streaming

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/** The video side of a stream, as the publisher drives it. */
interface StreamVideoEncoder {
    /** The surface a picture source renders output frames into, once started. */
    val inputSurface: Surface?

    /**
     * Starts encoding. Frames carry presentation times in nanoseconds on the publisher's clock;
     * [startNs] maps them to stream milliseconds. [output] runs on the encoder's own thread.
     */
    fun start(startNs: Long, output: (StreamMediaPacket) -> Unit)

    fun setBitrate(bps: Int)

    fun requestKeyframe()

    fun release()
}

/**
 * H.264 on MediaCodec with surface input: High profile when the device's encoder offers it,
 * the format's keyframe interval, no B-frames (decode order is presentation order), constant
 * bitrate when supported. The codec config arrives as one SPS and PPS packet before the first
 * frame and again if it changes.
 */
class H264StreamEncoder(private val format: StreamOutputFormat) : StreamVideoEncoder {
    private val thread = HandlerThread("opc.stream.h264").apply { start() }
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MIME)
    private var surface: Surface? = null
    private var lastConfig: ByteArray? = null
    @Volatile private var released = false

    override val inputSurface: Surface? get() = surface

    override fun start(startNs: Long, output: (StreamMediaPacket) -> Unit) {
        val startUs = startNs / 1000
        codec.setCallback(
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

                override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    if (released) return
                    try {
                        val buffer = codec.getOutputBuffer(index)
                        if (buffer != null && info.size > 0) {
                            val bytes = buffer.copy(info)
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                config(bytes, output)
                            } else {
                                val ms = StreamEncodedMedia.ms(info.presentationTimeUs, startUs)
                                val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0 ||
                                    StreamEncodedMedia.hasIdr(bytes)
                                output(StreamMediaPacket.Video(bytes, key, ms, ms))
                            }
                        }
                        codec.releaseOutputBuffer(index, false)
                    } catch (error: IllegalStateException) {
                        Log.w(TAG, "encoder output after release", error)
                    }
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    val sps = format.getByteBuffer("csd-0") ?: return
                    val pps = format.getByteBuffer("csd-1") ?: return
                    config(sps.remainingBytes() + pps.remainingBytes(), output)
                }

                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                    Log.w(TAG, "H.264 encoder error", e)
                }
            },
            Handler(thread.looper),
        )
        codec.configure(mediaFormat(), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = codec.createInputSurface()
        codec.start()
    }

    override fun setBitrate(bps: Int) {
        if (released) return
        runCatching { codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bps) }) }
    }

    override fun requestKeyframe() {
        if (released) return
        runCatching { codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) }
    }

    override fun release() {
        if (released) return
        released = true
        runCatching { codec.stop() }
        runCatching { codec.release() }
        runCatching { surface?.release() }
        surface = null
        thread.quitSafely()
    }

    private fun config(annexB: ByteArray, output: (StreamMediaPacket) -> Unit) {
        val (sps, pps) = StreamEncodedMedia.splitParameterSets(annexB) ?: return
        val joined = sps + pps
        if (lastConfig?.contentEquals(joined) == true) return
        lastConfig = joined
        output(StreamMediaPacket.VideoConfig(sps, pps))
    }

    private fun mediaFormat(): MediaFormat {
        val media = MediaFormat.createVideoFormat(MIME, format.width, format.height)
        media.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        media.setInteger(MediaFormat.KEY_BIT_RATE, format.videoBitrateBps)
        media.setFloat(MediaFormat.KEY_FRAME_RATE, format.framesPerSecond.toFloat())
        media.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, format.keyframeIntervalSeconds)
        media.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
        media.setInteger(MediaFormat.KEY_PRIORITY, 0)
        val capabilities = runCatching { codec.codecInfo.getCapabilitiesForType(MIME) }.getOrNull()
        val high = capabilities?.profileLevels
            ?.filter { it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh }
            ?.maxByOrNull { it.level }
        if (high != null) {
            media.setInteger(MediaFormat.KEY_PROFILE, high.profile)
            media.setInteger(MediaFormat.KEY_LEVEL, high.level)
        }
        val cbr = MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
        if (capabilities?.encoderCapabilities?.isBitrateModeSupported(cbr) == true) {
            media.setInteger(MediaFormat.KEY_BITRATE_MODE, cbr)
        }
        return media
    }

    companion object {
        private const val TAG = "OpenCineStream"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC

        /** Whether this device has an H.264 encoder at all. */
        fun isAvailable(): Boolean = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(MIME, ignoreCase = true) }
        }
    }
}

internal fun ByteBuffer.copy(info: MediaCodec.BufferInfo): ByteArray {
    val bytes = ByteArray(info.size)
    position(info.offset)
    limit(info.offset + info.size)
    get(bytes)
    return bytes
}

internal fun ByteBuffer.remainingBytes(): ByteArray {
    val copy = duplicate()
    return ByteArray(copy.remaining()).also { copy.get(it) }
}
