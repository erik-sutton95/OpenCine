package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.snapping.SnapPosition
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import com.opencapture.monitorui.MonitorQuickPreview
import com.opencapture.monitorui.monitorScrollFade
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.opencapture.opencine.vocabulary.ApertureStrategy
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureShutterPolicy
import com.opencapture.opencine.vocabulary.ShutterAngle
import com.opencapture.opencine.vocabulary.VideoAspect
import com.opencapture.opencine.vocabulary.VideoResolution
import com.opencapture.opencine.vocabulary.VideoFormat
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.round
import com.opencapture.monitorui.LiveChromeMetrics
import com.opencapture.monitorui.LivePopupPlacement
import com.opencapture.monitorui.MonitorAssistPanelMetrics
import com.opencapture.opencine.appkit.MonitorCapturePreferences
import com.opencapture.opencine.vocabulary.CaptureSessionState
import com.opencapture.opencine.vocabulary.CaptureSetting

@Composable
fun LiveControlSheet(
    sheet: LiveSheet,
    host: CaptureSheetHost,
    status: CameraStatus,
    locked: Boolean,
    onDismiss: () -> Unit,
    maxHeightDp: Float? = null,
    preview: MonitorQuickPreview? = null,
    portrait: Boolean? = null,
    showsHeader: Boolean = true,
    chromeless: Boolean = false,
    onHeaderChanged: (String, String) -> Unit = { _, _ -> },
    /**
     * The host's whole shutter settling window (format pin, pending shutter write, reported rate
     * change; [MonitorOperatorCaptureSource.shutterAngleSettling]). Null: the format pin alone.
     */
    shutterAngleSettling: Boolean? = null,
) {
    val availableStatus = CaptureLists.withEffectiveVideoFormats(
        status, host.camera,
    )
    val isPortrait = portrait ?: viewportIsPortrait()
    CompositionLocalProvider(LocalCapturePreview provides preview, LocalViewportPortrait provides isPortrait) {
        val commandLocked = locked || !com.opencapture.opencine.appkit.LocalMonitorCaptureCommandEnabled.current
        if (sheet.isRecordingSetup && isPortrait && (showsHeader || chromeless)) {
            RecordingSetupPanel(sheet, host, availableStatus, commandLocked, onDismiss, maxHeightDp, chromeless, onHeaderChanged)
        } else {
            LiveControlSheetContent(sheet, host, availableStatus, commandLocked, onDismiss, maxHeightDp,
                showsHeader = showsHeader && !chromeless, chromeless = chromeless, onHeaderChanged = onHeaderChanged,
                shutterAngleSettling = shutterAngleSettling)
        }
    }
}

/** Format, color and shooting mode share one native recording-options panel. */
@Composable
private fun RecordingSetupPanel(
    initial: LiveSheet, host: CaptureSheetHost, status: CameraStatus, locked: Boolean,
    onDismiss: () -> Unit, maxHeightDp: Float?,
    chromeless: Boolean = false, onHeaderChanged: (String, String) -> Unit = { _, _ -> },
) {
    val preview = LocalCapturePreview.current
    val enabled = !locked && preview == null
    val tabNames = CaptureShutterPolicy.recordingCategoryTabs(status.shootingMode)
    var tab by remember(initial, tabNames) {
        mutableStateOf(
            when {
                "Mode" in tabNames && (initial == LiveSheet.MODE || tabNames == listOf("Mode")) -> "Mode"
                initial == LiveSheet.COLOR && "Color" in tabNames -> "Color"
                else -> tabNames.firstOrNull() ?: "Format"
            },
        )
    }
    val categories: @Composable () -> Unit = {
        if (tabNames.size > 1) {
            ModeBar(tabNames, tabNames.indexOf(tab).coerceAtLeast(0), enabled) {
                tab = tabNames[it]
            }
        }
    }
    androidx.compose.runtime.key(tab) {
        if (tab == "Mode" || tabNames == listOf("Mode")) {
            val modeScroll = rememberScrollState()
            Column(Modifier.fillMaxWidth().then(if (maxHeightDp != null) Modifier.heightIn(max = maxHeightDp.dp) else Modifier)
                .then(if (chromeless) Modifier else Modifier.pickerPanelGlass(capturePanelShape(fromTop = true, portrait = viewportIsPortrait()))
                    .monitorScrollFade(modeScroll).verticalScroll(modeScroll, enabled = preview == null).padding(14.dp)),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                androidx.compose.runtime.SideEffect { onHeaderChanged("SHOOTING MODE", "Capture mode") }
                if (!chromeless) SheetHeader("SHOOTING MODE", "Capture mode", onDismiss)
                val bodyName = host.camera?.name
                val labels = CaptureLists.shootingModeLabels(bodyName, status.shootingMode, host.labelProfile)
                CaptureDrumWheel(labels, CameraCommands.shootingModeLabel(status.shootingMode, bodyName, host.labelProfile).orEmpty()
                    .takeIf { it in labels }.orEmpty(),
                    interactive = enabled && !status.isRecording) { label ->
                    host.commit(CaptureSetting.ShootingMode(label), null, status)
                }
                if (tabNames.size > 1 &&
                    com.opencapture.monitorui.MonitorLayoutPolicy.showsRecordingCategoryTabs(viewportIsPortrait(), preview != null)
                ) {
                    categories()
                }
                if (status.isRecording) Text("Stop recording to change mode.", color = LiveDesign.muted, style = LiveType.text(11f))
                if (!chromeless && com.opencapture.monitorui.MonitorLayoutPolicy.showsCaptureGrabber(preview != null, fromTop = true)) {
                    com.opencapture.monitorui.MonitorPanelGrabber()
                }
            }
        } else {
            LiveControlSheetContent(if (tab == "Color") LiveSheet.COLOR else LiveSheet.FORMAT,
                host, status, locked, onDismiss, maxHeightDp, footer = categories,
                showsHeader = !chromeless, chromeless = chromeless, onHeaderChanged = onHeaderChanged)
        }
    }
}

@Composable
private fun LiveControlSheetContent(
    sheet: LiveSheet,
    host: CaptureSheetHost,
    status: CameraStatus,
    locked: Boolean,
    onDismiss: () -> Unit,
    maxHeightDp: Float?,
    footer: (@Composable () -> Unit)? = null,
    showsHeader: Boolean = true,
    chromeless: Boolean = false,
    onHeaderChanged: (String, String) -> Unit = { _, _ -> },
    shutterAngleSettling: Boolean? = null,
) {
    val openedField = remember(sheet, host) { host.captureField(sheet, status.expoMode) }
    // Angle and Speed are two presentations of one shutter descriptor: a mode switch republishes it
    // (an emulated angle editor, or none), so the shutter drum follows the current field (Swift twin
    // `captureCommonField` on a mode change and on the descriptor).
    val commonField = if (sheet == LiveSheet.SHUTTER) host.captureField(sheet, status.expoMode) else openedField
    val session = host.captureSessionState(status)
    val shutterSettling = shutterAngleSettling ?: session.formatPinned
    val prefs = host.capturePreferences
    val preview = LocalCapturePreview.current
    val effects = CapturePanelEffects(preview != null)
    val enabled = !locked && preview == null
    val isEvSheet = CaptureLists.isEvSheet(sheet, status.expoMode)
    val offersIsoAuto = CaptureLists.offersIsoAuto(status)
    var selectedMode by remember(sheet) {
        mutableIntStateOf(initialSelectedMode(sheet, status, session, prefs, isEvSheet))
    }
    var selectedAspect by remember(sheet) {
        mutableStateOf(
            VideoResolution.fromRaw(status.resolutionCode)?.aspect ?: VideoAspect.SIXTEEN_NINE,
        )
    }
    var drumSelection by remember(sheet) { mutableStateOf("") }
    var lastApplied by remember(sheet) { mutableStateOf("") }
    var preferredAngle by remember(sheet) { mutableDoubleStateOf(prefs.shutterAngleDegrees) }
    val isIsoAutoTab = sheet == LiveSheet.ISO && offersIsoAuto && selectedMode == 0
    val isAngleSheet = CaptureLists.isAngleSheet(
        sheet, status.expoMode, selectedMode, status.shootingMode,
    )
    val formatAspects = CaptureLists.formatAspects(status)
    val tabs = if (sheet == LiveSheet.AUDIO) host.audioService?.fields?.map { it.title }.orEmpty()
        else CaptureLists.modeTabs(sheet, status, offersIsoAuto, selectedAspect)
    val bodyFamily = host.camera?.family ?: "pocket"
    val bodyName = host.camera?.name ?: ""

    // The shared drum reports one settled value. Dispatch here, with no second
    // delayed closure that could outlive this source, frame rate, or option set.
    fun commitDrumValue(send: () -> Unit) { if (enabled) send() }

    fun applyIsoSeat(state: IsoSheetLogic.State) {
        selectedMode = state.selectedMode
        lastApplied = state.lastApplied
        drumSelection = state.drumSelection
    }

    fun reseatIso() {
        applyIsoSeat(IsoSheetLogic.reseat(status, bodyName, host.camera?.captureProfile?.isoAutoRangeFloor, session.controlCapabilities.nativeISO.ceiling == true))
    }

    fun applySeat(seat: CaptureLists.ShutterSeat) {
        if (isAngleSheet) preferredAngle = seat.preferredAngle
        lastApplied = seat.selection
        drumSelection = seat.selection
    }

    fun reseatEv() {
        applySeat(CaptureLists.reseatEv(status))
    }

    fun reseatShutterAngle() {
        applySeat(CaptureLists.reseatShutterAngle(status, preferredAngle, shutterSettling))
    }

    fun reseatShutter() {
        applySeat(CaptureLists.reseatShutter(status, selectedMode, isEvSheet, preferredAngle, shutterSettling))
    }

    fun reseatShutterOrEv() {
        if (isEvSheet) reseatEv() else reseatShutter()
    }

    fun reseatWb() {
        drumSelection = CaptureLists.wbDrumSelection(status)
        lastApplied = drumSelection
    }

    fun reseatResolution() {
        if (CameraCommands.isPhotoMode(status.shootingMode)) {
            drumSelection = CaptureLists.PHOTO_FORMAT_READOUT
            lastApplied = drumSelection
            return
        }
        val resolution = VideoResolution.fromRaw(status.resolutionCode)
        selectedAspect = resolution?.aspect ?: CaptureLists.formatAspects(status).firstOrNull() ?: VideoAspect.SIXTEEN_NINE
        val tabs = CaptureLists.formatResolutions(status, selectedAspect)
        selectedMode = tabs.indexOf(resolution).coerceAtLeast(0)
        val label = CaptureLists.fpsDrumLabel(status)
        drumSelection = label
        lastApplied = label
    }

    fun handleAspectChange(aspect: VideoAspect) {
        if (!enabled || aspect == selectedAspect || CameraCommands.isPhotoMode(status.shootingMode)) return
        selectedAspect = aspect
        val sizes = CaptureLists.formatResolutions(status, aspect)
        val match =
            sizes.firstOrNull { it.sizeTitle == VideoResolution.fromRaw(status.resolutionCode)?.sizeTitle }
                ?: sizes.firstOrNull()
                ?: return
        selectedMode = sizes.indexOf(match).coerceAtLeast(0)
        val rates = CaptureLists.formatRates(status, match)
        val currentRate = VideoFormat.current(status)?.frameRate
        val rate = currentRate?.takeIf { it in rates } ?: rates.firstOrNull() ?: return
        drumSelection = rate.drumLabel
        lastApplied = drumSelection
        val next = VideoFormat(match, rate)
        if (next != VideoFormat.current(status)) host.commit(CaptureSetting.Format(next), commonField, status)
    }

    fun reseatColor() {
        val labels = CaptureLists.colorWheelLabels(status, bodyFamily, bodyName, host.labelProfile)
        val live = CameraCommands.colorLabel(status.colorMode, bodyFamily, host.labelProfile)
        val next = if (live in labels) live else labels.firstOrNull().orEmpty()
        drumSelection = next
        lastApplied = next
    }

    fun seed() {
        when (sheet) {
            LiveSheet.ISO -> reseatIso()
            LiveSheet.SHUTTER -> {
                if (!isEvSheet) {
                    selectedMode =
                        if (CameraCommands.isPhotoMode(status.shootingMode) || !prefs.shutterUsesAngle) 0
                        else 1
                }
                reseatShutterOrEv()
            }
            LiveSheet.WB -> {
                selectedMode = CaptureLists.wbInitialTab(status, session.awbLockKelvin != null)
                reseatWb()
            }
            LiveSheet.AUDIO -> selectedMode = CaptureLists.audioInitialTab()
            LiveSheet.FORMAT -> reseatResolution()
            LiveSheet.COLOR -> reseatColor()
            LiveSheet.MODE -> {
                val live = CameraCommands.shootingModeLabel(status.shootingMode, bodyName, host.labelProfile).orEmpty()
                val labels = CaptureLists.shootingModeLabels(bodyName, status.shootingMode, host.labelProfile)
                drumSelection = if (live in labels) live else ""
                lastApplied = drumSelection
            }
            else -> selectedMode = 0
        }
    }

    fun applyVideoFormat(tab: Int, drum: String, fromDrum: Boolean) {
        if (!CaptureLists.formatPickerEditable(status)) return
        val next = CaptureLists.nextVideoFormat(status, tab, drum, fromDrum, selectedAspect) ?: return
        host.commit(CaptureSetting.Format(next), commonField, status)
    }

    fun handleModeChange(index: Int) {
        if (!enabled) return
        when {
            sheet == LiveSheet.ISO && offersIsoAuto -> {
                val (state, cmd) = IsoSheetLogic.handleModeChange(index, status, bodyName, host.camera?.captureProfile?.isoAutoRangeFloor, session.controlCapabilities.nativeISO.ceiling == true)
                applyIsoSeat(state)
                when (cmd) {
                    is IsoSheetLogic.Command.SetIndex -> host.commit(CaptureSetting.IsoIndex(cmd.index), commonField, status)
                    is IsoSheetLogic.Command.SetLimit -> host.commit(CaptureSetting.IsoLimitRaw(cmd.raw), commonField, status)
                    null -> Unit
                }
            }
            sheet == LiveSheet.SHUTTER && !isEvSheet -> {
                host.updateCapturePreferences(prefs.copy(shutterUsesAngle = index == 1))
                // Tab change reseats after selectedMode is written by the caller.
            }
            sheet == LiveSheet.WB -> Unit
            sheet == LiveSheet.FORMAT -> applyVideoFormat(index, drumSelection, fromDrum = false)
        }
    }

    fun applyDrum(value: String) {
        if (!enabled || value.isEmpty() || value == lastApplied) return
        if (sheet == LiveSheet.COLOR && status.isRecording) {
            CaptureLists.applyColorDrum(
                label = value,
                family = bodyFamily,
                status = status,
                hopEnabled = prefs.nativeIsoHop,
                name = bodyName,
                profile = host.labelProfile,
            )?.let { host.commit(CaptureSetting.ColorMode(it.colorMode), commonField, status) }
            return
        }
        lastApplied = value
        when (sheet) {
            LiveSheet.ISO -> {
                when (val cmd = IsoSheetLogic.applyDrum(value, status, selectedMode, bodyName, host.camera?.captureProfile?.isoAutoRangeFloor, session.controlCapabilities.nativeISO.ceiling == true)) {
                    is IsoSheetLogic.Command.SetLimit ->
                        commitDrumValue { host.commit(CaptureSetting.IsoLimitRaw(cmd.raw), commonField, status) }
                    is IsoSheetLogic.Command.SetIndex ->
                        commitDrumValue { host.commit(CaptureSetting.IsoIndex(cmd.index), commonField, status) }
                    null -> return
                }
            }
            LiveSheet.SHUTTER -> {
                when (
                    val cmd =
                        CaptureLists.applyShutterDrum(
                            value = value,
                            isEvSheet = isEvSheet,
                            isAngleSheet = isAngleSheet,
                            facePriority = prefs.facePriorityExposure,
                            status = status,
                        )
                ) {
                    is CaptureLists.ShutterDrumCommand.SetEv ->
                        commitDrumValue { host.commit(CaptureSetting.Ev(cmd.thirds), commonField, status) }
                    is CaptureLists.ShutterDrumCommand.SetShutter ->
                        commitDrumValue { host.commit(CaptureSetting.ShutterDenom(cmd.denom), commonField, status) }
                    is CaptureLists.ShutterDrumCommand.SetAngle -> {
                        commitDrumValue {
                            preferredAngle = cmd.degrees
                            host.commit(CaptureSetting.ShutterAngle(cmd.degrees), commonField, status)
                        }
                    }
                    CaptureLists.ShutterDrumCommand.Ignored -> Unit
                }
            }
            LiveSheet.WB -> {
                val custom = CaptureLists.wbKelvinDrumApply(selectedMode, value, status) ?: return
                host.commit(CaptureSetting.WhiteBalance(custom.first, custom.second), commonField, status)
            }
            LiveSheet.FORMAT -> {
                commitDrumValue { applyVideoFormat(selectedMode, value, fromDrum = true) }
            }
            LiveSheet.COLOR -> {
                val command =
                    CaptureLists.applyColorDrum(
                        label = value,
                        family = bodyFamily,
                        status = status,
                        hopEnabled = prefs.nativeIsoHop,
                        name = bodyName,
                        profile = host.labelProfile,
                    ) ?: return
                // Session.setColorMode hops native ISO, as iOS CameraSession does.
                commitDrumValue { host.commit(CaptureSetting.ColorMode(command.colorMode), commonField, status) }
            }
            LiveSheet.MODE -> {
                commitDrumValue {
                    host.commit(CaptureSetting.ShootingMode(value), commonField, status)
                }
            }
            else -> Unit
        }
    }

    // Read-only preview mounts cannot seed preferences or issue any camera GET.
    // Effects also guard reseating so a future caller cannot accidentally persist an angle.
    if (preview == null) {
        LaunchedEffect(sheet) {
            effects.mount(sheet, status, session.controlCapabilities.focus.isOffered, host::refresh, ::seed, ::reseatIso,
                ceilingSupported = session.controlCapabilities.nativeISO.ceiling == true)
        }
        // Match iOS CaptureControlSheets onChange keys. Do not reseat ISO/shutter drums
        // on every live isoIndex / shutterDenom tick: that snaps Manual back to Auto
        // and parks the wheel on the first option.
        LaunchedEffect(sheet, status.availableIsoIndices, status.colorMode) {
            if (sheet == LiveSheet.ISO) reseatIso()
        }
        LaunchedEffect(sheet, status.availableShutterDenoms, status.fps) {
            if (sheet == LiveSheet.SHUTTER && !isEvSheet) reseatShutter()
        }
        // The end of a hold reseats the angle drum on what the camera really makes (Swift twin).
        LaunchedEffect(sheet, shutterSettling) {
            if (sheet == LiveSheet.SHUTTER && !isEvSheet && isAngleSheet) reseatShutter()
        }
        LaunchedEffect(sheet, status.expoMode) {
            if (sheet == LiveSheet.SHUTTER) {
                CaptureLists.shutterTabAfterExpoChange(
                    status.expoMode, prefs.shutterUsesAngle, status.shootingMode,
                )?.let {
                    selectedMode = it
                }
                reseatShutterOrEv()
            }
        }
        LaunchedEffect(sheet, status.evComp, prefs.facePriorityExposure) {
            if (sheet == LiveSheet.SHUTTER && isEvSheet) reseatEv()
        }
        LaunchedEffect(
            sheet, status.shootingMode, status.resolutionCode, status.fpsIndex,
            status.availableVideoFormats,
        ) {
            if (sheet == LiveSheet.FORMAT && !session.formatPinned) reseatResolution()
        }
        LaunchedEffect(sheet, status.shootingMode) {
            if (sheet == LiveSheet.SHUTTER && CameraCommands.isPhotoMode(status.shootingMode) && !isEvSheet) {
                selectedMode = 0
                reseatShutter()
            }
        }
        LaunchedEffect(sheet, status.colorMode) {
            if (sheet == LiveSheet.COLOR) reseatColor()
        }
    }

    val cap = maxHeightDp?.dp
    val compact = preview != null
    val fromTop = sheet.isTopAnchored
    val portrait = viewportIsPortrait()
    val topPadding = if (showsHeader) com.opencapture.monitorui.MonitorLayoutPolicy.captureTopPadding(fromTop, portrait, compact) else 0f
    val headerTitle = CaptureLists.headerTitle(sheet, status.expoMode, status.shootingMode)
    val headerSubtitle = if (compact) "drag to set" else CaptureLists.headerSubtitle(sheet, status.expoMode,
        selectedMode, prefs.facePriorityExposure, status.shootingMode)
    androidx.compose.runtime.SideEffect { onHeaderChanged(headerTitle, headerSubtitle) }
    // Every drum has the same 86dp viewport; the card hugs its own controls.
    val sheetScroll = rememberScrollState()
    Column(
        Modifier
            .fillMaxWidth()
            .then(Modifier.wrapContentHeight(align = Alignment.Top))
            .then(if (cap != null) Modifier.heightIn(max = cap) else Modifier)
            .then(if (chromeless) Modifier else Modifier.pickerPanelGlass(capturePanelShape(fromTop, portrait))
                .monitorScrollFade(sheetScroll).verticalScroll(sheetScroll, enabled = preview == null))
            .pointerInput(Unit) { detectTapGestures(onTap = {}) }
            .padding(horizontal = if (chromeless) 0.dp else 14.dp)
            .padding(
                top = topPadding.dp,
                bottom = when {
                    chromeless -> 0.dp
                    compact -> com.opencapture.monitorui.MonitorLayoutPolicy.compactCaptureBottomPadding(
                        topPadding).dp
                    fromTop -> 14.dp
                    else -> 11.dp
                },
            ),
        verticalArrangement = Arrangement.spacedBy(MonitorAssistPanelMetrics.PANEL_GAP_DP.dp),
    ) {
            if (showsHeader) SheetHeader(
                title = if (sheet == LiveSheet.COLOR) host.recordingCodecColor(status).title
                    else CaptureLists.headerTitle(sheet, status.expoMode, status.shootingMode),
                subtitle =
                    if (compact) "drag to set"
                    else
                        CaptureLists.headerSubtitle(
                            sheet,
                            status.expoMode,
                            selectedMode,
                            prefs.facePriorityExposure,
                            status.shootingMode,
                        ),
                onClose = onDismiss,
                showsClose = !compact,
            )
            // Composed once: a host panel keeps one slot group per recomposition.
            val nativePanel = host.nativeCapturePanel(sheet, enabled)
            if (preview != null) {
                CaptureDrumWheel(
                    options = preview.control.options,
                    selection = preview.selection,
                    markedValues = preview.control.marked,
                    interactive = false,
                    onSelect = {},
                )
            } else if (nativePanel != null && sheet != LiveSheet.COLOR) {
                nativePanel()
            } else when (sheet) {
                LiveSheet.ISO -> {
                    Column(
                        Modifier.wrapContentHeight(),
                        verticalArrangement = Arrangement.spacedBy(MonitorAssistPanelMetrics.PANEL_GAP_DP.dp),
                    ) {
                        Box(Modifier.fillMaxWidth()) {
                            if (isIsoAutoTab) {
                                CaptureDrumWheel(
                                    options = IsoSheetLogic.autoLabels(status, bodyName, host.camera?.captureProfile?.isoAutoRangeFloor, session.controlCapabilities.nativeISO.ceiling == true),
                                    selection = drumSelection,
                                    interactive = enabled,

                                    onSelect = {
                                        drumSelection = it
                                        applyDrum(it)
                                    },
                                )
                            } else {
                                host.CommonDrum(sheet, status, commonField, enabled, CaptureWheelState(drumSelection) { drumSelection = it; applyDrum(it) })
                            }
                        }
                        if (session.controlCapabilities.nativeISO.hop == true) PrefToggle(
                            title = CaptureLists.NATIVE_ISO_HOP_TITLE,
                            help = CaptureLists.NATIVE_ISO_HOP_HELP,
                            checked = prefs.nativeIsoHop,
                            enabled = enabled,
                            onCheckedChange = { host.updateCapturePreferences(prefs.copy(nativeIsoHop = it)) },
                        )
                    }
                }
                LiveSheet.SHUTTER -> {
                    Column(
                        Modifier.wrapContentHeight(),
                        verticalArrangement = Arrangement.spacedBy(MonitorAssistPanelMetrics.PANEL_GAP_DP.dp),
                    ) {
                        Box(Modifier.fillMaxWidth()) {
                            if (isEvSheet) {
                                host.CommonDrum(sheet, status, commonField, enabled, CaptureWheelState(drumSelection) { drumSelection = it; applyDrum(it) })
                            } else if (isAngleSheet) {
                                CaptureDrumWheel(
                                    options = ShutterAngle.labels,
                                    selection = drumSelection,
                                    interactive = enabled,

                                    onSelect = {
                                        drumSelection = it
                                        applyDrum(it)
                                    },
                                )
                            } else {
                                host.CommonDrum(sheet, status, commonField, enabled, CaptureWheelState(drumSelection) { drumSelection = it; applyDrum(it) })
                            }
                        }
                        if (isEvSheet) {
                            PrefToggle(
                                title = CaptureLists.FACE_PRIORITY_TITLE,
                                help = CaptureLists.FACE_PRIORITY_HELP,
                                checked = prefs.facePriorityExposure,
                                enabled = enabled,
                                onCheckedChange = { host.updateCapturePreferences(prefs.copy(facePriorityExposure = it)) },
                            )
                        }
                    }
                }
                LiveSheet.WB -> {
                    when (selectedMode) {
                        0 -> {
                            val awbLocked = session.awbLockKelvin != null
                            CheckedRows(
                                options = CaptureLists.wbModeRows(awbLocked || session.awbLockOffered),
                                selected = CaptureLists.wbModeRowSelected(status, awbLocked),
                                enabled = enabled,
                            ) { label ->
                                if (label == CaptureLists.AWB_LOCK) {
                                    host.commit(CaptureSetting.AutoWhiteBalanceLock, commonField, status)
                                } else if (CaptureLists.wbSendsAuto(label)) {
                                    host.commit(CaptureSetting.WhiteBalanceAuto, commonField, status)
                                } else {
                                    val custom = CaptureLists.wbCustomFromStatus(status)
                                    host.commit(CaptureSetting.WhiteBalance(custom.first, custom.second), commonField, status)
                                }
                            }
                        }
                        1 ->
                            Box(Modifier.wrapContentHeight().fillMaxWidth()) {
                                host.CommonDrum(sheet, status, commonField, enabled, CaptureWheelState(drumSelection) { drumSelection = it; applyDrum(it) })
                            }
                        else -> {
                            CaptureDrumWheel(
                                options = (-100..100).map(CaptureLists::tintLabel),
                                selection = CaptureLists.tintLabel(CaptureLists.currentTint(status)),
                                interactive = enabled,
                            ) { label ->
                                val value = label.replace('−', '-').removePrefix("+").toIntOrNull()
                                    ?: return@CaptureDrumWheel
                                val kelvin = if (CaptureLists.wbTintStaysAuto(status)) null else CaptureLists.currentKelvin(status)
                                host.commit(CaptureSetting.WhiteBalanceTint(value, kelvin), commonField, status)
                            }
                        }
                    }
                }
                LiveSheet.FOCUS -> {
                    if (session.controlCapabilities.focus.isOffered) {
                        FocusBody(
                            status = status,
                            labels = host.labelProfile.focusLabels,
                            enabled = enabled,
                            onSelect = { label -> host.commit(CaptureSetting.Focus(label), commonField, status) },
                        )
                    }
                }
                LiveSheet.APERTURE -> {
                    if (session.controlCapabilities.iris.isOffered) {
                        CheckedRows(
                            options = CaptureLists.apertureLabels(status),
                            selected = ApertureStrategy.label(status.apertureStrategy),
                            enabled = enabled,
                        ) { label ->
                            CaptureLists.apertureFromLabel(label)?.let { host.commit(CaptureSetting.Aperture(it), commonField, status) }
                        }
                    }
                }
                LiveSheet.EXPO -> {
                    val aeLocked = session.aeLocked
                    CheckedRows(
                        options = CaptureLists.expoLabels(aeLocked),
                        selected = CaptureLists.expoSelectedLabel(status.expoMode, aeLocked),
                        enabled = enabled,
                    ) { label ->
                        CaptureLists.expoModeFromLabel(label)?.let { host.commit(CaptureSetting.ExpoMode(it), commonField, status) }
                    }
                }
                LiveSheet.AUDIO -> AudioBody(status, enabled, selectedMode, host)
                LiveSheet.COLOR ->
                    // One popup for codec and colour: the codec choices the camera offers, then
                    // its colour choices. The colour drum keeps each camera's existing behaviour.
                    CaptureCodecColorPanel(
                        choices = host.recordingCodecColor(status),
                        enabled = enabled && !status.isRecording,
                        onSelectCodec = { id -> if (enabled && !status.isRecording) host.commitRecordingCodec(id) },
                    ) {
                        if (nativePanel != null) nativePanel() else CaptureDrumWheel(
                            options = CaptureLists.colorWheelLabels(status, bodyFamily, bodyName, host.labelProfile),
                            selection = drumSelection,
                            interactive = enabled,

                            onSelect = {
                                drumSelection = it
                                applyDrum(it)
                            },
                        )
                    }
                LiveSheet.FORMAT -> {
                    if (CameraCommands.isPhotoMode(status.shootingMode)) {
                        CaptureDrumWheel(listOf(CaptureLists.PHOTO_FORMAT_READOUT), drumSelection, interactive = false, onSelect = {})
                    } else {
                        val formats = CaptureLists.effectiveVideoFormats(status, host.camera)
                        CaptureFormatPicker(
                            choices = CaptureVideoFormatChoices.make(formats, VideoFormat.current(status)),
                            current = VideoFormat.current(status),
                            enabled = enabled && formats.isNotEmpty(), sourceIdentity = commonField ?: host,
                            followsReadback = !session.formatPinned,
                            isCurrent = { enabled },
                        ) { choice ->
                            if (enabled && choice.value in formats && choice.value != VideoFormat.current(status)) {
                                host.commit(CaptureSetting.Format(choice.value), commonField, status)
                            }
                        }
                    }
                }
                LiveSheet.MODE -> {
                    val labels = CaptureLists.shootingModeLabels(bodyName, status.shootingMode, host.labelProfile)
                    CaptureDrumWheel(
                        options = labels,
                        selection = CameraCommands.shootingModeLabel(status.shootingMode, bodyName, host.labelProfile).orEmpty()
                            .takeIf { it in labels }.orEmpty(),
                        interactive = enabled && !status.isRecording,
                        onSelect = {
                            drumSelection = it
                            applyDrum(it)
                        },
                    )
                    if (status.isRecording) Text("Stop recording to change mode.",
                        color = LiveDesign.muted, style = LiveType.text(11f))
                }
            }
            if (!compact) {
                if (sheet != LiveSheet.FORMAT && tabs.isNotEmpty()) {
                    ModeBar(
                        tabs = tabs,
                        selected = selectedMode,
                        enabled = enabled &&
                            (sheet != LiveSheet.FORMAT || CaptureLists.formatPickerEditable(status)),
                    ) { index ->
                        selectedMode = index
                        handleModeChange(index)
                        if (sheet == LiveSheet.SHUTTER && !isEvSheet) reseatShutter()
                    }
                }
                if (com.opencapture.monitorui.MonitorLayoutPolicy.showsRecordingCategoryTabs(portrait, compact)) {
                    footer?.invoke()
                }
                if (!chromeless && com.opencapture.monitorui.MonitorLayoutPolicy.showsCaptureGrabber(compact, fromTop)) {
                    com.opencapture.monitorui.MonitorPanelGrabber()
                }
            }
    }
}

/**
 * Camera values sit on the bottom-center well; recording categories hang from
 * the top edge. Outside taps dismiss the persistent drawer.
 */
@Composable
fun LivePickerHost(
    sheet: LiveSheet,
    viewportWidth: Float,
    viewportHeight: Float,
    safeLeading: Float,
    safeTrailing: Float,
    safeTop: Float,
    safeBottom: Float,
    floorY: Float?,
    host: CaptureSheetHost,
    status: CameraStatus,
    locked: Boolean,
    onSelect: (LiveSheet?) -> Unit,
    ceilingY: Float? = null,
) {
    val density = LocalDensity.current
    var panelHeight by remember(sheet) { mutableFloatStateOf(LiveChromeMetrics.DRUM_PICKER_HEIGHT) }
    val fromTop = sheet.isTopAnchored
    val portrait = viewportHeight > viewportWidth
    val place = if (fromTop) {
        LivePopupPlacement.topCapturePanel(panelHeight, viewportWidth, viewportHeight,
            safeLeading, safeTrailing, safeTop, safeBottom, ceilingY, floorY)
    } else {
        LivePopupPlacement.bottomCapturePanel(panelHeight, viewportWidth, viewportHeight,
            safeLeading, safeTrailing, safeTop, safeBottom, floorY)
    }
    Box(
        Modifier
            .fillMaxWidth()
            .fillMaxHeight(),
    ) {
        com.opencapture.monitorui.MonitorReadoutDismissBackdrop(onDismiss = { onSelect(null) })
        androidx.compose.runtime.key(sheet) {
            com.opencapture.monitorui.MonitorCaptureReveal(
                Modifier
                    .offset(place.x.dp, place.y.dp)
                    .width(place.width.dp)
                    .heightIn(max = place.maxHeight.dp)
                    .onSizeChanged { panelHeight = it.height / density.density },
                fromTop = fromTop,
            ) {
                androidx.compose.runtime.key(sheet) {
                    LiveControlSheet(
                        sheet,
                        host,
                        status,
                        locked,
                        onDismiss = { onSelect(null) },
                        maxHeightDp = place.maxHeight,
                        portrait = portrait,
                    )
                }
            }
        }
    }
}

@Composable
private fun AudioBody(status: CameraStatus, enabled: Boolean, selectedMode: Int, host: CaptureSheetHost) {
    val service = host.audioService
    val sourceID = remember(host) { service?.sourceID }
    var refusal by remember(host) { mutableStateOf<String?>(null) }
    val field = service?.fields?.getOrNull(selectedMode)
    if (field == null) Text("Audio controls unavailable", color = LiveDesign.faint)
    else CheckedRows(field.choices.map { it.label }, field.observed?.label,
        enabled && field.isEditable && service?.sourceID == sourceID) { label ->
        val current = host.audioService
        val currentField = current?.fields?.firstOrNull { it.id == field.id }
        val value = currentField?.choices?.firstOrNull { it.label == label }
        refusal = if (current == null || current.sourceID != sourceID || currentField?.isEditable != true || value == null)
            "Audio control unavailable"
        else when (current.commit(value)) {
            CaptureAudioCommitResult.SUBMITTED -> null
            CaptureAudioCommitResult.UNAVAILABLE -> "Audio control unavailable"
            CaptureAudioCommitResult.REFUSED -> "Audio control refused"
        }
    }
    refusal?.let { Text(it, color = LiveDesign.faint) }
}

internal fun initialSelectedMode(
    sheet: LiveSheet,
    status: CameraStatus,
    session: CaptureSessionState,
    prefs: MonitorCapturePreferences,
    isEvSheet: Boolean,
): Int =
    when (sheet) {
        LiveSheet.ISO ->
            if (CaptureLists.offersIsoAuto(status) && status.isoIndex != 0) 1 else 0
        LiveSheet.SHUTTER ->
            if (!isEvSheet && prefs.shutterUsesAngle && !CameraCommands.isPhotoMode(status.shootingMode)) 1
            else 0
        LiveSheet.WB -> CaptureLists.wbInitialTab(status, session.awbLockKelvin != null)
        LiveSheet.FORMAT -> {
            val resolution = VideoResolution.fromRaw(status.resolutionCode)
            CaptureLists.formatResolutions(status).indexOf(resolution).coerceAtLeast(0)
        }
        else -> 0
    }
