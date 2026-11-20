package com.opencapture.monitorui

import java.util.Locale

/**
 * The shared live stream surface's values and copy: the Compose twin of
 * `Sources/MonitorPresentation/LiveStreamPresentation.swift`, written to `docs/streaming/ui-contract.md`.
 * Values and actions only: nothing here imports the engine, a camera integration or an app.
 */

/** One service in the picker, built by composition from the engine's presets then the custom server. */
data class LiveStreamServiceOption(
    val id: String,
    val name: String,
    val keyHint: String,
    val needsServer: Boolean,
    val acceptsPlainServer: Boolean,
    val vertical: Boolean,
)

/** Whether a key is saved for the selected service. Unavailable is never treated as absent. */
enum class LiveStreamKeyState { ABSENT, SAVED, UNAVAILABLE }

/** Whether the connection route can reach the internet besides the camera link. */
enum class LiveStreamEligibility { ALLOWED, CAMERA_WIFI, NO_CAMERA }

data class LiveStreamQuality(
    val width: Int,
    val height: Int,
    val framesPerSecond: Double,
    val videoBitrateBps: Int,
)

sealed interface LiveStreamEnd {
    data object Stopped : LiveStreamEnd

    data class Refused(val reason: String) : LiveStreamEnd

    data object GaveUp : LiveStreamEnd

    data object Unreachable : LiveStreamEnd

    data object Background : LiveStreamEnd

    data object MicrophoneDenied : LiveStreamEnd
}

sealed interface LiveStreamPhase {
    data object Idle : LiveStreamPhase

    data object Connecting : LiveStreamPhase

    data object Live : LiveStreamPhase

    data class Reconnecting(val attempt: Int) : LiveStreamPhase

    data class Ended(val end: LiveStreamEnd) : LiveStreamPhase
}

/** Connecting, live or reconnecting: a stream runs and settings are locked. */
val LiveStreamPhase.isRunning: Boolean
    get() = this == LiveStreamPhase.Connecting || this == LiveStreamPhase.Live || this is LiveStreamPhase.Reconnecting

enum class LiveStreamHealth { GOOD, CONGESTED, OFFLINE }

data class LiveStreamStatusState(
    val phase: LiveStreamPhase,
    val elapsedSeconds: Int,
    val sentBitrateBps: Int,
    val droppedGroups: Int,
    val health: LiveStreamHealth,
)

enum class LiveStreamWarning { HOT, LOW_BATTERY }

/** Every string the live stream surface shows or speaks (contract copy, word for word). */
object LiveStreamCopy {
    const val CARD_TITLE = "Live stream"
    const val SERVICE = "Service"
    const val SERVER = "Server"
    const val SERVER_PLACEHOLDER = "rtmps://"
    const val SERVER_PLACEHOLDER_PLAIN = "rtmps:// or rtmp://"
    const val STREAM_KEY = "Stream key"
    const val KEY_PLACEHOLDER = "Paste stream key"
    const val PASTE = "Paste"
    const val SAVE = "Save"
    const val SAVED = "Saved"
    const val REMOVE = "Remove"
    const val QUALITY = "Quality"
    const val SHOW_ON_MONITOR = "Go live button on the monitor"
    const val PLAIN_WARNING = "Not encrypted: the stream and its key travel in the clear."
    const val KEY_UNAVAILABLE =
        "The saved stream key cannot be read until this phone is unlocked. Unlock it, then come back."
    const val LOCKED_WHILE_LIVE = "Service, server and key are locked while a stream runs."

    const val REMOVE_TITLE = "Remove the stream key?"
    fun removeMessage(service: String) =
        "The key for $service is deleted from this phone. You can paste it again later."
    const val CANCEL = "Cancel"

    const val GO_LIVE = "Go live"
    const val CONNECTING = "Connecting"
    const val RECONNECTING = "Reconnecting"
    const val GO_LIVE_UNAVAILABLE = "Go live, unavailable"
    fun goLiveHint(service: String) = "Starts streaming to $service"
    const val ENDS_THE_STREAM = "Ends the stream"
    fun connectingLabel(service: String) = "Connecting to $service"
    fun liveTitle(elapsedSeconds: Int) = "LIVE ${elapsed(elapsedSeconds)}"
    fun liveLabel(elapsedSeconds: Int) = "Live for ${spokenElapsed(elapsedSeconds)}"
    fun reconnectingLabel(attempt: Int) = "Reconnecting, attempt $attempt"

    fun startTitle(service: String) = "Go live on $service?"
    fun startMessage(quality: String, plain: Boolean): String {
        val first = "$quality. The camera picture goes out with the monitor LUT; assists and controls do not. " +
            "Camera recording is separate."
        return if (plain) "$first\n\n$PLAIN_WARNING" else first
    }
    const val STOP_TITLE = "End the stream?"
    const val STOP_MESSAGE = "Viewers see the stream end. Camera recording is not affected."
    const val END_STREAM = "End stream"
    const val KEEP_STREAMING = "Keep streaming"

    const val DISMISS = "Dismiss"
    const val RESTART = "Restart stream"

    /** The notice after a stream ends, or null when it needs none (the operator stopped it). */
    fun notice(end: LiveStreamEnd): String? = when (end) {
        LiveStreamEnd.Stopped -> null
        is LiveStreamEnd.Refused -> "The service refused the stream: ${end.reason}. Check the stream key and server."
        LiveStreamEnd.GaveUp -> "The stream ended: the network did not come back within 2 minutes."
        LiveStreamEnd.Unreachable ->
            "Could not reach the streaming server. Check this phone's internet connection, then go live again."
        LiveStreamEnd.Background -> "The stream ended when the app left the screen."
        LiveStreamEnd.MicrophoneDenied -> "Allow microphone access in Settings to go live."
    }

    fun warning(warning: LiveStreamWarning): String = when (warning) {
        LiveStreamWarning.HOT -> "The phone is hot. The stream continues; give it air or shade."
        LiveStreamWarning.LOW_BATTERY -> "Battery is low. The stream continues until the phone stops it."
    }

    fun eligibilityShort(eligibility: LiveStreamEligibility): String? = when (eligibility) {
        LiveStreamEligibility.ALLOWED -> null
        LiveStreamEligibility.CAMERA_WIFI -> "Camera Wi-Fi has no internet"
        LiveStreamEligibility.NO_CAMERA -> "No camera"
    }

    fun eligibilityLong(eligibility: LiveStreamEligibility): String? = when (eligibility) {
        LiveStreamEligibility.ALLOWED -> null
        LiveStreamEligibility.CAMERA_WIFI ->
            "This phone is on the camera's own Wi-Fi, which has no internet. To go live, connect the camera " +
                "over a shared Wi-Fi network, this phone's hotspot or a cable."
        LiveStreamEligibility.NO_CAMERA -> "Connect a camera to go live."
    }

    const val QUALITY_UNKNOWN = "Set from the camera when you go live."

    fun quality(quality: LiveStreamQuality?): String {
        quality ?: return QUALITY_UNKNOWN
        val vertical = quality.height > quality.width
        val short = minOf(quality.width, quality.height)
        val shape = if (vertical) "${short}p vertical" else "${short}p"
        return "$shape, ${framesPerSecond(quality.framesPerSecond)} fps, ${bitrate(quality.videoBitrateBps)}"
    }

    /** `<w>` is the source height times 9 / 16, rounded down. */
    fun verticalNote(sourceHeight: Int): String =
        "This service takes a vertical picture: the stream is a 9:16 center crop of the camera picture, " +
            "about ${sourceHeight * 9 / 16} pixels wide from a ${sourceHeight}p feed before scaling."

    /** Server and key problems, by engine error name; [custom] for the Custom server's wording. */
    fun problem(engineError: String, custom: Boolean): String = when (engineError) {
        "notRTMPS" -> if (custom) "Use an rtmps:// or rtmp:// address." else "Use the rtmps:// address the service gave you."
        "emptyKey" -> "Paste the stream key."
        "keyLooksLikeURL" -> "That looks like an address, not a key. Put the address in Server and the key here."
        else -> "The address needs a host and a path, like rtmps://live.example.com/app."
    }

    fun health(health: LiveStreamHealth): String = when (health) {
        LiveStreamHealth.GOOD -> "Good"
        LiveStreamHealth.CONGESTED -> "Slow network"
        LiveStreamHealth.OFFLINE -> "Offline"
    }

    fun dropped(count: Int) = "Dropped $count"

    fun statusLabel(status: LiveStreamStatusState): String {
        val connection = when (status.health) {
            LiveStreamHealth.GOOD -> "good"
            LiveStreamHealth.CONGESTED -> "slow"
            LiveStreamHealth.OFFLINE -> "offline"
        }
        return "Streaming for ${spokenElapsed(status.elapsedSeconds)}. Sending ${spokenBitrate(status.sentBitrateBps)}. " +
            "${status.droppedGroups} dropped. Connection $connection."
    }

    /** `m:ss` under an hour, `h:mm:ss` from an hour. */
    fun elapsed(seconds: Int): String {
        val s = seconds.coerceAtLeast(0)
        val hours = s / 3600
        val minutes = s % 3600 / 60
        val rest = s % 60
        return if (hours > 0) {
            String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, rest)
        } else {
            String.format(Locale.ROOT, "%d:%02d", minutes, rest)
        }
    }

    fun spokenElapsed(seconds: Int): String {
        val s = seconds.coerceAtLeast(0)
        fun unit(value: Int, name: String) = "$value $name" + if (value == 1) "" else "s"
        val parts = mutableListOf<String>()
        if (s >= 3600) parts += unit(s / 3600, "hour")
        if (s >= 60) parts += unit(s % 3600 / 60, "minute")
        parts += unit(s % 60, "second")
        return parts.joinToString(" ")
    }

    /** One decimal in Mbps from 1 Mbps, whole kbps below; `3 Mbps` when the decimal is zero. */
    fun bitrate(bps: Int): String = if (bps >= 1_000_000) "${megabits(bps)} Mbps" else "${bps / 1000} kbps"

    fun spokenBitrate(bps: Int): String =
        if (bps >= 1_000_000) "${megabits(bps)} megabits per second" else "${bps / 1000} kilobits per second"

    private fun megabits(bps: Int): String {
        val tenths = (bps + 50_000) / 100_000
        return if (tenths % 10 == 0) "${tenths / 10}" else "${tenths / 10}.${tenths % 10}"
    }

    private fun framesPerSecond(fps: Double): String {
        val rounded = Math.round(fps)
        if (kotlin.math.abs(fps - rounded) < 0.005) return rounded.toString()
        return String.format(Locale.ROOT, "%.2f", fps).trimEnd('0').trimEnd('.')
    }
}

/** Everything the live stream card, the Go live control, the status readout and notices show. */
data class LiveStreamState(
    val services: List<LiveStreamServiceOption> = emptyList(),
    val selectedServiceId: String? = null,
    /** The server field's text: entered, or the saved one. Only for services that need a server. */
    val server: String = "",
    /** After a failed Save, the problem copy. */
    val problem: String? = null,
    val keyState: LiveStreamKeyState = LiveStreamKeyState.ABSENT,
    /** The output the stream would have now, or null before a camera states its picture. */
    val quality: LiveStreamQuality? = null,
    /** The selected camera's picture height, for the vertical note. */
    val sourceHeight: Int? = null,
    val showOnMonitor: Boolean = true,
    val eligibility: LiveStreamEligibility = LiveStreamEligibility.NO_CAMERA,
    val phase: LiveStreamPhase = LiveStreamPhase.Idle,
    val status: LiveStreamStatusState? = null,
    val warnings: Set<LiveStreamWarning> = emptySet(),
) {
    val selected: LiveStreamServiceOption? get() = services.firstOrNull { it.id == selectedServiceId } ?: services.firstOrNull()

    /** The server is plain `rtmp://` on a service that accepts it: the stream travels unencrypted. */
    val plainServer: Boolean
        get() = selected?.acceptsPlainServer == true && selected?.needsServer == true &&
            server.trim().lowercase().startsWith("rtmp://")

    /** The Go live control is shown over the monitor. */
    val showsControl: Boolean
        get() = phase.isRunning || (showOnMonitor && keyState == LiveStreamKeyState.SAVED)

    /** The notice after a stream ended, if it needs one. */
    val notice: String? get() = (phase as? LiveStreamPhase.Ended)?.end?.let(LiveStreamCopy::notice)
}

/** What the live stream surface can ask for. Starting or stopping never sends a camera command. */
interface LiveStreamActions {
    fun selectService(id: String)

    fun setServer(text: String)

    /** Saves [key] (and the entered server) for the selected service; a problem shows on the card. */
    fun saveKey(key: String)

    fun removeKey()

    fun setShowOnMonitor(show: Boolean)

    /** Starts after the operator confirmed. */
    fun goLive()

    /** Stops after the operator confirmed. */
    fun stop()

    /** Starts again with the same settings, without a confirmation (after a background end). */
    fun restart()

    fun dismissNotice()
}
