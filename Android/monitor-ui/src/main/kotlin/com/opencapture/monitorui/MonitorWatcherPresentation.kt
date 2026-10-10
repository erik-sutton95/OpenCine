package com.opencapture.monitorui

/** Real producer revision changes for reconnect and lease changes, including ABA changes. */
public data class MonitorWatcherContext(public val source: String, public val revision: Long, public val canControl: Boolean, public val recording: Boolean) {
    public val tapSource: MonitorWatcherTapSource
        get() = MonitorWatcherTapSource(source, revision, canControl)
}
/** A picture gesture belongs to one source and lease; recording reports do not change it. */
public data class MonitorWatcherTapSource(public val source: String, public val revision: Long, public val canControl: Boolean) {
    public fun admits(current: MonitorWatcherTapSource): Boolean =
        canControl && current.canControl && source == current.source && revision == current.revision
}
public data class MonitorWatcherFocus(public val source: MonitorWatcherTapSource, public val x: Double, public val y: Double)
public enum class MonitorWatcherSetting { ISO, SHUTTER, ZOOM }
public data class MonitorWatcherChoice(public val id: Int, public val title: String)
public data class MonitorWatcherSettingValue(public val id: MonitorWatcherSetting, public val title: String, public val choices: List<MonitorWatcherChoice>)
public data class MonitorWatcherReading(public val title: String, public val value: String?)
public data class MonitorWatcherNotice(public val message: String, public val canChooseFeed: Boolean = false)
public data class MonitorWatcherPresentation(public val context: MonitorWatcherContext, public val hostTitle: String, public val receivedFPS: Int?,
    public val readings: List<MonitorWatcherReading>, public val settings: List<MonitorWatcherSettingValue>, public val holderName: String,
    public val canRequestControl: Boolean, public val controlRequested: Boolean, public val notice: MonitorWatcherNotice?) {
    public fun admits(action: MonitorWatcherAction): Boolean = when (action) {
        is MonitorWatcherAction.Set -> action.context == context && context.canControl &&
            settings.any { it.id == action.setting && it.choices.any { choice -> choice.id == action.choice } }
        is MonitorWatcherAction.Record -> action.context == context && context.canControl && action.desired != context.recording
        MonitorWatcherAction.RequestControl -> canRequestControl && !controlRequested
        MonitorWatcherAction.ReleaseControl -> context.canControl
        MonitorWatcherAction.ChooseFeed -> notice?.canChooseFeed == true
        MonitorWatcherAction.Leave -> true
    }
}
public sealed interface MonitorWatcherAction {
    public data object Leave : MonitorWatcherAction
    public data object ChooseFeed : MonitorWatcherAction
    public data object RequestControl : MonitorWatcherAction
    public data object ReleaseControl : MonitorWatcherAction
    public data class Set(public val context: MonitorWatcherContext, public val setting: MonitorWatcherSetting, public val choice: Int) : MonitorWatcherAction
    public data class Record(public val context: MonitorWatcherContext, public val desired: Boolean) : MonitorWatcherAction
}

/** The dialog captures an explicit target. Closing sends no command. */
public class MonitorWatcherInteraction {
    public var pendingRecording: MonitorWatcherContext? = null
        private set
    public var focus: MonitorWatcherFocus? = null
        private set
    public fun applyFocus(value: MonitorWatcherFocus, current: MonitorWatcherTapSource): Boolean {
        if (!value.source.admits(current)) return false
        focus = value
        return true
    }
    public fun retireFocus(current: MonitorWatcherTapSource): Unit {
        if (focus?.source?.admits(current) == false) focus = null
    }
    public fun update(context: MonitorWatcherContext, clean: Boolean): Unit {
        if (clean || pendingRecording != context) cancel()
    }
    public fun requestRecording(context: MonitorWatcherContext, confirm: Boolean): MonitorWatcherAction? {
        cancel()
        if (!context.canControl) return null
        if (confirm) { pendingRecording = context; return null }
        return MonitorWatcherAction.Record(context, !context.recording)
    }
    public fun confirmRecording(context: MonitorWatcherContext): MonitorWatcherAction? {
        val captured = pendingRecording
        cancel()
        if (captured == null || captured != context || !context.canControl) return null
        return MonitorWatcherAction.Record(context, !captured.recording)
    }
    public fun cancel(): Unit { pendingRecording = null }
}
