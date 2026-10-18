package com.opencapture.opencine.platform

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File

/**
 * The movie every app's debug review harness stages as a SIMULATED clip (`ReviewLaunch`), so no
 * review or conformance scenario depends on footage outside the repository. Twin of the Swift
 * `ReviewClip` (OpenCineApple): one second of 24 fps H.264 grey frames, 640x360, in an MP4.
 * Only debug review code calls it; release builds drop it as unreferenced.
 */
public object ReviewClip {
    public const val SECONDS: Int = 1
    public const val WIDTH: Int = 640
    public const val HEIGHT: Int = 360
    private const val FPS = 24
    private const val TIMEOUT_US = 10_000L

    /** Writes the movie to [file], replacing what is there. Blocking; call it off the main thread. */
    public fun write(file: File) {
        file.parentFile?.mkdirs()
        file.delete()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, WIDTH, HEIGHT).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, 1_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()
            encode(encoder, muxer)
        } finally {
            runCatching { encoder.stop() }
            encoder.release()
            runCatching { muxer.stop() }
            muxer.release()
        }
        check(file.length() > 0) { "The review clip was not written: $file" }
    }

    private fun encode(encoder: MediaCodec, muxer: MediaMuxer) {
        val info = MediaCodec.BufferInfo()
        var track = -1
        var queued = 0
        val frames = FPS * SECONDS
        while (true) {
            if (queued <= frames) {
                val index = encoder.dequeueInputBuffer(TIMEOUT_US)
                if (index >= 0) {
                    val pts = queued * 1_000_000L / FPS
                    if (queued == frames) {
                        encoder.queueInputBuffer(index, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    } else {
                        fillGrey(encoder, index, 64 + queued * 4)
                        encoder.queueInputBuffer(index, 0, WIDTH * HEIGHT * 3 / 2, pts, 0)
                    }
                    queued += 1
                }
            }
            val out = encoder.dequeueOutputBuffer(info, TIMEOUT_US)
            when {
                out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer.addTrack(encoder.outputFormat)
                    muxer.start()
                }
                out >= 0 -> {
                    val data = checkNotNull(encoder.getOutputBuffer(out))
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (!config && info.size > 0 && track >= 0) {
                        data.position(info.offset).limit(info.offset + info.size)
                        muxer.writeSampleData(track, data, info)
                    }
                    encoder.releaseOutputBuffer(out, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    /** One grey frame: luma [level], neutral chroma, written through the codec's own plane layout. */
    private fun fillGrey(encoder: MediaCodec, index: Int, level: Int) {
        val image = checkNotNull(encoder.getInputImage(index))
        image.planes.forEachIndexed { plane, value ->
            val buffer = value.buffer
            val fill = (if (plane == 0) level else 128).toByte()
            while (buffer.hasRemaining()) buffer.put(fill)
        }
    }
}
