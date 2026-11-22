package com.opencapture.opencine.streaming

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

/** Why the microphone could not start. */
class StreamMicrophoneException(message: String) : Exception(message)

/**
 * The device microphone at 48 kHz stereo, 16-bit, read on its own thread in 20 ms blocks. The
 * caller holds `RECORD_AUDIO`; the app declares it and asks for it before going live. Verified on
 * a device only.
 */
class StreamMicrophone(private val sampleRate: Int = 48_000, private val channels: Int = 2) {
    @Volatile private var record: AudioRecord? = null
    @Volatile private var running = false

    /** Starts capture; [onPcm] receives interleaved samples and the frame count. */
    fun start(onPcm: (ShortArray, Int) -> Unit) = start(onCaptureEnded = {}, onPcm = onPcm)

    /** Reports an unexpected audio read failure on the microphone thread. */
    @SuppressLint("MissingPermission")
    fun start(onCaptureEnded: () -> Unit, onPcm: (ShortArray, Int) -> Unit) {
        if (running) return
        val mask = if (channels == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val minimum = AudioRecord.getMinBufferSize(sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw StreamMicrophoneException("unsupported microphone format")
        val block = sampleRate / 50
        val created = try {
            AudioRecord(
                MediaRecorder.AudioSource.CAMCORDER, sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minimum, block * channels * 2 * 4),
            )
        } catch (error: SecurityException) {
            throw StreamMicrophoneException("microphone permission denied")
        }
        if (created.state != AudioRecord.STATE_INITIALIZED) {
            created.release()
            throw StreamMicrophoneException("microphone unavailable")
        }
        record = created
        running = true
        created.startRecording()
        Thread({
            val buffer = ShortArray(block * channels)
            while (running) {
                val read = created.read(buffer, 0, buffer.size)
                if (read < 0) {
                    if (running) onCaptureEnded()
                    break
                }
                if (read > 0) onPcm(buffer.copyOf(read), read / channels)
            }
        }, "opc.stream.mic").apply { isDaemon = true }.start()
    }

    fun stop() {
        running = false
        record?.let { runCatching { it.stop() }; it.release() }
        record = null
    }
}
