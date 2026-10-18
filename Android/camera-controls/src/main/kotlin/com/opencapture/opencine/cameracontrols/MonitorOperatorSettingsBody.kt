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
import android.widget.Toast
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import com.opencapture.monitorui.settings.LocalMonitorSettingsScrollContext
import com.opencapture.monitorui.settings.MonitorDisplaySettings
import androidx.compose.runtime.MutableIntState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.settings.MonitorPanelSettings
import com.opencapture.monitorui.settings.MonitorSettingsPage
import com.opencapture.monitorui.settings.MonitorSettingsRowCard
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsTab
import com.opencapture.monitorui.settings.MonitorAssistSettingsSection
import com.opencapture.monitorui.settings.MonitorViewAssistSettings
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorOperatorDisplaySections
import com.opencapture.opencine.appkit.MonitorOperatorPreferences
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel

/**
 * The picture tabs' content, which still has one owner per source: the View Assist cards (the
 * deployed card set and the configured calibrated sections) and Display (the configured display
 * store until it adopts the shared display session). Every other tab is one recipe over
 * [MonitorOperatorSettingsConfiguration].
 */
internal sealed interface MonitorOperatorPictureSettings {
    class Deployed(
        val model: OperatorSetupModel,
        val state: OperatorSetupState,
        val app: OperatorSetupApp,
    ) : MonitorOperatorPictureSettings

    class Configured(
        val assistSections: List<MonitorAssistSettingsSection>,
        val display: MonitorOperatorDisplaySource?,
        val borrowedDisplay: MonitorOperatorBorrowedDisplay? = null,
        val assist: MonitorOperatorAssistSettingsSource? = null,
    ) : MonitorOperatorPictureSettings

    class Session(
        val preferences: MonitorOperatorPreferences,
        val session: MonitorOperatorSessionModel,
        val assist: MonitorAssistState,
        val availableAssistTools: Set<MonitorAssistTool>,
        val assistHost: AssistHost,
        val lookOptions: AssistLutPicker?,
    ) : MonitorOperatorPictureSettings
}

internal class MonitorOperatorSettingsInputs(
    val configuration: MonitorOperatorSettingsConfiguration,
    val selection: MonitorSettingsTab,
    val onSelect: (MonitorSettingsTab) -> Unit,
    val picture: MonitorOperatorPictureSettings,
    val sourceIdentity: Any? = null,
    /** Each tab's scroll offset and where the open tab is scrolled to (A2-84). */
    val scrollOffsets: Map<MonitorSettingsTab, Int> = emptyMap(),
    val onScroll: (MonitorSettingsTab, Int) -> Unit = { _, _ -> },
)

/** One full-cover settings recipe for every app; [MonitorOperatorPictureSettings] supplies the picture tabs. */
@Composable
internal fun MonitorOperatorSettingsBody(inputs: MonitorOperatorSettingsInputs) {
    val configuration = inputs.configuration
    BackHandler(onBack = configuration.close)
    val legalPage = remember { mutableStateOf<MonitorLegalPage?>(null) }
    var showLutPicker by remember { mutableStateOf(false) }
    val revision = remember { mutableIntStateOf(0) }
    val context = LocalContext.current
    LaunchedEffect(inputs.selection) {
        val picture = inputs.picture
        if (inputs.selection == MonitorSettingsTab.DISPLAY && picture is MonitorOperatorPictureSettings.Configured) {
            picture.borrowedDisplay?.returnedFromEditor?.invoke()
        }
    }
    val openLegal: (MonitorLegalPage) -> Unit = { page ->
        val legal = configuration.legal
        if (legal != null && !legal.open(page, context) { legalPage.value = it }) {
            Toast.makeText(context, MONITOR_LINK_UNAVAILABLE, Toast.LENGTH_SHORT).show()
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize().background(MonitorPalette.background)
        .pointerInput(Unit) { detectTapGestures {} }
        .windowInsetsPadding(WindowInsets.safeDrawing)) {
        val compact = maxWidth < 600.dp
        MonitorSettingsPage(configuration.brand, inputs.selection, inputs.onSelect, configuration.isLive,
            configuration.phase, configuration.disconnect, configuration.feedback, tabs = configuration.tabs,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            sharingSubtitle = configuration.sharingSubtitle, sharingRail = configuration.sharingRail,
            back = configuration.close, scrollOffsets = inputs.scrollOffsets, onScroll = inputs.onScroll) { tab ->
            key(inputs.sourceIdentity) {
                MonitorOperatorSettingsRows(inputs, tab, compact, revision, openLegal,
                    onOpenLut = { showLutPicker = true }, onPreferenceChanged = { revision.intValue++ })
            }
        }
        val legal = configuration.legal
        val page = legalPage.value
        if (legal != null && page != null) MonitorLegalDocumentScreen(legal, page) { legalPage.value = null }
        val picture = inputs.picture
        if (picture is MonitorOperatorPictureSettings.Deployed && showLutPicker) picture.app.lutPicker { showLutPicker = false }
    }
}

internal const val MONITOR_LINK_UNAVAILABLE: String = "No app is available for that action."

@Composable
private fun MonitorOperatorSettingsRows(
    inputs: MonitorOperatorSettingsInputs,
    tab: MonitorSettingsTab,
    compact: Boolean,
    revision: MutableIntState,
    openLegal: (MonitorLegalPage) -> Unit,
    onOpenLut: () -> Unit,
    onPreferenceChanged: () -> Unit,
) {
    // Plain preferences do not publish snapshots. Observe their revision in this actual scope.
    @Suppress("UNUSED_VARIABLE") val observedRevision = revision.intValue
    val configuration = inputs.configuration
    val picture = inputs.picture
    when (tab) {
        MonitorSettingsTab.LINK -> SettingsLink(configuration.link)
        MonitorSettingsTab.SHARING -> SettingsSharing(configuration.sharing, configuration.feedback)
        MonitorSettingsTab.ASSIST -> when (picture) {
            is MonitorOperatorPictureSettings.Deployed -> AssistRows(picture.model, picture.state, picture.app, onOpenLut)
            is MonitorOperatorPictureSettings.Configured -> {
                val assist = picture.assist
                if (assist != null) MonitorOperatorAssistSettings(assist)
                else MonitorViewAssistSettings(picture.assistSections)
            }
            is MonitorOperatorPictureSettings.Session -> SessionAssistSettings(picture)
        }
        MonitorSettingsTab.CONTROLS -> {
            SettingsGyro(configuration.gyro, configuration.feedback)
            SettingsControls(configuration.controls, configuration.feedback)
        }
        MonitorSettingsTab.DISPLAY -> when (picture) {
            is MonitorOperatorPictureSettings.Deployed -> OperatorDisplayRows(picture.model, picture.state, picture.app)
            is MonitorOperatorPictureSettings.Configured -> {
                val display = picture.display
                if (display != null) OperatorDisplaySections(display.session,
                    display.available, display.edit, revision, onPreferenceChanged, configuration.feedback)
                else {
                    val borrowed = requireNotNull(picture.borrowedDisplay)
                    MonitorDisplaySettings(borrowed.layoutTitle, borrowed.layoutHelp, borrowed.choices,
                        borrowed.selection, borrowed.onSelect, borrowed.expandedSection, borrowed.onExpand,
                        borrowed.sections, borrowed.order, compact, configuration.feedback,
                        LocalMonitorSettingsScrollContext.current)
                }
            }
            is MonitorOperatorPictureSettings.Session -> SessionDisplaySettings(picture, configuration.isLive,
                revision, onPreferenceChanged)
        }
        MonitorSettingsTab.STORAGE -> SettingsStorage(configuration)
        MonitorSettingsTab.SYSTEM -> SettingsSystem(configuration, openLegal)
    }
}

@Composable
private fun SessionAssistSettings(source: MonitorOperatorPictureSettings.Session) {
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
private fun SessionDisplaySettings(source: MonitorOperatorPictureSettings.Session, live: Boolean,
    revision: MutableIntState, onPreferenceChanged: () -> Unit) {
    @Suppress("UNUSED_VARIABLE") val observedRevision = revision.intValue
    val preferences = source.preferences
    val session = source.session
    MonitorPanelSettings(preferences.hdrDisplay, "Show the native monitor in HDR when the display supports it.",
        { preferences.hdrDisplay = it; onPreferenceChanged() })
    OperatorDisplaySections(session, setOf(MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.CAMERA_VALUES,
        MonitorDisplaySection.LOCK_BUTTON, MonitorDisplaySection.REC_READOUT, MonitorDisplaySection.TIMECODE,
        MonitorDisplaySection.TOOL_BAR,
        MonitorDisplaySection.RAIL_RECORD, MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_SETTINGS),
        if (live) session::beginEditing else null, revision, onPreferenceChanged)
}

/** The one Display form over the session: each declared mode's chrome, its pins and its Edit view. */
@Composable
private fun OperatorDisplaySections(session: MonitorOperatorSessionModel, available: Set<MonitorDisplaySection>,
    edit: ((MonitorDisplayMode) -> Unit)?, revision: MutableIntState, onPreferenceChanged: () -> Unit,
    feedback: () -> Unit = {}) {
    @Suppress("UNUSED_VARIABLE") val observedRevision = revision.intValue
    MonitorOperatorDisplaySections(session.modes, session::chrome, session.assist,
        onChange = { mode, value ->
            when (mode) {
                MonitorDisplayMode.LIVE -> session.live = value
                MonitorDisplayMode.CLEAN -> session.clean = value
                MonitorDisplayMode.COMMAND -> session.command = value
            }
            onPreferenceChanged()
        }, available = available, edit = edit, feedback = feedback)
}
