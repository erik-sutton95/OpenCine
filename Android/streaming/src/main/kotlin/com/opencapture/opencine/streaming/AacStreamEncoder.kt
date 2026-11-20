package com.opencapture.opencine.streaming

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log

/** The audio side of a stream, as the publisher drives it. */
interface StreamAudioEncoder {
    /** [output] runs on the caller of [encode]. */
    fun start(output: (StreamMediaPacket) -> Unit)

    /**
     * Encodes interleaved 16-bit PCM at the format's rate and channels. [startMs] is the stream
     * time of the first sample ever passed; later times follow the sample count.
     */
    fun encode(pcm: ShortArray, frames: Int, startMs: Int)

    fun release()
}

/** AAC-LC on MediaCodec at the format's rate, channels and bitrate; raw frames, no ADTS. */
class AacStreamEncoder(private val format: StreamOutputFormat) : StreamAudioEncoder {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MIME)
    private val timeline = AacTimeline(format.audioSampleRate)
    private var output: (StreamMediaPacket) -> Unit = {}
    private var samples = 0L
    private var offsetMs: Int? = null
    private var configSent = false
    private val info = MediaCodec.BufferInfo()
    @Volatile private var released = false

    override fun start(output: (StreamMediaPacket) -> Unit) {
        this.output = output
        val media = MediaFormat.createAudioFormat(MIME, format.audioSampleRate, format.audioChannels)
        media.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        media.setInteger(MediaFormat.KEY_BIT_RATE, format.audioBitrateBps)
        media.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
        codec.configure(media, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
    }

    @Synchronized
    override fun encode(pcm: ShortArray, frames: Int, startMs: Int) {
        if (released) return
        val offset = offsetMs ?: startMs.also { offsetMs = it }
        try {
            var written = 0
            val channels = format.audioChannels
            while (written < frames) {
                val index = codec.dequeueInputBuffer(INPUT_WAIT_US)
                if (index < 0) break
                val buffer = codec.getInputBuffer(index) ?: break
                buffer.clear()
                val count = minOf(frames - written, buffer.capacity() / (2 * channels))
                val shorts = buffer.asShortBuffer()
                shorts.put(pcm, written * channels, count * channels)
                val ptsUs = samples * 1_000_000 / format.audioSampleRate
                codec.queueInputBuffer(index, 0, count * channels * 2, ptsUs, 0)
                samples += count
                written += count
            }
            drain(offset)
        } catch (error: IllegalStateException) {
            Log.w("OpenCineStream", "AAC encoder failed", error)
        }
    }

    @Synchronized
    override fun release() {
        if (released) return
        released = true
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }

    private fun drain(offset: Int) {
        while (true) {
            val index = codec.dequeueOutputBuffer(info, 0)
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val csd = codec.outputFormat.getByteBuffer("csd-0")
                if (csd != null && !configSent) {
                    output(StreamMediaPacket.AudioConfig(csd.remainingBytes()))
                    configSent = true
                }
                continue
            }
            if (index < 0) return
            val buffer = codec.getOutputBuffer(index)
            if (buffer != null && info.size > 0) {
                val bytes = buffer.copy(info)
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    if (!configSent) output(StreamMediaPacket.AudioConfig(bytes))
                    configSent = true
                } else {
                    val sample = info.presentationTimeUs * format.audioSampleRate / 1_000_000
                    output(StreamMediaPacket.Audio(bytes, offset + timeline.ms(sample)))
                }
            }
            codec.releaseOutputBuffer(index, false)
        }
    }

    private companion object {
        const val MIME = MediaFormat.MIMETYPE_AUDIO_AAC
        const val INPUT_WAIT_US = 10_000L
    }
}
