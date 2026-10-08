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

/** Deployed four-decimal-digit UI entry rule; wire credentials stay outside UI. */
public class MonitorWatcherPasscodeDraft {
    public var digits: String = ""
        private set
    public fun update(text: String): Unit { digits = text.filter(Char::isDigit).take(4) }
    public val complete: String? get() = digits.takeIf { it.length == 4 }
}
