@file:androidx.media3.common.util.UnstableApi

package com.opencapture.opencine.media3

import android.content.Context
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.TeeAudioProcessor
import com.opencapture.opencine.appkit.MonitorPlaybackAudioSession
import com.opencapture.opencine.media.MonitorPlaybackTransportState
import com.opencapture.opencine.runtime.MonitorAudioMeterSampler
import com.opencapture.opencine.runtime.MonitorAudioPeakAccumulator
import com.opencapture.opencine.runtime.MonitorPcmAudioInput
import com.opencapture.opencine.runtime.MonitorPcmFormat
import com.opencapture.opencine.runtime.MonitorPcmSampleType
import kotlinx.coroutines.CoroutineScope
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** The one ExoPlayer recipe and Media3 state reading the apps share; apps add only their DataSource. */
public object Media3Playback {
    /**
     * Movie audio with focus handling, a pause when output becomes noisy (headphones unplugged, as
     * AVPlayer does) and decoded PCM through [meter]. Float output stays off: Media3 bypasses audio
     * processors on that path.
     */
    public fun player(context: Context, meter: Media3AudioMeter): ExoPlayer {
        val renderers = object : DefaultRenderersFactory(context) {
            override fun buildAudioSink(context: Context, enableFloatOutput: Boolean,
                enableAudioOutputPlaybackParams: Boolean): AudioSink =
                DefaultAudioSink.Builder(context)
                    .setEnableFloatOutput(false)
                    .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
                    .setAudioProcessors(arrayOf<AudioProcessor>(TeeAudioProcessor(meter)))
                    .build()
        }
        return ExoPlayer.Builder(context, renderers)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            .setHandleAudioBecomingNoisy(true)
            .build()
    }

    /** Native Media3 state only; the shared model keeps the operator's requested intent. */
    public fun transport(player: Player): MonitorPlaybackTransportState? = when {
        player.playbackState == Player.STATE_IDLE -> null
        player.isPlaying -> MonitorPlaybackTransportState.PLAYING
        !player.playWhenReady || player.playbackState == Player.STATE_ENDED -> MonitorPlaybackTransportState.PAUSED
        else -> MonitorPlaybackTransportState.WAITING
    }
}

/**
 * Decoded playback PCM (a Media3 `TeeAudioProcessor` sink, so output bytes never change) into the
 * shared peak meter. Each flush prepares a new measurement, so a seek or format change never
 * inherits held peaks; muted or conforming output reads silent, as on iOS.
 */
public class Media3AudioMeter : TeeAudioProcessor.AudioBufferSink {
    private val peaks = MonitorAudioPeakAccumulator()
    private val input = MonitorPcmAudioInput(peaks)
    private val sampler = MonitorAudioMeterSampler(peaks)

    override fun flush(sampleRateHz: Int, channelCount: Int, encoding: Int) {
        input.prepare(format(encoding, channelCount))
    }

    override fun handleBuffer(buffer: ByteBuffer) {
        input.ingest(buffer)
    }

    /** The shared polling owner for this player's meters (one per meter). */
    public fun session(scope: CoroutineScope): MonitorPlaybackAudioSession =
        MonitorPlaybackAudioSession(scope, read = sampler::step, reset = { sampler.reset(); peaks.sampleAndReset() })

    /** Player disposal is terminal; late audio-thread callbacks cannot reopen metering. */
    public fun close() {
        input.close()
        peaks.close()
    }

    public companion object {
        /** Media3 wire encodings resolve here, never in the native runtime. */
        public fun format(encoding: Int, channelCount: Int): MonitorPcmFormat {
            val type = when (encoding) {
                C.ENCODING_PCM_FLOAT -> MonitorPcmSampleType.FLOAT32
                C.ENCODING_PCM_32BIT, C.ENCODING_PCM_32BIT_BIG_ENDIAN -> MonitorPcmSampleType.SIGNED32
                C.ENCODING_PCM_24BIT, C.ENCODING_PCM_24BIT_BIG_ENDIAN -> MonitorPcmSampleType.SIGNED24
                C.ENCODING_PCM_8BIT -> MonitorPcmSampleType.UNSIGNED8
                else -> MonitorPcmSampleType.SIGNED16
            }
            val order = when (encoding) {
                C.ENCODING_PCM_16BIT_BIG_ENDIAN, C.ENCODING_PCM_24BIT_BIG_ENDIAN, C.ENCODING_PCM_32BIT_BIG_ENDIAN -> ByteOrder.BIG_ENDIAN
                C.ENCODING_PCM_FLOAT, C.ENCODING_PCM_16BIT, C.ENCODING_PCM_24BIT, C.ENCODING_PCM_32BIT, C.ENCODING_PCM_8BIT -> ByteOrder.LITTLE_ENDIAN
                else -> null
            }
            return MonitorPcmFormat(type, channelCount, order)
        }
    }
}
