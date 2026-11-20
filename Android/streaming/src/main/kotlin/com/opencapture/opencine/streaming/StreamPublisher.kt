package com.opencapture.opencine.streaming

import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/**
 * One live stream on Android: it drives the shared run controller ([StreamingNativeApi]) with a
 * socket, the encoders, a frame clock at the output rate and the picture source.
 *
 * Everything runs on [scheduler]'s one thread. The picture source renders into the video
 * encoder's surface on each output frame while live (the newest picture, repeated or skipped to
 * hold the rate, a slate after 2 seconds without pictures); microphone audio goes through
 * [submitAudio] from any thread. It sends no camera command and touches no monitor state, so a
 * stream failure stays inside the stream. The stream key is handed to the engine at [start] and
 * kept nowhere here.
 */
class StreamPublisher(
    private val native: StreamingNativeApi,
    private val format: StreamOutputFormat,
    presetId: String,
    enteredServerUrl: String,
    streamKey: String,
    private val crop: Boolean,
    private val picture: StreamPictureSource?,
    private val video: StreamVideoEncoder,
    private val audio: StreamAudioEncoder?,
    private val connect: (host: String, port: Int, tls: Boolean) -> StreamConnection =
        { host, port, tls -> SocketStreamConnection(host, port, tls) },
    private val clock: () -> Long = System::nanoTime,
    private val scheduler: StreamScheduler = StreamScheduler.serial(),
) {
    private val mutableStatus = MutableStateFlow(StreamStatus.CONNECTING)

    /** The latest status; ended once the stream stops, is refused or gives up. */
    val status: StateFlow<StreamStatus> = mutableStatus.asStateFlow()

    /** Whether the stream travels encrypted; known after [start]. */
    @Volatile var encrypted: Boolean = true
        private set

    private var created: Triple<String, String, String>? = Triple(presetId, enteredServerUrl, streamKey)

    // Confined to the scheduler thread.
    private var owner: String? = null
    private var connection: StreamConnection? = null
    private var generation = 0
    @Volatile private var startedNs: Long? = null
    private val pacer = StreamFramePacer()
    private var frameTimer: StreamScheduler.Cancellable? = null
    private var tickTimer: StreamScheduler.Cancellable? = null
    private val wakes = mutableListOf<StreamScheduler.Cancellable>()
    private var finished = false

    /**
     * Checks the destination and starts connecting. An invalid destination starts nothing and
     * ends the status at once. Call once.
     */
    fun start(): StreamDestinationCheck {
        val (preset, server, key) = created
            ?: return StreamDestinationCheck.Invalid(StreamDestinationProblem.INVALID_SERVER_URL)
        created = null
        val reply = runCatching { JSONObject(native.create(preset, server, key, format.toJson(), clock())) }.getOrNull()
        val id = reply?.optString("owner")?.takeIf { it.isNotEmpty() }
        if (reply == null || id == null) {
            mutableStatus.value = StreamStatus.ENDED
            return StreamDestinationCheck.Invalid(StreamDestinationProblem.fromWire(reply?.optString("error")))
        }
        encrypted = reply.optBoolean("tls", true)
        scheduler.execute { begin(id) }
        return StreamDestinationCheck.Ok(encrypted)
    }

    /** Ends the stream politely. Safe to call at any time and more than once. */
    fun stop() {
        scheduler.execute {
            val id = owner ?: return@execute finish()
            apply(native.stop(id, clock()))
        }
    }

    /** Interleaved 16-bit PCM at the format's rate and channels, from any thread. */
    fun submitAudio(pcm: ShortArray, frames: Int) {
        val start = startedNs ?: return
        if (finished) return
        audio?.encode(pcm, frames, ((clock() - start) / 1_000_000).toInt())
    }

    private fun begin(id: String) {
        owner = id
        val start = clock()
        startedNs = start
        try {
            video.start(start) { packet -> scheduler.execute { publish(packet) } }
            audio?.start { packet -> scheduler.execute { publish(packet) } }
            val surface = video.inputSurface
            if (picture != null && surface != null) {
                picture.attach(surface, format.width, format.height, crop) {
                    scheduler.execute { pacer.submit(clock()) }
                }
            }
        } catch (error: Exception) {
            Log.w(TAG, "stream encoders did not start", error)
            apply(native.stop(id, clock()))
            return
        }
        apply(native.start(id))
        val frameNs = (1_000_000_000.0 / format.framesPerSecond.coerceAtLeast(1.0)).toLong()
        frameTimer = scheduler.repeat(frameNs) { emitFrame() }
        tickTimer = scheduler.repeat(1_000_000_000) { owner?.let { apply(native.tick(it, clock())) } }
    }

    private fun emitFrame() {
        if (status.value.phase != StreamPhase.Live) return
        val now = clock()
        picture?.draw(now, slate = pacer.frame(now) == StreamFramePacer.Frame.SLATE)
    }

    private fun publish(packet: StreamMediaPacket) {
        val id = owner ?: return
        val now = clock()
        apply(
            when (packet) {
                is StreamMediaPacket.VideoConfig -> native.publishVideoConfig(id, packet.sps, packet.pps, now)
                is StreamMediaPacket.Video ->
                    native.publishVideo(id, packet.annexB, packet.isKeyframe, packet.decodeMs, packet.presentMs, now)
                is StreamMediaPacket.AudioConfig -> native.publishAudioConfig(id, packet.audioSpecificConfig, now)
                is StreamMediaPacket.Audio -> native.publishAudio(id, packet.raw, packet.presentMs, now)
            },
        )
    }

    private fun handle(event: StreamConnectionEvent, from: Int) {
        val id = owner ?: return
        if (from != generation) return
        val now = clock()
        when (event) {
            StreamConnectionEvent.Opened -> apply(native.connected(id, now))
            is StreamConnectionEvent.Received -> apply(native.received(id, event.bytes, now))
            is StreamConnectionEvent.Wrote -> apply(native.wrote(id, event.count, now))
            StreamConnectionEvent.Lost -> {
                connection = null
                apply(native.connectionLost(id, now))
            }
        }
    }

    private fun apply(bytes: ByteArray) {
        if (finished) return
        val reply = StreamRunReply.decode(bytes)
        for (action in reply.actions) {
            when (action) {
                is StreamAction.Connect -> {
                    connection?.close()
                    generation += 1
                    val opened = connect(action.host, action.port, encrypted)
                    val from = generation
                    connection = opened
                    opened.open { event -> scheduler.execute { handle(event, from) } }
                }
                is StreamAction.Write -> connection?.write(action.bytes)
                StreamAction.Disconnect -> {
                    generation += 1
                    connection?.close()
                    connection = null
                }
                is StreamAction.SetVideoBitrate -> video.setBitrate(action.bps)
                StreamAction.RequestKeyframe -> video.requestKeyframe()
                is StreamAction.Wake -> {
                    val wake = scheduler.schedule(action.atNs - clock()) {
                        owner?.let { apply(native.tick(it, clock())) }
                    }
                    wakes += wake
                }
            }
        }
        mutableStatus.value = reply.status
        if (reply.status.phase is StreamPhase.Ended) finish()
    }

    /** Releases everything once the run has ended. */
    private fun finish() {
        if (finished) return
        finished = true
        frameTimer?.cancel()
        tickTimer?.cancel()
        wakes.forEach { it.cancel() }
        wakes.clear()
        generation += 1
        connection?.close()
        connection = null
        runCatching { picture?.detach() }
        runCatching { video.release() }
        runCatching { audio?.release() }
        owner?.let { native.close(it) }
        if (mutableStatus.value.phase !is StreamPhase.Ended) mutableStatus.value = StreamStatus.ENDED
        scheduler.shutdown()
    }

    private companion object {
        const val TAG = "OpenCineStream"
    }
}
