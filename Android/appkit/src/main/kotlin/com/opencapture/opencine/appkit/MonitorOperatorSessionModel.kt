package com.opencapture.opencine.appkit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.monitorui.settings.MonitorSettingsTab
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Owns display editing, reachable settings and one cancellable connect-tap arming lifetime. */
public class MonitorOperatorSessionModel(
    private val shell: ShellModel,
    private val assist: MonitorAssistState,
    private val preferences: MonitorDisplayPreferences,
    private val scope: CoroutineScope,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    private var liveValue by mutableStateOf(preferences.live)
    private var cleanValue by mutableStateOf(preferences.clean)
    public var live: MonitorDisplayChrome
        get() = liveValue
        set(value) { liveValue = value; preferences.live = value }
    public var clean: MonitorDisplayChrome
        get() = cleanValue
        set(value) { cleanValue = value; preferences.clean = value }
    public var settingsTab: MonitorSettingsTab by mutableStateOf(MonitorSettingsTab.LINK)
    private val displaySession = MonitorDisplaySession(MonitorDisplayMode.LIVE)
    public var editingMode: MonitorDisplayMode?
        get() = displaySession.editingMode
        set(value) { displaySession.editingMode = value }
    public var returnedMode: MonitorDisplayMode?
        get() = displaySession.returnedMode
        set(value) { displaySession.returnedMode = value }
    public var interactive: Boolean by mutableStateOf(true)
        private set
    private var source: String? = null
    private var revision: Long = 0
    private var armJob: Job? = null

    public val mode: MonitorDisplayMode get() = if (assist.clean) MonitorDisplayMode.CLEAN else MonitorDisplayMode.LIVE
    public val chrome: MonitorDisplayChrome get() = chrome(mode)
    public val isEditing: Boolean get() = editingMode != null

    public fun chrome(mode: MonitorDisplayMode): MonitorDisplayChrome = if (mode == MonitorDisplayMode.CLEAN) clean else live

    public fun mounts(section: MonitorDisplaySection): Boolean {
        if (editingMode == mode) return true
        if (section == MonitorDisplaySection.RAIL_SETTINGS && !live.railSettings && !clean.railSettings) return true
        return chrome.isVisible(section)
    }

    public fun toggle(section: MonitorDisplaySection, mode: MonitorDisplayMode): Unit {
        if (mode == MonitorDisplayMode.CLEAN) clean = clean.toggling(section) else live = live.toggling(section)
    }

    public fun beginEditing(mode: MonitorDisplayMode): Unit {
        shell.dismissCover()
        assist.clean = mode == MonitorDisplayMode.CLEAN
        displaySession.beginEditing(mode)
    }

    public fun finishEditing(): Unit {
        if (displaySession.finishEditing(MonitorDisplayMode.entries) == null) return
        settingsTab = MonitorSettingsTab.DISPLAY
        shell.open(ShellModel.Cover.SETTINGS)
    }

    /** The shell monitor ID changes on reentry even when the same camera session is reused. */
    public fun synchronize(source: String?): Unit {
        if (source == this.source) return
        retire()
        this.source = source
        if (source == null) return
        interactive = false
        val capturedRevision = revision
        armJob = scope.launch {
            sleep(550)
            if (this@MonitorOperatorSessionModel.source == source && revision == capturedRevision) {
                interactive = true
                armJob = null
            }
        }
    }

    public fun close(): Unit { retire(); source = null }

    private fun retire() {
        revision += 1
        armJob?.cancel(); armJob = null
        interactive = true
        displaySession.retireEditor()
    }
}
