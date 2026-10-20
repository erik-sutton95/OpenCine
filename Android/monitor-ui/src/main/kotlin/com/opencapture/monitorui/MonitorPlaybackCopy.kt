package com.opencapture.monitorui

import com.opencapture.opencine.media.MonitorConformPreview

/**
 * What the shared playback screen says to the operator and to assistive technologies: control
 * labels, their states and hints, the clip information sheet and the deletion confirmation.
 *
 * The Compose twin of `MonitorPlaybackCopy` (`Sources/MonitorPresentation/MonitorPlaybackCopy.swift`).
 * Nothing links the two, so `Fixtures/playback-copy.tsv` lists every string and both platforms'
 * tests read it (`MonitorPlaybackCopyVectorTests`, `MonitorPlaybackCopyVectorTest`): a label
 * edited on one side only fails a test.
 *
 * One accepted platform difference: [HIDE_CONTROLS_HINT] is read only on iOS, as the hide
 * control's accessibility hint. Compose has no hint semantics; TalkBack builds its own usage hint
 * from the click action, so Android carries the string but does not show it.
 */
object MonitorPlaybackCopy {
    // Header chrome.
    const val BACK_TO_MEDIA = "Back to media"
    const val FAVORITE = "Favorite clip"
    const val CLIP_INFORMATION = "Clip information"
    const val SHARE = "Share clip"
    const val SHARE_TITLE = "SHARE"
    const val DELETE = "Delete clip from camera"

    // Clip information sheet.
    const val CLIP_INFORMATION_TITLE = "CLIP INFO"
    const val CLOSE_CLIP_INFORMATION = "Close clip information"

    // Deletion confirmation, when the host supplies no captured copy of its own.
    const val DELETE_CONFIRMATION_TITLE = "Delete this clip from the camera?"
    const val DELETE_CONFIRM = "Delete"
    const val DELETE_CANCEL = "Cancel"
    const val DELETE_CANCEL_DESCRIPTION = "Cancel deletion"
    const val DELETE_CONFIRM_DESCRIPTION = "Delete from the camera card"

    // Transport.
    const val BACK_FIFTEEN = "Back 15 seconds"
    const val FORWARD_FIFTEEN = "Forward 15 seconds"
    const val PLAY = "Play"
    const val PAUSE = "Pause"
    const val RESTART = "Restart clip"
    const val PREVIOUS_CLIP = "Previous clip"
    const val NEXT_CLIP = "Next clip"

    // Options.
    const val CONFORM_PREVIEW = "Conform preview"
    const val CLOSE_CONFORM_PREVIEW = "Close conform preview"
    const val MUTE = "Mute"
    const val UNMUTE = "Unmute"
    const val LOOP = "Loop playback"
    const val ON = "On"
    const val OFF = "Off"
    const val HIDE_CONTROLS = "Hide playback controls"
    /** iOS reads it as the hide control's hint; Compose has no hint semantics (TalkBack derives its own). */
    const val HIDE_CONTROLS_HINT = "A restore control stays in the corner"
    const val SHOW_CONTROLS = "Show playback controls"

    // Conform preview panel.
    const val CONFORM_TITLE = "CONFORM PREVIEW"
    /** The drum's first choice: play as recorded. */
    const val REAL_TIME = "Real time"

    // Scrubber. The gesture well over the picture has no label on either platform: a screen
    // reader cannot act on it (tests find it by [MonitorPlaybackTags.PICTURE]).
    const val POSITION = "Playback position"

    // Rating shade.
    const val SHOW_RATING = "Show star rating"
    const val HIDE_RATING = "Hide star rating"

    /** The one transport button: restart after the end, else pause while playing, else play. */
    fun transport(reachedEnd: Boolean, playing: Boolean): String =
        if (reachedEnd) RESTART else if (playing) PAUSE else PLAY

    fun muteToggle(muted: Boolean): String = if (muted) UNMUTE else MUTE

    /** The state read with a toggle's label (the loop chip). */
    fun toggleValue(on: Boolean): String = if (on) ON else OFF

    /** The scrubber's state: whole seconds, never negative; an unknown position reads 0. */
    fun positionValue(seconds: Double): String {
        val whole = if (seconds.isFinite()) seconds.coerceAtLeast(0.0).toLong() else 0L
        return "$whole seconds"
    }

    /** The conform panel's line under its title: the clip's capture rate, leading into the choices. */
    fun conformSubtitle(captureRate: Double): String = MonitorConformPreview.menuHeader(captureRate)

    fun rating(expanded: Boolean): String = if (expanded) HIDE_RATING else SHOW_RATING

    /** One star choice of the rating control. */
    fun rate(level: Int): String = "Rate $level ${if (level == 1) "star" else "stars"}"
}

/** Test tags of shared playback nodes that carry no accessibility label. */
object MonitorPlaybackTags {
    /** The gesture well over the picture (pinch, pan, tap, frame scrub). */
    const val PICTURE = "monitor.playback.picture"
}
