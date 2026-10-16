package com.opencapture.monitorui

/** The common watcher measures the picture; native leaves consume this source-bound value. */
public data class MonitorWatcherPictureGeometry(public val source: MonitorWatcherTapSource,
    public val viewport: MonitorRect, public val feed: MonitorRect,
    public val bottomClearance: Double, public val mirrored: Boolean) {
    public fun belongsTo(current: MonitorWatcherTapSource): Boolean =
        source.source == current.source && source.revision == current.revision
}

/** Existing relay key lane above the monitor's system and assist bars, in points or dp. */
public object MonitorWatcherControlPlacement {
    public fun bottomInset(portrait: Boolean): Double = if (portrait) 192.0 else 84.0
}

/** Common notice wording; the adapter only maps its transport phase. */
public object MonitorWatcherNotices {
    public val joining: MonitorWatcherNotice get() = MonitorWatcherNotice("Joining shared feed…")
    public val waitingForPicture: MonitorWatcherNotice get() = MonitorWatcherNotice("Waiting for picture from the host…")
    public fun reconnecting(attempt: Int, maximum: Int): MonitorWatcherNotice = MonitorWatcherNotice("Reconnecting… $attempt of $maximum")
    public fun failed(message: String): MonitorWatcherNotice = MonitorWatcherNotice(message, canChooseFeed = true)
}
public enum class MonitorWatcherConnectionPhase { JOINING, WATCHING, DENIED, FAILED }
/** Optional join/control facts when the shared live surface already owns picture/tools. */
public data class MonitorWatcherConnectionOverlayValue(public val phase: MonitorWatcherConnectionPhase,
    public val canControl: Boolean, public val canRequestControl: Boolean,
    public val needsPasscode: Boolean, public val passcodeWasWrong: Boolean,
    public val failureReason: String?, public val controlBottomInset: Double)

/**
 * The one watcher passcode rule, shared by the broadcaster's setting and the watcher's join entry
 * on every app and both platforms (Swift twin: `MonitorWatcherPasscodeRule` in MonitorPresentation).
 *
 * A passcode is any text of at least [MINIMUM_LENGTH] characters (Unicode code points, so both
 * platforms count alike) once surrounding whitespace is trimmed; an empty one means an open
 * broadcast. The relay compares codes after the same trim (`RelayJoinPolicy`), so what one side
 * accepts the other side matches.
 *
 * The minimum judges only a code being chosen now. A code saved before this rule (four digits on
 * one app) stays in force: hosts keep requiring it, watchers keep sending it, and a watcher may
 * answer any non-empty code because only the host knows which code it requires.
 */
public object MonitorWatcherPasscodeRule {
    public const val MINIMUM_LENGTH: Int = 4

    /** Shown under a broadcaster's entry that is not yet long enough to take effect. */
    public const val TOO_SHORT_HINT: String = "At least 4 characters, or empty for an open feed."

    /** What a broadcaster's entry means. */
    public sealed interface Entry {
        /** The value to store and require, null while the entry is too short. */
        public val passcode: String?

        /** Empty: the broadcast is open. */
        public data object Open : Entry { override val passcode: String get() = "" }

        /** A passcode to require, trimmed. */
        public data class Code(val code: String) : Entry { override val passcode: String get() = code }

        /** Too short to take effect; the code already in force stays. */
        public data object TooShort : Entry { override val passcode: String? get() = null }
    }

    /**
     * Surrounding spaces, tabs and line breaks never count as part of a passcode. The same set as
     * Swift's `whitespacesAndNewlines`: Unicode Z* separators, U+0009 to U+000D and U+0085.
     */
    public fun normalized(text: String): String = text.trim(::isPasscodeWhitespace)

    /** Judges a passcode a broadcaster is choosing now. */
    public fun entry(text: String): Entry {
        val code = normalized(text)
        return when {
            code.isEmpty() -> Entry.Open
            code.codePointCount(0, code.length) >= MINIMUM_LENGTH -> Entry.Code(code)
            else -> Entry.TooShort
        }
    }

    /** A watcher's answer to a host that asked for a passcode: the trimmed code, null when empty. */
    public fun answer(text: String): String? = normalized(text).takeIf { it.isNotEmpty() }

    private fun isPasscodeWhitespace(ch: Char): Boolean = ch in '\u0009'..'\u000D' || ch == '\u0085' ||
        when (Character.getType(ch).toByte()) {
            Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true
            else -> false
        }
}
