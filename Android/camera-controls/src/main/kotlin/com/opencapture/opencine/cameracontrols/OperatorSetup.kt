package com.opencapture.opencine.cameracontrols

import android.content.Context
import android.content.res.Configuration
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorScopeGuides
import com.opencapture.monitorui.MonitorVectorscopeZoom
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.monitorui.MonitorJoystickSize
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.settings.MonitorExposureMeterSettings
import com.opencapture.monitorui.settings.MonitorMotionChoiceSetting
import com.opencapture.monitorui.settings.MonitorMotionIntegerSetting
import com.opencapture.monitorui.settings.MonitorMotionToggleSetting
import com.opencapture.monitorui.settings.MonitorDisplayChoice
import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import com.opencapture.monitorui.settings.MonitorSettingsColorDot
import com.opencapture.monitorui.settings.MonitorSettingsColorDots
import com.opencapture.monitorui.settings.MonitorSettingsCrushClipSegmented
import com.opencapture.monitorui.settings.MonitorSettingsDisplayToggle
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsPercentSlider
import com.opencapture.monitorui.settings.MonitorSettingsRowCard
import com.opencapture.monitorui.settings.MonitorSettingsSegmented
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsTab
import com.opencapture.monitorui.settings.MonitorSettingsValueSlider
import com.opencapture.monitorui.settings.MonitorSettingsValueText
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorDisplayChrome
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.diagnostics.FeedIncidentRuntime
import com.opencapture.opencine.appkit.diagnostics.ManualProblemReport
import com.opencapture.opencine.appkit.diagnostics.ManualProblemReportDialog
import com.opencapture.opencine.appkit.diagnostics.settingsStatus
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReporting
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.opencine.media.MonitorDesqueezeDirection
import com.opencapture.opencine.media.MonitorDesqueezePreset
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.MonitorZebraPaint
import com.opencapture.opencine.media.ScopeClipSource
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.GamepadGimbalStick
import com.opencapture.opencine.vocabulary.fromColorMode
import kotlinx.coroutines.delay

/** What Operator Setup reads and changes on the app's model; each app's AppModel implements it. */
interface OperatorSetupModel : GamepadHost {
    var operatorSettingsTab: MonitorSettingsTab
    var chromeEditorReturnMode: MonitorDisplayMode?
    val assist: MonitorAssistState
    val cameras: CamerasModel
    val lutSelection: String
    val keepScreenAwake: Boolean
    val hdrDisplay: Boolean
    val cacheFullResolution: Boolean
    val recordConfirmationEnabled: Boolean
    val gimbalStickSensitivity: Int
    val virtualJoystickSize: MonitorJoystickSize
    val virtualJoystickInvertPan: Boolean
    val virtualJoystickInvertTilt: Boolean
    val virtualJoystickDeadzonePercent: Int
    val virtualJoystickResponseCurve: CameraCommands.VirtualJoystickCurve
    val gimbalGamepad: GimbalGamepadDriver
    fun updateKeepScreenAwake(value: Boolean)
    fun updateHdrDisplay(value: Boolean)
    fun updateCacheFullResolution(value: Boolean)
    fun updateRecordConfirmationEnabled(value: Boolean)
    fun updateHapticsEnabled(value: Boolean)
    fun updateGimbalStickSensitivity(value: Int)
    fun updateVirtualJoystickSize(value: MonitorJoystickSize)
    fun updateVirtualJoystickInvertPan(value: Boolean)
    fun updateVirtualJoystickInvertTilt(value: Boolean)
    fun updateVirtualJoystickDeadzonePercent(value: Int)
    fun updateVirtualJoystickResponseCurve(value: CameraCommands.VirtualJoystickCurve)
    fun chrome(mode: MonitorDisplayMode): MonitorDisplayChrome
    fun toggleChrome(section: MonitorDisplaySection, mode: MonitorDisplayMode)
    fun beginChromeEditing(mode: MonitorDisplayMode)
    fun updateCleanViewPinnedTools(value: Set<String>)
    fun disconnect()
}

/** The link and body as the app reports them now; the app rebuilds it when its status changes. */
class OperatorSetupState(
    val phase: ConnectionPhase,
    val failure: String?,
    val colorMode: Int,
    val network: String?,
    val cameraName: String?,
    val cameraFamily: String?,
    val layout: MonitorLayoutCapabilities,
    val lookProfile: com.opencapture.opencine.vocabulary.CameraLUTProfile? = null,
)

/** The decoder and link counters the Link Health tile samples twice a second. */
class OperatorLinkSample(val framesEnqueued: Int, val lastPresentedAt: Long?, val videoPackets: Int, val hasVideoFormat: Boolean)

/** The App Information card: what the app is and how it talks to the camera. */
class OperatorAppInformation(
    val theme: String,
    val themeHelp: String,
    val protocol: String,
    val protocolHelp: String,
    val version: String,
    val versionHelp: String,
    val termsHelp: String,
)

/** The diagnostics the System rows report through (the app's Sentry wiring and session report). */
class OperatorDiagnostics(
    val reporting: ReliabilityReporting,
    val manualReport: ManualProblemReport,
    val incidents: FeedIncidentRuntime,
    val diagnosticText: () -> String,
    val shareReport: (Context) -> Unit,
    /** The report form's action pills: full touch targets or main's capsule size. */
    val reportActionMinimumTouchTarget: Boolean,
)

/** The app's part of Operator Setup: its name, copy, links, stores and pages. */
class OperatorSetupApp(
    val wordmark: String,
    val help: OperatorHelpCopy,
    val prefs: OperatorPreferenceStore,
    val assistHost: AssistHost,
    /** Legacy cache directories, read only when [cacheSource] is null. */
    val mediaCache: OperatorMediaCacheDirs? = null,
    val clearMediaCache: ((Context) -> Unit)? = null,
    val upscalers: List<String>,
    val upscaler: (Context) -> String,
    val setUpscaler: (Context, String) -> Unit,
    val linkSample: () -> OperatorLinkSample,
    val information: OperatorAppInformation,
    val sourceUrl: String,
    val diagnostics: OperatorDiagnostics,
    /** Privacy, terms, licenses and NOTICE, in Settings and wherever the app links privacy. */
    val legal: MonitorLegalDocuments,
    val lutPicker: @Composable (() -> Unit) -> Unit,
    /**
     * Captured existing cache IO; no page or storage policy is supplied by the app. An app whose gallery
     * runs on a shared library passes [monitorSettingsCacheSource] over it, so Settings counts and
     * clears what the gallery writes.
     */
    val cacheSource: (@Composable (Context) -> com.opencapture.opencine.appkit.MonitorSettingsCacheSource)? = null,
)

fun toggledCleanPins(prefs: OperatorPreferenceStore, current: Set<String>, toolKey: String): Set<String> {
    val next = current.toMutableSet()
    if (!next.add(toolKey)) next.remove(toolKey)
    return prefs.resolvedCleanPins(next)
}

fun resetDispChrome(model: OperatorSetupModel, mode: MonitorDisplayMode) {
    val defaults = if (mode == MonitorDisplayMode.LIVE) MonitorDisplayChrome.liveDefaults else MonitorDisplayChrome.cleanDefaults
    MonitorDisplaySection.entries.forEach { section ->
        if (model.chrome(mode).isVisible(section) != defaults.isVisible(section)) model.toggleChrome(section, mode)
    }
}

/** Operator Setup with each app's main rows; the app supplies its model, live state and [app] values. */
@Composable
fun OperatorSetupScreen(model: OperatorSetupModel, state: OperatorSetupState, app: OperatorSetupApp, onClose: () -> Unit) {
    var tick by remember { mutableIntStateOf(0) }
    var lastFrames by remember { mutableIntStateOf(0) }
    var lastTickAt by remember { mutableLongStateOf(0L) }
    var measuredFps by remember { mutableDoubleStateOf(0.0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(500)
            tick += 1
            val now = SystemClock.elapsedRealtime()
            val sample = app.linkSample()
            if (lastTickAt != 0L) {
                val dt = (now - lastTickAt) / 1000.0
                val presentedAge = sample.lastPresentedAt?.let { now - it }
                measuredFps =
                    if (dt > 0 && presentedAge != null && presentedAge < 1_500) {
                        ((sample.framesEnqueued - lastFrames) / dt).coerceAtLeast(0.0)
                    } else {
                        0.0
                    }
            }
            lastFrames = sample.framesEnqueued
            lastTickAt = now
        }
    }
    tick
    val isLive = state.phase == ConnectionPhase.LIVE
    val sample = app.linkSample()
    val bars = OperatorLinkHealth.bars(isLive, sample.videoPackets, sample.hasVideoFormat, measuredFps)
    val phaseLabel = connectionPhaseLabel(state.phase, state.failure)
    val view = LocalView.current
    val context = LocalContext.current

    LaunchedEffect(model.chromeEditorReturnMode) {
        if (model.chromeEditorReturnMode == null) return@LaunchedEffect
        model.chromeEditorReturnMode = null
    }

    val legalPage = remember { mutableStateOf<MonitorLegalPage?>(null) }
    var showReportForm by remember { mutableStateOf(false) }
    val configuration = operatorSetupConfiguration(model, state, app, isLive, phaseLabel, bars, onClose,
        feedback = { operatorHaptic(view, model.hapticsEnabled) }, report = { showReportForm = true })
    MonitorOperatorSettingsBody(MonitorOperatorSettingsInputs(configuration, model.operatorSettingsTab,
        { model.operatorSettingsTab = it }, MonitorOperatorPictureSettings.Deployed(model, state, app), legalPage = legalPage))
    if (showReportForm) {
        val diagnostics = app.diagnostics
        ManualProblemReportDialog(
            diagnostics.manualReport, diagnostics.diagnosticText, diagnostics.reportActionMinimumTouchTarget,
            onClose = { showReportForm = false },
            onPrivacy = {
                showReportForm = false
                app.legal.open(MonitorLegalPage.PRIVACY, context) { legalPage.value = it }
            },
        )
    }
}

/** The deployed apps' settings as one configuration over their model: the same recipe every app builds. */
@Composable
private fun operatorSetupConfiguration(
    model: OperatorSetupModel, state: OperatorSetupState, app: OperatorSetupApp,
    isLive: Boolean, phaseLabel: String, bars: Int, onClose: () -> Unit,
    feedback: () -> Unit, report: () -> Unit,
): MonitorOperatorSettingsConfiguration {
    val context = LocalContext.current
    val diagnostics = app.diagnostics
    var upscaler by remember { mutableStateOf(app.upscaler(context)) }
    var gimbalGamepadStick by remember { mutableStateOf(app.prefs.gimbalGamepadStick(context)) }
    var reliabilityOptIn by remember { mutableStateOf(diagnostics.reporting.isOptedIn) }
    val reportSnapshot by diagnostics.manualReport.snapshot.collectAsState()
    val saved = model.cameras.state.collectAsState().value.saved
    val cacheSource = app.cacheSource?.invoke(context) ?: run {
        val dirs = requireNotNull(app.mediaCache) { "Operator Setup needs a cache source or the legacy cache directories" }
        val clear = requireNotNull(app.clearMediaCache) { "Legacy cache directories need their clear action" }
        com.opencapture.opencine.appkit.MonitorSettingsCacheSource(
            com.opencapture.opencine.appkit.MonitorSettingsCacheIdentity(dirs.candidates(context).first().absolutePath, null),
            0L, isCurrent = { true },
            count = { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { dirs.byteCount(context) } },
            clear = { clear(context) },
        )
    }
    fun <T> changed(next: T, current: T, apply: (T) -> Unit) {
        if (next != current) { feedback(); apply(next) }
    }
    val gimbal = state.layout.gimbal
    val information = app.information
    return MonitorOperatorSettingsConfiguration(
        brand = app.wordmark, isLive = isLive, phase = phaseLabel, close = onClose, disconnect = model::disconnect,
        feedback = feedback,
        link = MonitorSettingsLinkSource(
            transport = if (isLive) "BLE + Wi-Fi active" else "Not connected", transportHelp = app.help.CURRENT_TRANSPORT,
            phase = phaseLabel, phaseHelp = app.help.PHASE, healthTitle = "Link Health",
            healthCaption = OperatorLinkHealth.caption(isLive, bars), score = OperatorLinkHealth.score(bars),
            processingTitle = "Processing",
            processingChoices = if (app.upscalers.size > 1) listOf(MonitorSettingsChoiceSource("Feed Upscaler",
                app.help.FEED_UPSCALER, app.upscalers.map { MonitorDisplayChoice(it, it) }, upscaler,
                select = { label -> upscaler = label; app.setUpscaler(context, label) }, segmented = true)) else emptyList(),
            network = state.network, networkHelp = app.help.CAMERA_WIFI,
            savedCameras = monitorSavedCameraSummaries(saved), savedCamerasHelp = app.help.SAVED_CAMERAS,
        ),
        sharing = null, sharingSubtitle = null, sharingRail = null,
        controls = MonitorSettingsControlsSource(
            model.recordConfirmationEnabled, model::updateRecordConfirmationEnabled,
            model.hapticsEnabled, model::updateHapticsEnabled, model.keepScreenAwake, model::updateKeepScreenAwake,
            keepAwakeHelp = app.help.KEEP_SCREEN_AWAKE, hapticsHelp = app.help.HAPTICS,
            motion = MonitorSettingsMotionSource(
                sensitivity = if (!gimbal) null else MonitorMotionIntegerSetting(model.gimbalStickSensitivity, 1..5,
                    app.help.JOYSTICK_SENSITIVITY) { changed(it, model.gimbalStickSensitivity, model::updateGimbalStickSensitivity) },
                joystick = if (!gimbal) null else MonitorSettingsJoystickSource(
                    size = MonitorMotionChoiceSetting(MonitorJoystickSize.entries.map { it.label },
                        model.virtualJoystickSize.label, app.help.VIRTUAL_JOYSTICK_SIZE) { label ->
                        changed(MonitorJoystickSize.fromLabel(label), model.virtualJoystickSize, model::updateVirtualJoystickSize)
                    },
                    invertPan = MonitorMotionToggleSetting(model.virtualJoystickInvertPan,
                        app.help.VIRTUAL_JOYSTICK_INVERT_PAN) { feedback(); model.updateVirtualJoystickInvertPan(it) },
                    invertTilt = MonitorMotionToggleSetting(model.virtualJoystickInvertTilt,
                        app.help.VIRTUAL_JOYSTICK_INVERT_TILT) { feedback(); model.updateVirtualJoystickInvertTilt(it) },
                    deadZone = MonitorMotionIntegerSetting(model.virtualJoystickDeadzonePercent, 0..25,
                        app.help.VIRTUAL_JOYSTICK_DEADZONE, suffix = "%") {
                        changed(it, model.virtualJoystickDeadzonePercent, model::updateVirtualJoystickDeadzonePercent)
                    },
                    response = MonitorMotionChoiceSetting(CameraCommands.VirtualJoystickCurve.entries.map { it.label },
                        model.virtualJoystickResponseCurve.label, app.help.VIRTUAL_JOYSTICK_RESPONSE) { label ->
                        changed(CameraCommands.VirtualJoystickCurve.fromLabel(label), model.virtualJoystickResponseCurve,
                            model::updateVirtualJoystickResponseCurve)
                    },
                    identifier = "gimbal.virtual",
                ),
                controller = MonitorMotionChoiceSetting(GamepadGimbalStick.entries.map { it.label },
                    gimbalGamepadStick.label, app.help.GIMBAL_JOYSTICK) { label ->
                    changed(GamepadGimbalStick.fromLabel(label), gimbalGamepadStick) { next ->
                        app.prefs.setGimbalGamepadStick(context, next)
                        gimbalGamepadStick = next
                        model.gimbalGamepad.noteStickSelectionChanged(model)
                    }
                },
                controllerStatus = if (model.gamepadConnected) "Connected" else "Not connected",
                controllerHelp = app.help.GAMEPAD,
            ),
        ),
        cache = MonitorSettingsCachePresentation(cacheSource, formatBytes = { if (it == 0L) "Empty" else formatCacheSize(it) },
            scopeHelp = app.help.LOCAL_CACHE, clearHelp = app.help.CLEAR_CACHE,
            cacheOriginals = model.cacheFullResolution, setCacheOriginals = model::updateCacheFullResolution,
            cacheHelp = app.help.CACHE_FULL_RESOLUTION),
        unconfiguredAccount = MonitorSettingsReadoutSource("Frame.io", app.help.FRAME_IO, null),
        support = MonitorSettingsSupportSource(report = report,
            automaticReports = reliabilityOptIn, available = diagnostics.reporting.isAvailable,
            automaticHelp = app.help.RELIABILITY_REPORTS, unavailableHelp = app.help.RELIABILITY_UNAVAILABLE,
            setAutomaticReports = { reliabilityOptIn = it; diagnostics.reporting.setConsent(it) },
            status = reportSnapshot.settingsStatus,
            discard = if (reportSnapshot.allowsDiscard) ({ diagnostics.manualReport.discard() }) else null,
            sourceUrl = app.sourceUrl, sourceHelp = app.help.SOURCE, termsHelp = information.termsHelp),
        diagnostics = MonitorSettingsDiagnosticsSource(save = { diagnostics.shareReport(context) },
            incidents = diagnostics.incidents),
        legal = app.legal,
        information = MonitorSettingsInformationSource(information.theme, information.protocol, information.version,
            information.themeHelp, information.protocolHelp, information.versionHelp),
    )
}

// View Assist: main's cards (two columns in landscape), on the settings controls.

@Composable
internal fun AssistRows(model: OperatorSetupModel, state: OperatorSetupState, app: OperatorSetupApp, onOpenLut: () -> Unit) {
    val assist = model.assist
    val colorMode = state.colorMode
    val transfer = MonitorTransfer.fromColorMode(colorMode)
    @Composable fun card(tool: MonitorAssistTool) = OperatorAssistCard(tool, assist, app.help, app.assistHost, transfer)
    if (LocalConfiguration.current.orientation == Configuration.ORIENTATION_PORTRAIT) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA, MonitorAssistTool.WAVE, MonitorAssistTool.PARADE,
                MonitorAssistTool.HISTO, MonitorAssistTool.VECTOR, MonitorAssistTool.PEAK, MonitorAssistTool.LIGHTS).forEach { card(it) }
        }
    } else {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(MonitorAssistTool.FALSE, MonitorAssistTool.WAVE, MonitorAssistTool.HISTO, MonitorAssistTool.PEAK).forEach { card(it) }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(MonitorAssistTool.ZEBRA, MonitorAssistTool.PARADE, MonitorAssistTool.VECTOR, MonitorAssistTool.LIGHTS).forEach { card(it) }
            }
        }
    }

    MonitorExposureMeterSettings(
        isOn = assist.evMeter,
        help = "Show the camera's exposure meter at the picture's left edge in DISP 1. Auto and Manual use the camera reading without changing exposure settings.",
        onToggle = { assist.toggle(MonitorAssistTool.EV) },
    )

    MonitorSettingsRowCard(title = "Anamorphic Desqueeze", onReset = {
        assist.updateDesqueezeFactor(1.33)
        assist.selectDesqueezePreset(MonitorDesqueezePreset.X133)
        assist.updateDesqueezeDirection(MonitorDesqueezeDirection.HORIZONTAL)
    }) {
        MonitorSettingsSwitchInlineRow("Enabled", isOn = assist.desqueeze, showTopDivider = false) {
            assist.toggle(MonitorAssistTool.DESQ)
        }
        DesqueezeOptions(assist)
    }

    MonitorSettingsRowCard(title = "LUT") {
        MonitorSettingsInlineRow("Look", app.help.LUT_LOOK, showTopDivider = false) {
            MonitorSettingsValueText(
                lutLookLabel(
                    selection = model.lutSelection,
                    enabled = assist.lutOn,
                    colorMode = colorMode,
                    profile = state.lookProfile,
                ),
            )
        }
        MonitorSettingsInlineRow("Choose look") {
            MonitorSettingsActionPill(title = "Open", minimumTouchTarget = false, onClick = onOpenLut)
        }
    }
}

/** One of main's eight View Assist cards, tagged `settings.assist.<name>`. */
@Composable
fun OperatorAssistCard(tool: MonitorAssistTool, assist: MonitorAssistState, help: OperatorHelpCopy, host: AssistHost, transfer: MonitorTransfer) {
    val ceiling = host.scopeCeiling(assist)
    val (tag, card) = when (tool) {
        MonitorAssistTool.FALSE -> "falseColor" to @Composable { FalseColorAssistCard(assist, help, transfer, ceiling) }
        MonitorAssistTool.ZEBRA -> "zebra" to @Composable { ZebraAssistCard(assist, help, host, transfer, ceiling) }
        MonitorAssistTool.WAVE -> "waveform" to @Composable { WaveformAssistCard(assist, help) }
        MonitorAssistTool.PARADE -> "parade" to @Composable { ParadeAssistCard(assist, help) }
        MonitorAssistTool.HISTO -> "histogram" to @Composable { HistogramAssistCard(assist) }
        MonitorAssistTool.VECTOR -> "vectorscope" to @Composable { VectorscopeAssistCard(assist, help) }
        MonitorAssistTool.PEAK -> "peaking" to @Composable { PeakingAssistCard(assist, help, host) }
        MonitorAssistTool.LIGHTS -> "trafficLights" to @Composable { TrafficLightsAssistCard(assist, help) }
        else -> return
    }
    Box(Modifier.testTag("settings.assist.$tag")) { card() }
}

@Composable
private fun FalseColorAssistCard(assist: MonitorAssistState, help: OperatorHelpCopy, transfer: MonitorTransfer, ceiling: ScopeClipSource) {
    MonitorSettingsRowCard(
        title = "False Color",
        onReset = { assist.resetSettings(MonitorAssistTool.FALSE) },
    ) {
        MonitorSettingsInlineRow("Scale", help.FALSE_COLOR_SCALE, showTopDivider = false, stacked = true) {
            MonitorSettingsSegmented(
                options = listOf("CineStop", "Video", "IRE", "Limits"),
                selected = assist.falseColorScale.menuLabel,
            ) { label -> assist.setFalseColor(scale = MonitorFalseColorSelection.fromMenuLabel(label)) }
        }
        MonitorSettingsInlineRow(title = "Reference key", stacked = true) {
            FalseColorKey(assist.falseColorScale, transfer, ceiling)
        }
        MonitorSettingsSwitchInlineRow(
            title = "Reference Display",
            isOn = assist.falseColorReference,
            help = help.FALSE_COLOR_REFERENCE,
            stacked = true,
        ) { assist.setFalseColor(reference = !assist.falseColorReference) }
    }
}

/** The false color bands with their stop or signal ruler (main's settings key). */
@Composable
private fun FalseColorKey(scale: MonitorFalseColorSelection, transfer: MonitorTransfer, ceiling: ScopeClipSource) {
    val segments = FalseColorReference.segments(scale, transfer, ceiling = ceiling)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Canvas(Modifier.fillMaxWidth().height(11.dp)) {
            drawRect(Color.White.copy(alpha = 0.5f))
            segments.forEach { segment ->
                val lo = segment.lowerFraction.toFloat()
                val hi = segment.upperFraction.toFloat()
                drawRect(
                    Color(segment.band.red.toFloat(), segment.band.green.toFloat(), segment.band.blue.toFloat()),
                    Offset(size.width * lo, 0f),
                    Size(maxOf(1f, size.width * (hi - lo)), size.height),
                )
            }
        }
        if (scale.usesSceneStops) {
            BoxWithConstraints(Modifier.fillMaxWidth().height(12.dp)) {
                val rulerWidth = maxWidth
                FalseColorReference.sceneStopMarkers(transfer, ceiling = ceiling).forEach { marker ->
                    Text(marker.label, style = LiveType.mono(7f), color = LiveDesign.muted,
                        modifier = Modifier.offset(x = (rulerWidth * marker.fraction.toFloat() - 8.dp)
                            .coerceIn(0.dp, (rulerWidth - 16.dp).coerceAtLeast(0.dp))))
                }
            }
        } else {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                FalseColorReference.axisLabels(scale).forEach { label ->
                    Text(label, style = LiveType.ui(7f), color = LiveDesign.muted)
                }
            }
        }
    }
}

@Composable
private fun PeakingAssistCard(assist: MonitorAssistState, help: OperatorHelpCopy, host: AssistHost) {
    MonitorSettingsRowCard(
        title = "Peaking",
        onReset = { assist.resetSettings(MonitorAssistTool.PEAK) },
    ) {
        MonitorSettingsInlineRow("Sensitivity", help.PEAKING_SENSITIVITY, showTopDivider = false, stacked = true) {
            MonitorSettingsSegmented(
                options = MonitorPeakingSense.entries.map { it.label },
                selected = assist.peakingSensitivity.label,
            ) { label -> assist.setPeaking(sense = MonitorPeakingSense.fromPersisted(label)) }
        }
        MonitorSettingsInlineRow("Color", help.PEAKING_COLOR, stacked = true) {
            MonitorSettingsColorDots(dots = host.peakingColors, selectedName = assist.peakingColor.label) { name ->
                assist.setPeaking(color = MonitorPeakingColor.fromPersisted(name))
            }
        }
    }
}

@Composable
private fun ZebraAssistCard(assist: MonitorAssistState, help: OperatorHelpCopy, host: AssistHost, transfer: MonitorTransfer, ceiling: ScopeClipSource) {
    MonitorSettingsRowCard(
        title = "Zebra",
        onReset = { assist.resetSettings(MonitorAssistTool.ZEBRA) },
    ) {
        MonitorSettingsInlineRow("Units", help.ZEBRA_UNITS, showTopDivider = false, stacked = true) {
            MonitorSettingsSegmented(options = listOf("0-255", "IRE"), selected = assist.zebraUnit.editorLabel) { label ->
                assist.updateZebraUnit(MonitorZebraUnit.fromEditorLabel(label))
            }
        }
        val maximum = ZebraEditor.editorMaximum(assist.zebraUnit)
        ZebraZoneRow(
            title = "Highlight",
            help = help.ZEBRA_HIGHLIGHT,
            enabled = assist.zebraHighlight,
            value = ZebraEditor.displayValue(assist.zebraHighlightIRE, assist.zebraUnit, transfer, ceiling),
            maximum = maximum,
            selectedColor = assist.zebraHighlightColor.label,
            palette = host.highlightColors,
            onEnabled = { assist.setZebraHighlight(enabled = !assist.zebraHighlight) },
            onValue = { assist.setZebraHighlight(ire = ZebraEditor.ireFromDisplay(it, assist.zebraUnit, transfer, ceiling)) },
            onColor = { assist.setZebraHighlight(color = MonitorZebraPaint.fromPersisted(it)) },
        )
        ZebraZoneRow(
            title = "Midtone",
            help = help.ZEBRA_MIDTONE,
            enabled = assist.zebraMidtone,
            value = ZebraEditor.displayValue(assist.zebraMidtoneIRE, assist.zebraUnit, transfer, ceiling),
            maximum = maximum,
            selectedColor = assist.zebraMidtoneColor.label,
            palette = host.midtoneColors,
            onEnabled = { assist.setZebraMidtone(enabled = !assist.zebraMidtone) },
            onValue = { assist.setZebraMidtone(ire = ZebraEditor.ireFromDisplay(it, assist.zebraUnit, transfer, ceiling)) },
            onColor = { assist.setZebraMidtone(color = MonitorZebraPaint.fromPersisted(it)) },
        )
    }
}

@Composable
private fun ZebraZoneRow(
    title: String,
    help: String,
    enabled: Boolean,
    value: Int,
    maximum: Int,
    selectedColor: String,
    palette: List<MonitorSettingsColorDot>,
    onEnabled: () -> Unit,
    onValue: (Int) -> Unit,
    onColor: (String) -> Unit,
) {
    MonitorSettingsSwitchInlineRow(title = title, help = help, isOn = enabled, onToggle = onEnabled)
    Column(Modifier.padding(start = 14.dp).alpha(if (enabled) 1f else 0.4f)) {
        MonitorSettingsInlineRow(title = "Threshold") {
            MonitorSettingsValueSlider(
                value = value.coerceIn(0, maximum),
                range = 0..maximum,
                label = "$value",
                labelWidth = 34,
                onChange = onValue,
                modifier = Modifier.semantics { contentDescription = "$title threshold" },
            )
        }
        MonitorSettingsInlineRow(title = "Colour") {
            MonitorSettingsColorDots(dots = palette, selectedName = selectedColor, onSelect = onColor)
        }
    }
}

@Composable
private fun WaveformAssistCard(assist: MonitorAssistState, help: OperatorHelpCopy) {
    MonitorSettingsRowCard(
        title = "Waveform",
        onReset = { assist.resetSettings(MonitorAssistTool.WAVE) },
    ) {
        MonitorSettingsInlineRow("Mode", showTopDivider = false, stacked = true) {
            MonitorSettingsSegmented(options = MonitorWaveformMode.entries.map { it.label }, selected = assist.waveMode.label) { label ->
                assist.setWaveform(mode = MonitorWaveformMode.fromPersisted(label))
            }
        }
        MonitorSettingsInlineRow("Brightness", help.WAVEFORM_BRIGHTNESS, stacked = true) {
            MonitorSettingsPercentSlider(value = assist.waveBrightness, range = 0..200) { assist.setWaveform(brightness = it) }
        }
        ScopeGuideRows(assist.waveGuides) { assist.setWaveform(guides = it) }
    }
}

@Composable
private fun ParadeAssistCard(assist: MonitorAssistState, help: OperatorHelpCopy) {
    MonitorSettingsRowCard(
        title = "Parade",
        onReset = { assist.resetSettings(MonitorAssistTool.PARADE) },
    ) {
        MonitorSettingsInlineRow("Mode", showTopDivider = false, stacked = true) {
            MonitorSettingsSegmented(options = MonitorParadeMode.entries.map { it.label }, selected = assist.paradeMode.label) { label ->
                assist.setParade(mode = MonitorParadeMode.fromPersisted(label))
            }
        }
        MonitorSettingsInlineRow("Brightness", help.PARADE_BRIGHTNESS, stacked = true) {
            MonitorSettingsPercentSlider(value = assist.paradeBrightness, range = 0..200) { assist.setParade(brightness = it) }
        }
        ScopeGuideRows(assist.paradeGuides) { assist.setParade(guides = it) }
    }
}

@Composable
private fun HistogramAssistCard(assist: MonitorAssistState) {
    MonitorSettingsRowCard(
        title = "Histogram",
        onReset = { assist.resetSettings(MonitorAssistTool.HISTO) },
    ) {
        MonitorSettingsSwitchInlineRow(
            title = HistogramAssist.TRAFFIC_LIGHTS_TITLE,
            isOn = assist.histoTrafficLights,
            help = HistogramAssist.TRAFFIC_LIGHTS_HELP,
            showTopDivider = false,
            stacked = true,
        ) { assist.setHistogram(traffic = !assist.histoTrafficLights) }
        MonitorSettingsInlineRow(title = HistogramAssist.COMPENSATION_TITLE, help = HistogramAssist.COMPENSATION_HELP, stacked = true) {
            CrushClipControl(assist.crushClipCompensation) { assist.setHistogram(compensation = it) }
        }
    }
}

@Composable
private fun VectorscopeAssistCard(assist: MonitorAssistState, help: OperatorHelpCopy) {
    MonitorSettingsRowCard(
        title = "Vectorscope",
        onReset = { assist.resetSettings(MonitorAssistTool.VECTOR) },
    ) {
        MonitorSettingsInlineRow("Trace Zoom", help.VECTORSCOPE_ZOOM, showTopDivider = false, stacked = true) {
            MonitorSettingsSegmented(options = MonitorVectorscopeZoom.entries.map { it.label }, selected = assist.vectorZoom.label) { label ->
                assist.setVectorscope(zoom = MonitorVectorscopeZoom.fromPersisted(label))
            }
        }
        MonitorSettingsInlineRow("Brightness", help.VECTORSCOPE_BRIGHTNESS, stacked = true) {
            MonitorSettingsPercentSlider(value = assist.vectorBrightness, range = 0..200) { assist.setVectorscope(brightness = it) }
        }
    }
}

@Composable
private fun TrafficLightsAssistCard(assist: MonitorAssistState, help: OperatorHelpCopy) {
    MonitorSettingsRowCard(title = "Traffic Lights", onReset = { assist.resetSettings(MonitorAssistTool.LIGHTS) }) {
        MonitorSettingsInlineRow(
            title = HistogramAssist.COMPENSATION_TITLE,
            help = help.TRAFFIC_LIGHTS_COMPENSATION,
            showTopDivider = false,
            stacked = true,
        ) { CrushClipControl(assist.crushClipCompensation) { assist.setCompensation(it) } }
    }
}

@Composable
private fun CrushClipControl(selected: MonitorCrushClipCompensation, onSelect: (MonitorCrushClipCompensation) -> Unit) {
    MonitorSettingsCrushClipSegmented(
        options = MonitorCrushClipCompensation.entries.map { it.label to it.compactLabel },
        selectedLabel = selected.label,
    ) { label -> MonitorCrushClipCompensation.entries.firstOrNull { it.label == label }?.let(onSelect) }
}

@Composable
private fun ScopeGuideRows(guides: MonitorScopeGuides, onChange: (MonitorScopeGuides) -> Unit) {
    MonitorSettingsSwitchInlineRow("Safe Border Clip", isOn = guides.clip, stacked = true) { onChange(guides.copy(clip = !guides.clip)) }
    MonitorSettingsSwitchInlineRow("Safe Border Crush", isOn = guides.crush, stacked = true) { onChange(guides.copy(crush = !guides.crush)) }
    MonitorSettingsSwitchInlineRow("Middle Gray", isOn = guides.middle, stacked = true) { onChange(guides.copy(middle = !guides.middle)) }
}

// Display: main's rows.

/** Main's Display rows; tagged `monitor.settings.display.*` for the instrumented tests. */
@Composable
fun OperatorDisplayRows(model: OperatorSetupModel, state: OperatorSetupState, app: OperatorSetupApp, isLive: Boolean) {
    val view = LocalView.current
    MonitorSettingsRowCard(title = "Panel") {
        MonitorSettingsSwitchInlineRow(
            title = "HDR display",
            help = app.help.HDR_DISPLAY,
            showTopDivider = false,
            isOn = model.hdrDisplay,
        ) {
            operatorHaptic(view, model.hapticsEnabled)
            model.updateHdrDisplay(!model.hdrDisplay)
        }
    }
    com.opencapture.opencine.appkit.MonitorOperatorDisplaySections(
        live = model.chrome(MonitorDisplayMode.LIVE), clean = model.chrome(MonitorDisplayMode.CLEAN),
        assist = model.assist,
        onChange = { mode, desired ->
            MonitorDisplaySection.entries.forEach { section ->
                if (model.chrome(mode).isVisible(section) != desired.isVisible(section)) {
                    model.toggleChrome(section, mode)
                }
            }
        },
        available = MonitorDisplaySection.entries.filter { section ->
            when (section) {
                MonitorDisplaySection.GIMBAL_STICK -> state.layout.gimbal
                MonitorDisplaySection.ZOOM_CHIP -> state.layout.zoom
                else -> true
            }
        }.toSet(),
        pinnable = MonitorAssistTool.cleanPinCases.filter { it != MonitorAssistTool.AUDIO || state.layout.audio }.toSet(),
        onPinsChanged = { pins ->
            val next = app.prefs.resolvedCleanPins(pins.map { it.name }.toSet())
            model.assist.pinned = next.mapNotNull(MonitorAssistTool::fromPersisted).toSet()
            model.updateCleanViewPinnedTools(next)
        },
        edit = if (!isLive) null else { mode -> model.beginChromeEditing(mode) },
        feedback = { operatorHaptic(view, model.hapticsEnabled) },
    )
}

private fun operatorHaptic(view: View, enabled: Boolean) {
    if (!enabled) return
    view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
}
