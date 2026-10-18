package com.opencapture.opencine.appkit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.monitorui.settings.MonitorSettingsTab
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicReference

/**
 * The one owner of the monitor's display intent: the DISP modes a source offers and the current one,
 * each mode's chrome, the chrome editor and its return to Settings, the interface lock and the
 * connect-tap arming lifetime. Every app's live surface reads it; none keeps its own copy.
 * The shell retains the camera; this owner closes presentation without sending a command.
 *
 * Swift mirror: `MonitorOperatorSessionModel` in `OpenCineAppKit`, same names.
 */
public class MonitorOperatorSessionModel(
    private val shell: ShellModel,
    public val assist: MonitorAssistState,
    private val preferences: MonitorDisplayPreferences,
    private val scope: CoroutineScope,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    private var liveValue by mutableStateOf(preferences.live)
    private var cleanValue by mutableStateOf(preferences.clean)
    private var commandValue by mutableStateOf(preferences.command)
    public var live: MonitorDisplayChrome
        get() = liveValue
        set(value) { liveValue = value; preferences.live = value }
    public var clean: MonitorDisplayChrome
        get() = cleanValue
        set(value) { cleanValue = value; preferences.clean = value }
    public var command: MonitorDisplayChrome
        get() = commandValue
        set(value) { commandValue = value; preferences.command = value }
    /**
     * The one landing-tab rule (A2-84): Settings opens on the tab the operator last chose in this app
     * run, Link at first, whichever entry opens it (home, the monitor, a cover rehost). Only the chrome
     * editor's Done picks a tab, Display, the page it returns to.
     */
    public var settingsTab: MonitorSettingsTab by mutableStateOf(MonitorSettingsTab.LINK)
    /** Each settings tab's scroll offset for this app run, so a tab reopens where it was left (A2-84). */
    public var settingsScrollOffsets: Map<MonitorSettingsTab, Int> by mutableStateOf(emptyMap())
        private set
    private val displaySession = MonitorDisplaySession(MonitorDisplayMode.LIVE)
    public var editingMode: MonitorDisplayMode?
        get() = displaySession.editingMode
        set(value) { displaySession.editingMode = value }
    public var returnedMode: MonitorDisplayMode?
        get() = displaySession.returnedMode
        set(value) { displaySession.returnedMode = value }
    /** The modes the source offers, in DISP order. Live and Clean unless a source declares more. */
    public var modes: List<MonitorDisplayMode> by mutableStateOf(listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN))
        private set
    /** The interface lock. It refuses the DISP cycle here; the surface refuses every other operator
     * input while it holds. It lasts one monitor lifetime. */
    private val commandRevision = AtomicReference(Any())
    public var locked: Boolean
        get() = displaySession.locked
        set(value) {
            if (displaySession.locked != value) commandRevision.set(Any())
            displaySession.locked = value
        }

    /** Captures this owner's local command lifetime without making an eligibility decision. */
    public fun captureCommandRevision(): () -> Boolean {
        val captured = commandRevision.get()
        return { commandRevision.get() === captured }
    }
    public var interactive: Boolean by mutableStateOf(true)
        private set
    /** Command has no assist-state twin; Live and Clean stay `assist.clean`, which assist filtering and
     * saved assist state already follow. */
    private var commandShown by mutableStateOf(false)
    private var source: String? = null
    private var revision: Long = 0
    private var armJob: Job? = null

    public val mode: MonitorDisplayMode
        get() = if (commandShown) MonitorDisplayMode.COMMAND else if (assist.clean) MonitorDisplayMode.CLEAN else MonitorDisplayMode.LIVE
    public val chrome: MonitorDisplayChrome get() = chrome(mode)
    public val isEditing: Boolean get() = editingMode != null

    public fun chrome(mode: MonitorDisplayMode): MonitorDisplayChrome = when (mode) {
        MonitorDisplayMode.LIVE -> live
        MonitorDisplayMode.CLEAN -> clean
        MonitorDisplayMode.COMMAND -> command
    }

    public fun mounts(section: MonitorDisplaySection): Boolean {
        if (editingMode == mode && MonitorDisplayChrome.isConfigurable(section, mode)) return true
        if (section == MonitorDisplaySection.RAIL_SETTINGS) {
            return com.opencapture.monitorui.MonitorSideRailPlan.showsSettings(
                chrome.railSettings, modes.any { chrome(it).railSettings })
        }
        return chrome.isVisible(section)
    }

    public fun toggle(section: MonitorDisplaySection, mode: MonitorDisplayMode): Unit {
        if (!MonitorDisplayChrome.isConfigurable(section, mode)) return
        when (mode) {
            MonitorDisplayMode.LIVE -> live = live.toggling(section)
            MonitorDisplayMode.CLEAN -> clean = clean.toggling(section)
            MonitorDisplayMode.COMMAND -> command = command.toggling(section)
        }
    }

    /** The source states which modes it offers. A current mode that leaves the set falls back to the
     * first, lock or not: the capability went, not the operator's intent. */
    public fun declare(modes: List<MonitorDisplayMode>): Unit {
        if (modes.isEmpty() || modes == this.modes) return
        this.modes = modes
        if (mode !in modes) show(modes[0])
    }

    /** DISP or a feed swipe. Refused while locked and for a mode the source does not offer. */
    public fun select(next: MonitorDisplayMode): Boolean {
        if (locked || next == mode || next !in modes) return false
        show(next)
        return true
    }

    /** The DISP key: the next offered mode. */
    public fun cycle(): Boolean = MonitorDisplaySession.next(modes, mode)?.let(::select) ?: false

    public fun beginEditing(mode: MonitorDisplayMode): Unit {
        shell.dismissCover()
        show(mode)
        displaySession.beginEditing(mode)
    }

    public fun finishEditing(): Unit {
        if (displaySession.finishEditing(modes) == null) return
        settingsTab = MonitorSettingsTab.DISPLAY
        shell.open(ShellModel.Cover.SETTINGS)
    }

    /** Opens Settings on the operator's last tab and scroll position (the landing-tab rule). */
    public fun openSettings(): Unit = shell.open(ShellModel.Cover.SETTINGS)

    /** The settings page reports where [tab] is scrolled to. */
    public fun noteSettingsScroll(tab: MonitorSettingsTab, offset: Int): Unit {
        if (settingsScrollOffsets[tab] != offset) settingsScrollOffsets = settingsScrollOffsets + (tab to offset)
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

    private fun show(next: MonitorDisplayMode) {
        if (commandShown != (next == MonitorDisplayMode.COMMAND)) commandShown = next == MonitorDisplayMode.COMMAND
        if (assist.clean != (next == MonitorDisplayMode.CLEAN)) assist.clean = next == MonitorDisplayMode.CLEAN
    }

    private fun retire() {
        commandRevision.set(Any())
        revision += 1
        armJob?.cancel(); armJob = null
        interactive = true
        locked = false
        displaySession.retireEditor()
    }
}
