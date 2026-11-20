package com.opencapture.opencine.streaming

import org.json.JSONArray
import org.json.JSONObject

/** One streaming service as the shared preset table describes it. Names are content only. */
data class StreamServicePreset(
    val id: String,
    val displayName: String,
    /** The fixed ingest address, or null when the user enters it. */
    val serverUrl: String?,
    val requiresServerEntry: Boolean,
    val maxVideoBitrateBps: Int?,
    /** The service expects a vertical 9:16 picture. */
    val portrait: Boolean,
    /** One plain sentence on where to find the stream key. */
    val keyHint: String,
)

/** The fixed encoder settings of one stream, set at go-live. */
data class StreamOutputFormat(
    val width: Int,
    val height: Int,
    val fpsNum: Int,
    val fpsDen: Int,
    val videoBitrateBps: Int,
    val keyframeIntervalSeconds: Int,
    val audioBitrateBps: Int,
    val audioSampleRate: Int,
    val audioChannels: Int,
) {
    val framesPerSecond: Double get() = fpsNum.toDouble() / fpsDen

    fun toJson(): String = JSONObject()
        .put("width", width).put("height", height).put("fpsNum", fpsNum).put("fpsDen", fpsDen)
        .put("videoBitrateBps", videoBitrateBps).put("keyframeIntervalSeconds", keyframeIntervalSeconds)
        .put("audioBitrateBps", audioBitrateBps).put("audioSampleRate", audioSampleRate)
        .put("audioChannels", audioChannels).toString()

    companion object {
        fun fromJson(text: String): StreamOutputFormat? = runCatching {
            val o = JSONObject(text)
            StreamOutputFormat(
                o.getInt("width"), o.getInt("height"), o.getInt("fpsNum"), o.getInt("fpsDen"),
                o.getInt("videoBitrateBps"), o.getInt("keyframeIntervalSeconds"), o.getInt("audioBitrateBps"),
                o.getInt("audioSampleRate"), o.getInt("audioChannels"),
            )
        }.getOrNull()
    }
}

/** Why a server address or key cannot be used: the twin of Swift `StreamDestinationError`. */
enum class StreamDestinationProblem {
    /** Not an address scheme the engine accepts. */
    NOT_RTMPS,
    INVALID_SERVER_URL,
    EMPTY_KEY,
    /** A whole URL was pasted into the key field. */
    KEY_LOOKS_LIKE_URL,
    INVALID_FORMAT,
    ;

    companion object {
        fun fromWire(name: String?): StreamDestinationProblem = when (name) {
            "notRTMPS" -> NOT_RTMPS
            "emptyKey" -> EMPTY_KEY
            "keyLooksLikeURL" -> KEY_LOOKS_LIKE_URL
            "invalidFormat" -> INVALID_FORMAT
            else -> INVALID_SERVER_URL
        }
    }
}

sealed interface StreamDestinationCheck {
    /** Usable. [encrypted] is false for a plain `rtmp://` server: the stream and key travel in clear. */
    data class Ok(val encrypted: Boolean) : StreamDestinationCheck

    data class Invalid(val problem: StreamDestinationProblem) : StreamDestinationCheck
}

/** How the device reaches the camera, as the app states it: the twin of `StreamConnectionRoute`. */
enum class StreamConnectionRoute(val wireName: String) {
    USB_CABLE("usbCable"),
    CAPTURE_CARD("captureCard"),
    SHARED_WIFI("sharedWiFi"),
    DEVICE_HOTSPOT("deviceHotspot"),
    CAMERA_WIFI("cameraWiFi"),
}

/** The shared preset table, output rule and destination check, read through the engine. */
class StreamCatalog(private val native: StreamingNativeApi) {
    /** The presets in picker order, then the custom server. */
    fun presets(): List<StreamServicePreset> {
        val array = JSONArray(native.presets())
        return (0 until array.length()).map { index ->
            val o = array.getJSONObject(index)
            StreamServicePreset(
                id = o.getString("id"),
                displayName = o.getString("displayName"),
                serverUrl = if (o.isNull("serverURL")) null else o.getString("serverURL"),
                requiresServerEntry = o.getBoolean("requiresServerEntry"),
                maxVideoBitrateBps = if (o.isNull("maxVideoBitrateBps")) null else o.getInt("maxVideoBitrateBps"),
                portrait = o.getBoolean("portrait"),
                keyHint = o.getString("keyHint"),
            )
        }
    }

    /**
     * The output for a go-live from the selected camera's real size and rate (null rate when the
     * source does not state it) and any other connected sources' sizes.
     */
    fun format(
        presetId: String,
        width: Int,
        height: Int,
        fpsNum: Int?,
        fpsDen: Int?,
        connected: List<Pair<Int, Int>> = emptyList(),
    ): StreamOutputFormat? {
        val sizes = connected.flatMap { listOf(it.first, it.second) }.toIntArray()
        val json = native.format(presetId, width, height, fpsNum ?: 0, fpsDen ?: 0, sizes) ?: return null
        return StreamOutputFormat.fromJson(json)
    }

    fun check(serverUrl: String, streamKey: String): StreamDestinationCheck =
        parseCheck(native.checkDestination(serverUrl, streamKey))

    /** Whether a stream may start on [route]; an unknown route (null) may not. */
    fun canStream(route: StreamConnectionRoute?): Boolean = route != null && native.canStream(route.wireName)

    internal companion object {
        fun parseCheck(json: String): StreamDestinationCheck {
            val o = runCatching { JSONObject(json) }.getOrNull()
                ?: return StreamDestinationCheck.Invalid(StreamDestinationProblem.INVALID_SERVER_URL)
            return if (o.has("error")) {
                StreamDestinationCheck.Invalid(StreamDestinationProblem.fromWire(o.optString("error")))
            } else {
                StreamDestinationCheck.Ok(encrypted = o.optBoolean("tls", true))
            }
        }
    }
}
