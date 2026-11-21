package com.opencapture.opencine.streaming

import android.util.Log

/**
 * The shared run controller and stream values, as the Android shell calls them. Implemented by
 * [StreamingNative] over JNI and by `FakeStreamingNative` in tests.
 *
 * Run calls name an owner from [create] and return the binary reply [StreamRunReply] decodes:
 * the actions to apply in order, then the status. Times are nanoseconds on one monotonic clock.
 */
interface StreamingNativeApi {
    /**
     * A run for [presetId]: its fixed server, or [enteredServerUrl] when it asks for one, with its
     * rule on plain `rtmp://`. JSON `{"owner":id,"tls":bool}` or `{"error":name}`. The key is never
     * in the reply.
     */
    fun create(presetId: String, enteredServerUrl: String, streamKey: String, formatJson: String, nowNs: Long): String

    fun start(owner: String): ByteArray

    fun connected(owner: String, nowNs: Long): ByteArray

    fun received(owner: String, bytes: ByteArray, nowNs: Long): ByteArray

    fun connectionLost(owner: String, nowNs: Long): ByteArray

    fun wrote(owner: String, count: Int, nowNs: Long): ByteArray

    fun tick(owner: String, nowNs: Long): ByteArray

    fun stop(owner: String, nowNs: Long): ByteArray

    fun publishVideoConfig(owner: String, sps: ByteArray, pps: ByteArray, nowNs: Long): ByteArray

    fun publishVideo(
        owner: String,
        annexB: ByteArray,
        isKeyframe: Boolean,
        decodeMs: Int,
        presentMs: Int,
        nowNs: Long,
    ): ByteArray

    fun publishAudioConfig(owner: String, audioSpecificConfig: ByteArray, nowNs: Long): ByteArray

    fun publishAudio(owner: String, raw: ByteArray, presentMs: Int, nowNs: Long): ByteArray

    /** Retires the owner; later calls naming it reply ended. */
    fun close(owner: String)

    /** The service presets then the custom server, as a JSON array. */
    fun presets(): String

    /** The output format JSON for a go-live, or null for an unknown preset. 0 fps means unknown. */
    fun format(
        presetId: String,
        width: Int,
        height: Int,
        fpsNum: Int,
        fpsDen: Int,
        connected: IntArray,
    ): String?

    /**
     * The output format JSON for a go-live with the operator's quality choice (a
     * [StreamQualityChoice.wireName]), or null for an unknown preset or choice. The default
     * answers the camera feed choice only, for an implementation that predates the choice.
     */
    fun formatFor(
        presetId: String,
        width: Int,
        height: Int,
        fpsNum: Int,
        fpsDen: Int,
        connected: IntArray,
        choice: String,
    ): String? = if (choice == StreamQualityChoice.CAMERA_FEED.wireName) {
        format(presetId, width, height, fpsNum, fpsDen, connected)
    } else {
        null
    }

    /** JSON `{"ok":true,"tls":bool}` or `{"error":name}`, for a preset as in [create]. */
    fun checkDestination(presetId: String, enteredServerUrl: String, streamKey: String): String

    /** Whether a stream may start on a `StreamConnectionRoute` named by its case name. */
    fun canStream(route: String): Boolean

    /** A receive session that accepts only [token] as the stream key; returns its owner id. */
    fun receiverCreate(token: String): String = throw UnsupportedOperationException("receiver")

    /** Bytes from the publisher; the reply [RtmpReceiveReply.decode] reads. */
    fun receiverFeed(owner: String, bytes: ByteArray): ByteArray = throw UnsupportedOperationException("receiver")

    fun receiverClose(owner: String): Unit = throw UnsupportedOperationException("receiver")
}

/**
 * JNI facade for the shared streaming engine. The natives are implemented in Swift by OpenCine's
 * OpenCineStreamingAndroid target, which an app's Swift Android library links and exports as
 * `Java_com_opencapture_opencine_streaming_StreamingNative_<name>`, so this class name, package and
 * member names are the native contract (consumer-rules.pro keeps them).
 *
 * The app calls [load] with its library name once, before any streaming call.
 */
object StreamingNative : StreamingNativeApi {
    /** True once [load] has loaded the library that implements these natives. */
    @Volatile
    var isAvailable: Boolean = false
        private set

    /** Loads the app's JNI library ([library] without `lib` and `.so`); false when absent. */
    @Synchronized
    fun load(library: String): Boolean {
        if (isAvailable) return true
        isAvailable =
            try {
                System.loadLibrary(library)
                true
            } catch (e: UnsatisfiedLinkError) {
                runCatching { Log.e("StreamingNative", "lib$library.so did not load", e) }
                false
            }
        return isAvailable
    }

    external override fun create(
        presetId: String,
        enteredServerUrl: String,
        streamKey: String,
        formatJson: String,
        nowNs: Long,
    ): String

    external override fun start(owner: String): ByteArray

    external override fun connected(owner: String, nowNs: Long): ByteArray

    external override fun received(owner: String, bytes: ByteArray, nowNs: Long): ByteArray

    external override fun connectionLost(owner: String, nowNs: Long): ByteArray

    external override fun wrote(owner: String, count: Int, nowNs: Long): ByteArray

    external override fun tick(owner: String, nowNs: Long): ByteArray

    external override fun stop(owner: String, nowNs: Long): ByteArray

    external override fun publishVideoConfig(owner: String, sps: ByteArray, pps: ByteArray, nowNs: Long): ByteArray

    external override fun publishVideo(
        owner: String,
        annexB: ByteArray,
        isKeyframe: Boolean,
        decodeMs: Int,
        presentMs: Int,
        nowNs: Long,
    ): ByteArray

    external override fun publishAudioConfig(owner: String, audioSpecificConfig: ByteArray, nowNs: Long): ByteArray

    external override fun publishAudio(owner: String, raw: ByteArray, presentMs: Int, nowNs: Long): ByteArray

    external override fun close(owner: String)

    external override fun presets(): String

    external override fun format(
        presetId: String,
        width: Int,
        height: Int,
        fpsNum: Int,
        fpsDen: Int,
        connected: IntArray,
    ): String?

    external override fun formatFor(
        presetId: String,
        width: Int,
        height: Int,
        fpsNum: Int,
        fpsDen: Int,
        connected: IntArray,
        choice: String,
    ): String?

    external override fun checkDestination(presetId: String, enteredServerUrl: String, streamKey: String): String

    external override fun canStream(route: String): Boolean

    external override fun receiverCreate(token: String): String

    external override fun receiverFeed(owner: String, bytes: ByteArray): ByteArray

    external override fun receiverClose(owner: String)
}
