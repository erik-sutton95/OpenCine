package com.opencapture.opencine.cameracontrols

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableIntState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.settings.LocalMonitorSettingsScrollContext
import com.opencapture.monitorui.settings.MonitorDisplaySettings
import com.opencapture.monitorui.settings.MonitorInputOrientationSettings
import com.opencapture.monitorui.settings.MonitorOperatorSafetySettings
import com.opencapture.monitorui.settings.MonitorPanelSettings
import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import com.opencapture.monitorui.settings.MonitorSettingsPage
import com.opencapture.monitorui.settings.MonitorSettingsRowCard
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsTab
import com.opencapture.monitorui.settings.MonitorViewAssistSettings
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorMediaLibraryModel
import com.opencapture.opencine.appkit.MonitorOperatorDisplaySections
import com.opencapture.opencine.appkit.MonitorOperatorPreferences
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel

/** Actual source records vary; the page, navigation and common row dispatch do not. */
internal sealed interface MonitorOperatorSettingsSource {
    class Deployed(
        val model: OperatorSetupModel,
        val state: OperatorSetupState,
        val app: OperatorSetupApp,
        val linkBars: Int,
    ) : MonitorOperatorSettingsSource

    class Configured(
        val configuration: MonitorOperatorSettingsConfiguration,
        val display: MonitorOperatorBorrowedDisplay,
    ) : MonitorOperatorSettingsSource

    class Session<P>(
        val preferences: MonitorOperatorPreferences,
        val session: MonitorOperatorSessionModel,
        val assist: MonitorAssistState,
        val library: MonitorMediaLibraryModel<P>?,
        val cameraName: String?,
        val availableAssistTools: Set<MonitorAssistTool>,
        val assistHost: AssistHost,
        val lookOptions: AssistLutPicker?,
        val diagnostics: () -> Unit,
        val reportProblem: () -> Unit,
    ) : MonitorOperatorSettingsSource
}

internal class MonitorOperatorSettingsInputs(
    val brand: String,
    val selection: MonitorSettingsTab,
    val onSelect: (MonitorSettingsTab) -> Unit,
    val isLive: Boolean,
    val phase: String,
    val close: () -> Unit,
    val disconnect: (() -> Unit)?,
    val source: MonitorOperatorSettingsSource,
    val feedback: () -> Unit = {},
    val tabs: List<MonitorSettingsTab> = MonitorSettingsTab.entries,
    val sourceIdentity: Any? = null,
    val sharingSubtitle: String? = null,
    val sharingRail: String? = null,
)

/** One full-cover settings recipe for deployed, configured and generated entry points. */
@Composable
internal fun MonitorOperatorSettingsBody(inputs: MonitorOperatorSettingsInputs) {
    BackHandler(onBack = inputs.close)
    var legalPage by remember { mutableStateOf<OperatorLegalPage?>(null) }
    var showLutPicker by remember { mutableStateOf(false) }
    val revision = remember { mutableIntStateOf(0) }
    LaunchedEffect(inputs.selection) {
        val source = inputs.source
        if (inputs.selection == MonitorSettingsTab.DISPLAY && source is MonitorOperatorSettingsSource.Configured) {
            source.display.returnedFromEditor()
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize().background(MonitorPalette.background)
        .pointerInput(Unit) { detectTapGestures {} }
        .windowInsetsPadding(WindowInsets.safeDrawing)) {
        val compact = maxWidth < 600.dp
        MonitorSettingsPage(inputs.brand, inputs.selection, inputs.onSelect, inputs.isLive,
            inputs.phase, inputs.disconnect, inputs.feedback, tabs = inputs.tabs,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            sharingSubtitle = inputs.sharingSubtitle, sharingRail = inputs.sharingRail,
            back = inputs.close) { tab ->
            key(inputs.sourceIdentity) {
                MonitorOperatorSettingsRows(inputs, tab, compact, revision,
                    onLegal = { legalPage = it }, onOpenLut = { showLutPicker = true },
                    onPreferenceChanged = { revision.intValue++ })
            }
        }
        val source = inputs.source
        if (source is MonitorOperatorSettingsSource.Deployed) {
            legalPage?.let { page -> source.app.legalPage(page) { legalPage = null } }
            if (showLutPicker) source.app.lutPicker { showLutPicker = false }
        }
    }
}

@Composable
private fun MonitorOperatorSettingsRows(
    inputs: MonitorOperatorSettingsInputs,
    tab: MonitorSettingsTab,
    compact: Boolean,
    revision: MutableIntState,
    onLegal: (OperatorLegalPage) -> Unit,
    onOpenLut: () -> Unit,
    onPreferenceChanged: () -> Unit,
) {
    // Plain preferences do not publish snapshots. Observe their revision in this actual scope.
    @Suppress("UNUSED_VARIABLE") val observedRevision = revision.intValue
    val source = inputs.source
    when (tab) {
        MonitorSettingsTab.LINK -> when (source) {
            is MonitorOperatorSettingsSource.Deployed -> LinkRows(source.model, source.state, source.app,
                inputs.isLive, inputs.phase, source.linkBars)
            is MonitorOperatorSettingsSource.Configured -> SettingsLink(source.configuration.link)
            is MonitorOperatorSettingsSource.Session<*> -> MonitorSettingsRowCard("Connection") {
                Text(source.cameraName ?: "No camera connected", color = MonitorPalette.text)
            }
        }
        MonitorSettingsTab.SHARING -> when (source) {
            is MonitorOperatorSettingsSource.Deployed -> SharingRows()
            is MonitorOperatorSettingsSource.Configured -> source.configuration.sharing?.let {
                SettingsSharing(it, inputs.feedback)
            }
            is MonitorOperatorSettingsSource.Session<*> -> Unit
        }
        MonitorSettingsTab.ASSIST -> when (source) {
            is MonitorOperatorSettingsSource.Deployed -> AssistRows(source.model, source.state, source.app, onOpenLut)
            is MonitorOperatorSettingsSource.Configured -> MonitorViewAssistSettings(source.configuration.assistSections)
            is MonitorOperatorSettingsSource.Session<*> -> SessionAssistSettings(source)
        }
        MonitorSettingsTab.CONTROLS -> when (source) {
            is MonitorOperatorSettingsSource.Deployed -> ControlsRows(source.model, source.state, source.app)
            is MonitorOperatorSettingsSource.Configured -> {
                val controls = source.configuration.controls
                MonitorOperatorSafetySettings(controls.recordConfirmation, controls.haptics, controls.keepAwake,
                    controls.setRecordConfirmation, controls.setHaptics, controls.setKeepAwake,
                    keepScreenAwakeHelp = controls.keepAwakeHelp, feedback = inputs.feedback)
                MonitorInputOrientationSettings(controls.remoteShutter, controls.setRemoteShutter,
                    remoteTitle = controls.remoteTitle, remoteCaption = controls.remoteCaption,
                    autoRotateFeed = controls.autoRotateFeed, onAutoRotateFeed = controls.setAutoRotateFeed,
                    rotationTitle = controls.rotationTitle, rotationHelp = controls.rotationHelp,
                    feedback = inputs.feedback)
            }
            is MonitorOperatorSettingsSource.Session<*> -> {
                val preferences = source.preferences
                MonitorOperatorSafetySettings(preferences.recordConfirmation, preferences.haptics, preferences.keepScreenAwake,
                    { preferences.recordConfirmation = it; onPreferenceChanged() },
                    { preferences.haptics = it; onPreferenceChanged() },
                    { preferences.keepScreenAwake = it; onPreferenceChanged() })
            }
        }
        MonitorSettingsTab.DISPLAY -> when (source) {
            is MonitorOperatorSettingsSource.Deployed -> OperatorDisplayRows(source.model, source.state, source.app, inputs.isLive)
            is MonitorOperatorSettingsSource.Configured -> {
                val display = source.display
                val scroll = LocalMonitorSettingsScrollContext.current
                MonitorDisplaySettings(display.layoutTitle, display.layoutHelp,
                    display.choices, display.selection, display.onSelect,
                    display.expandedSection, display.onExpand, display.sections,
                    display.order, compact, inputs.feedback, scroll)
            }
            is MonitorOperatorSettingsSource.Session<*> -> SessionDisplaySettings(source, inputs.isLive, revision, onPreferenceChanged)
        }
        MonitorSettingsTab.STORAGE -> when (source) {
            is MonitorOperatorSettingsSource.Deployed -> StorageRows(source.model, source.app)
            is MonitorOperatorSettingsSource.Configured -> {
                source.configuration.account?.let { SettingsAccount(it) }
                source.configuration.cache?.let { cache ->
                    MonitorOperatorCacheSettings(cache.source, scopeHelp = cache.scopeHelp,
                        clearHelp = cache.clearHelp, formatBytes = cache.formatBytes, feedback = inputs.feedback,
                        checkingLabel = cache.checking, readFailureLabel = cache.readFailure,
                        clearFailureLabel = cache.clearFailure, confirmClear = cache.confirmClear,
                        summaryColor = cache.summaryColor)
                }
            }
            is MonitorOperatorSettingsSource.Session<*> -> SessionCacheSettings(source, revision, onPreferenceChanged)
        }
        MonitorSettingsTab.SYSTEM -> when (source) {
            is MonitorOperatorSettingsSource.Deployed -> SystemRows(source.model, source.app, onLegal)
            is MonitorOperatorSettingsSource.Configured -> SettingsSystem(source.configuration.support,
                source.configuration.information, inputs.feedback)
            is MonitorOperatorSettingsSource.Session<*> -> MonitorSettingsRowCard("Diagnostics") {
                MonitorSettingsActionPill("Diagnostics", onClick = source.diagnostics)
                MonitorSettingsActionPill("Report a problem", onClick = source.reportProblem)
            }
        }
    }
}

@Composable
private fun SessionAssistSettings(source: MonitorOperatorSettingsSource.Session<*>) {
    val assist = source.assist
    MonitorSettingsRowCard("View Assist") {
        source.availableAssistTools.forEach { tool ->
            MonitorSettingsSwitchInlineRow(tool.title, assist.isOn(tool),
                help = "Apply this monitor tool to the displayed picture.", testTag = "monitor.assist.${tool.name}") {
                assist.toggle(tool)
            }
            if (tool !in setOf(MonitorAssistTool.EV, MonitorAssistTool.LEVEL) &&
                (tool != MonitorAssistTool.LUT || source.lookOptions != null)) {
                AssistOptionsPanel(tool, assist, {}, source.assistHost, source.lookOptions, embedded = true,
                    transfer = assist.scopeBundle.transfer)
            }
        }
    }
}

@Composable
private fun SessionDisplaySettings(source: MonitorOperatorSettingsSource.Session<*>, live: Boolean,
    revision: MutableIntState, onPreferenceChanged: () -> Unit) {
    @Suppress("UNUSED_VARIABLE") val observedRevision = revision.intValue
    val preferences = source.preferences
    val session = source.session
    MonitorPanelSettings(preferences.hdrDisplay, "Show the native monitor in HDR when the display supports it.",
        { preferences.hdrDisplay = it; onPreferenceChanged() })
    MonitorOperatorDisplaySections(session.modes, session::chrome, source.assist,
        onChange = { mode, value ->
            when (mode) {
                MonitorDisplayMode.LIVE -> session.live = value
                MonitorDisplayMode.CLEAN -> session.clean = value
                MonitorDisplayMode.COMMAND -> session.command = value
            }
            onPreferenceChanged()
        }, available = setOf(MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.CAMERA_VALUES,
            MonitorDisplaySection.LOCK_BUTTON, MonitorDisplaySection.REC_READOUT, MonitorDisplaySection.TIMECODE,
            MonitorDisplaySection.TOOL_BAR,
            MonitorDisplaySection.RAIL_RECORD, MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_SETTINGS),
        edit = if (live) session::beginEditing else null)
}

@Composable
private fun <P> SessionCacheSettings(source: MonitorOperatorSettingsSource.Session<P>,
    revision: MutableIntState, onPreferenceChanged: () -> Unit) {
    @Suppress("UNUSED_VARIABLE") val observedRevision = revision.intValue
    val library = source.library
    if (library != null) MonitorOperatorCacheSettings(library, source.preferences.cacheOriginals,
        { source.preferences.cacheOriginals = it; onPreferenceChanged() })
}
