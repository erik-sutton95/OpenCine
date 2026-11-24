package com.opencapture.opencine.appkitnative

import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.ParcelFileDescriptor
import android.speech.RecognizerIntent
import android.system.Os
import android.system.OsConstants
import androidx.annotation.RequiresApi
import com.opencapture.opencine.streaming.StreamMicrophone
import java.io.Closeable
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Streams foreground microphone PCM through an in-memory pipe to the on-device recognizer. */
internal class MonitorVoiceAudio : Closeable {
    private val pipe = ParcelFileDescriptor.createPipe()
    private val microphone = StreamMicrophone(SAMPLE_RATE, channels = 1)
    private val writer = pipe[1].fileDescriptor

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    fun configure(intent: Intent) {
        val flags = Os.fcntlInt(writer, OsConstants.F_GETFL, 0)
        Os.fcntlInt(writer, OsConstants.F_SETFL, flags or OsConstants.O_NONBLOCK)
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0])
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, SAMPLE_RATE)
        intent.putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
    }

    fun start(onCaptureEnded: () -> Unit) {
        microphone.start(onCaptureEnded) { samples, _ ->
            val pcm = ByteBuffer.allocate(samples.size * Short.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN)
            pcm.asShortBuffer().put(samples)
            // The provider may stop reading, or ignore the pipe. Never block the microphone thread.
            runCatching { Os.write(writer, pcm.array(), 0, pcm.capacity()) }
        }
    }

    override fun close() {
        try {
            microphone.stop()
        } finally {
            pipe.forEach { runCatching { it.close() } }
        }
    }

    private companion object { const val SAMPLE_RATE = 16_000 }
}
