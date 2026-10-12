@file:androidx.media3.common.util.UnstableApi
package com.opencapture.opencine.media3

import androidx.media3.common.C
import androidx.media3.common.Player
import com.opencapture.opencine.media.MonitorAudioMeterBallistics
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.MonitorPlaybackTransportState
import com.opencapture.opencine.runtime.MonitorPcmPeaks
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

@OptIn(ExperimentalCoroutinesApi::class)
class Media3AudioMeterTest {
    private fun peaks(buffer: ByteBuffer, encoding: Int, channels: Int) =
        assertNotNull(MonitorPcmPeaks.ingest(buffer, Media3AudioMeter.format(encoding, channels)))

    /** Moved from the Pocket and Insta playback chrome tests with the encoding map. */
    @Test fun pcmFloatAndInt16PeaksMatchIosMaxMagnitude() {
        val float = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
            .apply { asFloatBuffer().put(floatArrayOf(0.25f, -0.5f, 1f, 0.1f)) }
        assertEquals(1f, peaks(float, C.ENCODING_PCM_FLOAT, 2).first, 0.001f)
        assertEquals(0.5f, peaks(float, C.ENCODING_PCM_FLOAT, 2).second, 0.001f)
        val pcm16 = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
            .apply { asShortBuffer().put(shortArrayOf(32767, 16384, 0, -8192)) }
        assertEquals(1f, peaks(pcm16, C.ENCODING_PCM_16BIT, 2).first, 0.02f)
        assertEquals(0.5f, peaks(pcm16, C.ENCODING_PCM_16BIT, 2).second, 0.02f)
        val mono = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
            .apply { asFloatBuffer().put(floatArrayOf(0.4f, -0.8f)) }
        assertEquals(0.8f, peaks(mono, C.ENCODING_PCM_FLOAT, 1).first, 0.001f)
        assertEquals(0.8f, peaks(mono, C.ENCODING_PCM_FLOAT, 1).second, 0.001f)
    }

    @Test fun signed32FullScaleKeepsBothChannelMagnitudes() {
        val buffer = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt(Int.MIN_VALUE).putInt(Int.MAX_VALUE)
        buffer.rewind()
        val (left, right) = peaks(buffer, C.ENCODING_PCM_32BIT, 2)
        assertEquals(1f, left, 0.000001f)
        assertEquals(1f, right, 0.000001f)
    }

    /** iOS feeds silence while output is muted or conforming; Android OpenZCine used to keep metering. */
    @Test fun mutedOutputReadsSilent() = runTest {
        val meter = Media3AudioMeter()
        val audio = meter.session(backgroundScope)
        fun feed() = meter.handleBuffer(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
            .apply { asShortBuffer().put(shortArrayOf(32767, 32767)) })
        meter.flush(48_000, 2, C.ENCODING_PCM_16BIT)
        val item = MonitorPlaybackItemToken(UUID.randomUUID(), 1)
        audio.synchronize(item, visible = true, outputMuted = false) { true }
        feed(); runCurrent(); advanceTimeBy(42); runCurrent()
        assertEquals(0.0, assertNotNull(audio.levels.value).left.levelDB, 0.01)
        audio.synchronize(item, visible = true, outputMuted = true) { true }
        feed(); runCurrent(); advanceTimeBy(42); runCurrent()
        assertEquals(MonitorAudioMeterBallistics.FLOOR_DB, assertNotNull(audio.levels.value).left.levelDB, 1e-9)
        assertEquals(MonitorAudioMeterBallistics.FLOOR_DB, assertNotNull(audio.levels.value).right.levelDB, 1e-9)
        audio.close(); meter.close()
        feed(); assertNull(audio.levels.value)
    }

    @Test fun observedTransportMapsMedia3State() {
        fun player(state: Int, playing: Boolean, playWhenReady: Boolean) =
            Proxy.newProxyInstance(Player::class.java.classLoader, arrayOf(Player::class.java)) { _, method, _ ->
                when (method.name) {
                    "getPlaybackState" -> state; "isPlaying" -> playing; "getPlayWhenReady" -> playWhenReady; else -> null
                }
            } as Player
        assertNull(Media3Playback.transport(player(Player.STATE_IDLE, false, true)))
        assertEquals(MonitorPlaybackTransportState.PLAYING, Media3Playback.transport(player(Player.STATE_READY, true, true)))
        assertEquals(MonitorPlaybackTransportState.PAUSED, Media3Playback.transport(player(Player.STATE_READY, false, false)))
        assertEquals(MonitorPlaybackTransportState.PAUSED, Media3Playback.transport(player(Player.STATE_ENDED, false, true)))
        assertEquals(MonitorPlaybackTransportState.WAITING, Media3Playback.transport(player(Player.STATE_BUFFERING, false, true)))
    }
}
