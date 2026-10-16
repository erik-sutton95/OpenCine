package com.opencapture.opencine.appkit

import android.content.Context
import android.content.Intent
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.SystemClock
import android.view.KeyEvent
import androidx.core.content.IntentCompat

/** A supported media-button command received while the remote shutter is armed (A2-32). */
public enum class MonitorRemoteShutterCommand {
    /** Toggle recording from standby to recording or the reverse. */
    TOGGLE,

    /** Start recording when the camera is in standby. */
    START,

    /** Stop recording when the camera is already recording. */
    STOP,
}

/**
 * The Android remote shutter (A2-32; Swift twin: OpenCineAppKitApple `MonitorRemoteShutter`): a
 * monitor-only media-button session. An app offers it by declaring
 * `MonitorSettingsRemoteShutter.mediaButtons(...)` in its Controls source and arming this owner
 * from its live monitor ([monitorRemoteShutterShouldArm]).
 *
 * Android does not report a trustworthy Bluetooth-versus-local identity for every hardware event,
 * so this accepts an explicit key allowlist while armed. Generic Bluetooth shutters commonly emit
 * volume keys, and the phone's own volume buttons intentionally become shutter triggers in this
 * monitor-only state, as on iOS. The backing [MediaSession] is active only while the live monitor
 * is frontmost; callers pair [arm] with [disarm] on every lifecycle or surface transition and call
 * [close] at activity teardown. [sessionTag] names the host's media session.
 */
public class MonitorRemoteShutter(context: Context, sessionTag: String) {
    private val controller = MonitorRemoteShutterController(SystemClock::elapsedRealtime)
    private var closed: Boolean = false
    private val mediaSession: MediaSession =
        MediaSession(context.applicationContext, sessionTag).apply {
            setCallback(
                object : MediaSession.Callback() {
                    override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                        val keyEvent = IntentCompat.getParcelableExtra(
                            mediaButtonIntent, Intent.EXTRA_KEY_EVENT, KeyEvent::class.java,
                        )
                        return keyEvent?.let(::dispatchKeyEvent) ?: false
                    }
                },
            )
        }

    /** Whether the session is currently allowed to consume supported media keys. */
    public val isArmed: Boolean
        get() = controller.isArmed

    /**
     * Activates the foreground media-button route and sends accepted commands to [onCommand].
     * Re-arming updates the callback without resetting the duplicate-event debounce window.
     */
    public fun arm(onCommand: (MonitorRemoteShutterCommand) -> Unit) {
        if (closed) return
        controller.arm(onCommand)
        mediaSession.setPlaybackState(armedPlaybackState())
        mediaSession.isActive = true
    }

    /**
     * Stops consuming media buttons and releases the active-session claim. Safe to call repeatedly
     * from an overlay, lifecycle, or composition teardown path.
     */
    public fun disarm() {
        controller.disarm()
        if (!closed) mediaSession.isActive = false
    }

    /**
     * Gives an activity-delivered key event the same policy as an event routed through the active
     * [MediaSession]. Returns true only when this armed shutter owns a supported media event.
     */
    public fun dispatchKeyEvent(event: KeyEvent): Boolean =
        !closed && controller.handleKeyEvent(
            keyCode = event.keyCode, action = event.action, repeatCount = event.repeatCount,
        )

    /** Permanently releases the platform media session during activity teardown. */
    public fun close() {
        if (closed) return
        disarm()
        mediaSession.release()
        closed = true
    }

    private fun armedPlaybackState(): PlaybackState =
        PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_STOP or PlaybackState.ACTION_PLAY_PAUSE,
            ).setState(PlaybackState.STATE_PAUSED, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 0f)
            .build()

    public companion object {
        /** The Controls row title and caption every app shows for this owner. */
        public const val TITLE: String = "Bluetooth Remote Shutter"
        public const val CAPTION: String =
            "A paired Bluetooth shutter remote's button press starts or stops recording while the live view is up front. Android cannot reliably distinguish Bluetooth from phone hardware keys, so Volume Up/Down and Play/Pause also toggle recording. Record Confirmation is skipped for remote presses."
    }
}

/**
 * Whether the front monitor is in a safe state to claim Android media keys: the operator's opt-in,
 * the live monitor in front, a connected camera, a resumed app, and no record command, record
 * confirmation or camera control already in flight, so a remote never bypasses a visible prompt.
 */
public fun monitorRemoteShutterShouldArm(
    enabled: Boolean,
    monitorIsFront: Boolean,
    cameraConnected: Boolean,
    recordCommandPending: Boolean,
    applicationResumed: Boolean,
    recordConfirmationPending: Boolean,
    cameraControlPending: Boolean,
): Boolean =
    enabled && monitorIsFront && cameraConnected && !recordCommandPending && applicationResumed &&
        !recordConfirmationPending && !cameraControlPending

/** The recording state one command asks for, or null when it is a no-op. */
public fun monitorRemoteShutterRecordingTarget(command: MonitorRemoteShutterCommand, isRecording: Boolean): Boolean? =
    when (command) {
        MonitorRemoteShutterCommand.TOGGLE -> !isRecording
        MonitorRemoteShutterCommand.START -> if (isRecording) null else true
        MonitorRemoteShutterCommand.STOP -> if (isRecording) false else null
    }

/** Pure, JVM-testable event gate shared by activity and media-session delivery. */
internal class MonitorRemoteShutterController(
    private val elapsedRealtimeMillis: () -> Long,
) {
    private var onCommand: ((MonitorRemoteShutterCommand) -> Unit)? = null
    private var lastAcceptedAtMillis: Long? = null

    val isArmed: Boolean
        get() = onCommand != null

    fun arm(onCommand: (MonitorRemoteShutterCommand) -> Unit) {
        if (!isArmed) lastAcceptedAtMillis = null
        this.onCommand = onCommand
    }

    fun disarm() {
        onCommand = null
        lastAcceptedAtMillis = null
    }

    /**
     * Consumes a supported media key only while armed. Key-up, repeat, and
     * duplicate delivery events are consumed without issuing another command,
     * keeping a single physical button press to one camera request.
     */
    fun handleKeyEvent(keyCode: Int, action: Int, repeatCount: Int): Boolean {
        val command = MonitorRemoteShutterKeyMap.commandFor(keyCode) ?: return false
        val callback = onCommand ?: return false
        if (action == KeyEvent.ACTION_UP) return true
        if (action != KeyEvent.ACTION_DOWN) return false
        if (repeatCount != 0 || isDebounced()) return true

        lastAcceptedAtMillis = elapsedRealtimeMillis()
        callback(command)
        return true
    }

    private fun isDebounced(): Boolean {
        val previous = lastAcceptedAtMillis ?: return false
        return elapsedRealtimeMillis() - previous < DEBOUNCE_MILLIS
    }

    private companion object {
        /** Swift twin: `MonitorRemoteShutterPolicy.debounceInterval`. */
        const val DEBOUNCE_MILLIS = 600L
    }
}

/** Explicit Android shutter-key allowlist used only while the monitor has armed the controller. */
internal object MonitorRemoteShutterKeyMap {
    fun commandFor(keyCode: Int): MonitorRemoteShutterCommand? =
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_VOLUME_UP,
            KeyEvent.KEYCODE_VOLUME_DOWN,
            -> MonitorRemoteShutterCommand.TOGGLE

            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_RECORD,
            -> MonitorRemoteShutterCommand.START

            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP,
            -> MonitorRemoteShutterCommand.STOP

            else -> null
        }
}
