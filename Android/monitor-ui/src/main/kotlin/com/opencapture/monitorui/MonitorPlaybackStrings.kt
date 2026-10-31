package com.opencapture.monitorui

import com.opencapture.opencine.media.MonitorConformPreview

/**
 * The units and the leading word [MonitorPlaybackStrings] composes, so a translation table can
 * carry them: a label like "Rate 1 star" is a sentence in one language and two tokens in another.
 */
internal object MonitorPlaybackCopyUnits {
    const val RATE = "Rate"
    const val SECONDS = "seconds"
    const val STAR = "star"
    const val STARS = "stars"
}

/**
 * The playback surface's copy resolved for one language.
 *
 * Member names match [MonitorPlaybackCopy], so a screen swaps `MonitorPlaybackCopy.PLAY` for
 * `copy.play` and reads the same string in the operator's language. English resolves to the
 * constants themselves, so the fixture-pinned text stays byte identical.
 */
internal class MonitorPlaybackStrings(
    private val catalog: CopyCatalog,
    private val language: CopyLanguage,
) {
    private fun t(english: String): String = catalog.text(english, language)

    // Header chrome.
    val backToMedia: String get() = t(MonitorPlaybackCopy.BACK_TO_MEDIA)
    val favorite: String get() = t(MonitorPlaybackCopy.FAVORITE)
    val clipInformation: String get() = t(MonitorPlaybackCopy.CLIP_INFORMATION)
    val share: String get() = t(MonitorPlaybackCopy.SHARE)
    val shareTitle: String get() = t(MonitorPlaybackCopy.SHARE_TITLE)
    val delete: String get() = t(MonitorPlaybackCopy.DELETE)

    // Clip information sheet.
    val clipInformationTitle: String get() = t(MonitorPlaybackCopy.CLIP_INFORMATION_TITLE)
    val closeClipInformation: String get() = t(MonitorPlaybackCopy.CLOSE_CLIP_INFORMATION)

    // Deletion confirmation.
    val deleteConfirmationTitle: String get() = t(MonitorPlaybackCopy.DELETE_CONFIRMATION_TITLE)
    val deleteConfirm: String get() = t(MonitorPlaybackCopy.DELETE_CONFIRM)
    val deleteCancel: String get() = t(MonitorPlaybackCopy.DELETE_CANCEL)
    val deleteCancelDescription: String get() = t(MonitorPlaybackCopy.DELETE_CANCEL_DESCRIPTION)
    val deleteConfirmDescription: String get() = t(MonitorPlaybackCopy.DELETE_CONFIRM_DESCRIPTION)

    // Transport.
    val backFifteen: String get() = t(MonitorPlaybackCopy.BACK_FIFTEEN)
    val forwardFifteen: String get() = t(MonitorPlaybackCopy.FORWARD_FIFTEEN)
    val play: String get() = t(MonitorPlaybackCopy.PLAY)
    val pause: String get() = t(MonitorPlaybackCopy.PAUSE)
    val restart: String get() = t(MonitorPlaybackCopy.RESTART)
    val previousClip: String get() = t(MonitorPlaybackCopy.PREVIOUS_CLIP)
    val nextClip: String get() = t(MonitorPlaybackCopy.NEXT_CLIP)

    // Options.
    val conformPreview: String get() = t(MonitorPlaybackCopy.CONFORM_PREVIEW)
    val closeConformPreview: String get() = t(MonitorPlaybackCopy.CLOSE_CONFORM_PREVIEW)
    val mute: String get() = t(MonitorPlaybackCopy.MUTE)
    val unmute: String get() = t(MonitorPlaybackCopy.UNMUTE)
    val loop: String get() = t(MonitorPlaybackCopy.LOOP)
    val on: String get() = t(MonitorPlaybackCopy.ON)
    val off: String get() = t(MonitorPlaybackCopy.OFF)
    val hideControls: String get() = t(MonitorPlaybackCopy.HIDE_CONTROLS)

    /** iOS reads it as the hide control's hint; Compose has no hint semantics. */
    val hideControlsHint: String get() = t(MonitorPlaybackCopy.HIDE_CONTROLS_HINT)
    val showControls: String get() = t(MonitorPlaybackCopy.SHOW_CONTROLS)

    // Conform preview panel.
    val conformTitle: String get() = t(MonitorPlaybackCopy.CONFORM_TITLE)
    val realTime: String get() = t(MonitorPlaybackCopy.REAL_TIME)

    // Scrubber.
    val position: String get() = t(MonitorPlaybackCopy.POSITION)

    // Rating shade.
    val showRating: String get() = t(MonitorPlaybackCopy.SHOW_RATING)
    val hideRating: String get() = t(MonitorPlaybackCopy.HIDE_RATING)

    /** The one transport button: restart after the end, else pause while playing, else play. */
    fun transport(reachedEnd: Boolean, playing: Boolean): String =
        if (reachedEnd) restart else if (playing) pause else play

    fun muteToggle(muted: Boolean): String = if (muted) unmute else mute

    /** The state read with a toggle's label (the loop chip). */
    fun toggleValue(on: Boolean): String = if (on) this.on else off

    /** The scrubber's state: whole seconds, never negative; an unknown position reads 0. */
    fun positionValue(seconds: Double): String {
        val whole = if (seconds.isFinite()) seconds.coerceAtLeast(0.0).toLong() else 0L
        return "$whole ${t(MonitorPlaybackCopyUnits.SECONDS)}"
    }

    /**
     * The conform panel's line under its title. The capture rate is a number and a unit that the
     * shared media layer formats, so it stays one implementation for every language.
     */
    fun conformSubtitle(captureRate: Double): String = MonitorConformPreview.menuHeader(captureRate)

    fun rating(expanded: Boolean): String = if (expanded) hideRating else showRating

    /** One star choice of the rating control. */
    fun rate(level: Int): String {
        val unit = if (level == 1) MonitorPlaybackCopyUnits.STAR else MonitorPlaybackCopyUnits.STARS
        return "${t(MonitorPlaybackCopyUnits.RATE)} $level ${t(unit)}"
    }
}

/** The playback copy in [language], reading [catalog] when the host supplies one. */
internal fun MonitorPlaybackCopy.resolved(
    language: CopyLanguage,
    catalog: CopyCatalog = CopyCatalog.bundled,
): MonitorPlaybackStrings = MonitorPlaybackStrings(catalog, language)
