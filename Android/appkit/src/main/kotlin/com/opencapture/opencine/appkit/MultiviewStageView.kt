package com.opencapture.opencine.appkit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.monitorui.MonitorAssistIcon
import com.opencapture.monitorui.MonitorAssistPalette
import com.opencapture.monitorui.MonitorAuxCircleButton
import com.opencapture.monitorui.MonitorBatteryOutlineRow
import com.opencapture.monitorui.MonitorGaugeBars
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorLayoutPolicy
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorRecordLamp
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.MultiviewArrangement
import com.opencapture.monitorui.MultiviewPresentationLayout
import com.opencapture.monitorui.MultiviewTileCanvas
import com.opencapture.monitorui.monitorChromeClickable
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.monitorui.monitorScrollFade
import com.opencapture.opencine.multicam.RecordPlan
import kotlinx.coroutines.delay

// Swift twin: Sources/OpenCineAppKit/MultiviewStageView.swift. Same types; each platform keeps
// its shipping look (Compose: per-tile drop-down options and a status card with buttons).

/** What the stage asks of the app. Every camera action is the app's. */
public class MultiviewStageActions(
    /** Selects a slot (tap). */
    public val select: (Int) -> Unit,
    /** The LAYOUT tool. */
    public val arrange: (MultiviewArrangement) -> Unit,
    /** The FIT tool: fill (true) or fit. */
    public val setFill: (Boolean) -> Unit,
    /** Double tap or the Live View option. The app checks the camera can open. */
    public val openLiveView: (Int) -> Unit,
    /** Add camera on an empty slot. */
    public val add: (Int) -> Unit,
    /** A [MultiviewCameraAction] other than record, by id, for a slot. */
    public val perform: (action: String, slot: Int) -> Unit,
    /** The close button. */
    public val close: () -> Unit,
    /** The record plan now: every camera (null) or one slot. */
    public val recordContext: (slot: Int?) -> MultiviewRecordContext,
    /**
     * Runs an approved plan. The app launches it in a scope that outlives the stage: Live View
     * can replace the stage while a group command is in flight.
     */
    public val record: (plan: RecordPlan, slot: Int?) -> Unit,
    /** A readout choice: slot, readout index and the choice the operator picked, as shown. */
    public val choose: (slot: Int, readout: Int, choice: String) -> Unit = { _, _, _ -> },
    /** The LUT tool. */
    public val toggleLut: () -> Unit = {},
    /** The CAMERA tool: the app shows its settings panel for the slot over the stage. */
    public val openSettings: (Int) -> Unit = {},
    /** The options closed. */
    public val popupsClosed: () -> Unit = {},
    /** Tap feedback (the app's selection haptic). */
    public val feedback: () -> Unit = {},
)

/** A chrome button the app adds at the stage's network slot (top, beside close). */
public class MultiviewStageButton(
    public val title: String,
    public val icon: MonitorIcon,
    public val enabled: Boolean = true,
    public val identifier: String,
    public val action: () -> Unit,
)

private val TileShape = RoundedCornerShape(12.dp)
private val ControlShape = RoundedCornerShape(14.dp)
private val GlassBright = Color(94 / 255f, 98 / 255f, 98 / 255f, 0.18f)
private val Good = Color(0.18f, 0.78f, 0.42f)
private val Amber = Color(0.914f, 0.674f, 0.208f)

private fun Modifier.at(rect: MonitorRect): Modifier =
    offset(rect.x.dp, rect.y.dp).requiredSize(rect.width.dp, rect.height.dp)

@Composable
private fun Modifier.glass(shape: androidx.compose.ui.graphics.Shape = TileShape): Modifier =
    monitorMaterial(MonitorMaterial.Compact, shape)

/**
 * The shared Multiview stage: slots laid out by [MultiviewPresentationLayout] (Grid or Center
 * stage), each with its picture, identity chrome and options, plus close, the app's network
 * button, the assist tools, the program readouts, DISP and record on all cameras. Values and
 * actions only; the app owns sessions, sheets, its settings panel and the camera picker.
 *
 * @param tiles one per slot, null while the slot is empty.
 * @param readouts the program camera's values under Center stage, null to hide them.
 * @param busy the app is changing membership or the network: no close or add.
 * @param groupBusy a group record runs.
 * @param closing the stage is closing: tools lock and no record starts.
 * @param interactive false while an app overlay covers the stage.
 */
@Composable
public fun MultiviewStage(
    tiles: List<MultiviewTile?>,
    layout: MultiviewPresentationLayout,
    arrangement: MultiviewArrangement,
    selected: Int,
    fill: Boolean,
    tools: List<MultiviewTool>,
    readouts: List<MultiviewReadout>?,
    recording: Boolean,
    groupBusy: Boolean,
    confirmsRecord: Boolean,
    actions: MultiviewStageActions,
    modifier: Modifier = Modifier,
    lut: Boolean = false,
    busy: Boolean = false,
    closing: Boolean = false,
    interactive: Boolean = true,
    network: MultiviewStageButton? = null,
    picture: @Composable (slot: Int) -> Unit,
) {
    val fallback = remember(tiles.size) { MultiviewStageState(maxOf(1, tiles.size)) }
    val presentation = LocalMultiviewStageState.current ?: fallback
    val clean = presentation.clean
    val stageInteractive = interactive && LocalMultiviewStageVisible.current
    LaunchedEffect(stageInteractive) { if (!stageInteractive) actions.popupsClosed() }
    Box(
        // Hidden from TalkBack while an app overlay covers it.
        modifier.fillMaxSize().then(if (stageInteractive) Modifier else Modifier.clearAndSetSemantics { }),
    ) {
        MultiviewTileCanvas(tiles.indices.map { it.toString() }, layout) { index, compact ->
            val overlay = layout.readoutsOverlay && index == selected
            TileView(
                tiles, index, compact, clean, stageInteractive, selected, arrangement, busy, groupBusy, confirmsRecord,
                actions,
                // The View Assist palette floats over the main tile's lower left; its footer
                // starts where the stage value row does.
                footerStart = if (overlay) layout.readouts.x - layout.tiles[index].x else 0f,
                // Grid's selected tile carries its values between the footer columns.
                inlineValues = overlay && arrangement == MultiviewArrangement.GRID,
                picture = picture,
            )
        }
        if (!clean) {
            ChromeButton(
                MonitorIcon.X, "Exit Multiview", Modifier.at(layout.sessionControls),
                enabled = !busy && !groupBusy, feedback = actions.feedback, onClick = actions.close,
            )
            if (arrangement == MultiviewArrangement.CENTER_STAGE && readouts != null) {
                ProgramReadouts(readouts, selected, actions, Modifier.at(layout.readouts))
            }
            AssistPalette(
                tools, tiles, arrangement, fill, lut, closing, selected, actions, layout.controlCellSize,
                Modifier.at(layout.assists), horizontal = layout.assistsHorizontal,
                fixed = layout.portrait && arrangement == MultiviewArrangement.CENTER_STAGE,
                presentation = presentation,
                maxExpandedHeight = if (layout.assistsHorizontal) null else layout.assists.height,
            )
            network?.let { NetworkButton(it, Modifier.at(layout.network), actions.feedback) }
        }
        DisplayButton(clean, Modifier.at(layout.display), actions.feedback) { presentation.clean = !clean }
        RecordAllButton(recording, groupBusy, confirmsRecord, layout.record.width, Modifier.at(layout.record), actions)
    }
}

@Composable
private fun ChromeButton(
    icon: MonitorIcon, label: String, modifier: Modifier, enabled: Boolean, feedback: () -> Unit,
    onClick: () -> Unit,
) {
    Box(
        modifier.alpha(if (enabled) 1f else 0.4f)
            .glass(ControlShape)
            .monitorChromeClickable(enabled = enabled, onClickFeedback = feedback, onClick = onClick)
            .semantics { contentDescription = label; role = Role.Button },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(icon, null, Modifier.fillMaxSize(26f / 54f), MonitorPalette.text.copy(alpha = 0.86f))
    }
}

@Composable
private fun NetworkButton(button: MultiviewStageButton, modifier: Modifier, feedback: () -> Unit) {
    val configuration = LocalConfiguration.current
    val tablet = minOf(configuration.screenWidthDp, configuration.screenHeightDp) >= 600
    val side = MonitorLayoutPolicy.systemButtonSize(tablet)
    MonitorAuxCircleButton(
        modifier.semantics { contentDescription = button.title }.testTag(button.identifier)
            .size(side.dp).alpha(if (button.enabled) 1f else 0.4f)
            .glass(ControlShape)
            .monitorChromeClickable(enabled = button.enabled, onClickFeedback = feedback, onClick = button.action)
            .semantics { role = Role.Button },
    ) { tint -> MonitorIcon(button.icon, null, Modifier.fillMaxSize(), tint) }
}

@Composable
private fun ProgramReadouts(
    readouts: List<MultiviewReadout>, slot: Int, actions: MultiviewStageActions, modifier: Modifier,
) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Row(
            Modifier.widthIn(max = 300.dp).fillMaxWidth().testTag("multiview.readouts"),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            readouts.forEachIndexed { index, readout ->
                ReadoutValue(readout, slot, index, actions, Modifier.weight(1f), 12f, 7f)
            }
        }
    }
}

/** A value; one with the camera's advertised choices opens them, and a pick calls `choose`. */
@Composable
private fun ReadoutValue(
    readout: MultiviewReadout, slot: Int, index: Int, actions: MultiviewStageActions, modifier: Modifier,
    valueSize: Float, titleSize: Float,
) {
    var open by remember { mutableStateOf(false) }
    val visible = LocalMultiviewStageVisible.current
    LaunchedEffect(visible) { if (!visible) open = false }
    Column(
        modifier.then(
            if (readout.choices.isEmpty()) Modifier else Modifier
                .monitorChromeClickable(onClickFeedback = actions.feedback) { open = true }
                .testTag("multiview.value.${readout.title.lowercase()}"),
        ),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(readout.value, color = MonitorPalette.text,
            style = MonitorTypography.readout(valueSize, FontWeight.SemiBold), maxLines = 1)
        Text(readout.title, color = MonitorPalette.muted,
            style = MonitorTypography.text(titleSize, FontWeight.SemiBold), maxLines = 1)
        DropdownMenu(expanded = open && LocalMultiviewStageVisible.current, onDismissRequest = { open = false }) {
            readout.choices.forEach { name ->
                DropdownMenuItem(text = { Text(name) }, onClick = {
                    open = false
                    actions.choose(slot, index, name)
                })
            }
        }
    }
}

@Composable
private fun AssistPalette(
    tools: List<MultiviewTool>, tiles: List<MultiviewTile?>, arrangement: MultiviewArrangement, fill: Boolean,
    lut: Boolean, closing: Boolean, selected: Int, actions: MultiviewStageActions, cell: Float, modifier: Modifier,
    horizontal: Boolean, fixed: Boolean, maxExpandedHeight: Float?, presentation: MultiviewStageState,
) {
    val services = LocalMultiviewStageServices.current
    val occupied = tiles.indices.filter { tiles[it] != null }.toSet()
    val offered = services?.availability?.offeredTools(tools, occupied) ?: tools
    val cameras = occupied.isNotEmpty()
    val grid = arrangement == MultiviewArrangement.GRID
    val nowClosing by rememberUpdatedState(closing)
    val expansion = remember(presentation) {
        object : androidx.compose.runtime.MutableState<Boolean> {
            override var value: Boolean
                // A temporary close lock collapses the surface, not the operator's saved preference.
                get() = !nowClosing && presentation.toolsExpanded
                set(value) { if (!nowClosing) presentation.toolsExpanded = value }
            override fun component1(): Boolean = value
            override fun component2(): (Boolean) -> Unit = { value = it }
        }
    }
    fun title(tool: MultiviewTool) = when (tool) {
        MultiviewTool.LUT -> if (services?.automaticLUT == false) "Toggle LUT for all cameras" else "Toggle Auto LUT for all cameras"
        MultiviewTool.FIT -> if (fill) "Fit feed in frame" else "Fill frame with feed"
        MultiviewTool.LAYOUT -> if (grid) "Show Focused stage" else "Show Grid"
        MultiviewTool.CAMERA -> "Camera settings"
    }
    fun isOn(tool: MultiviewTool) = tool == MultiviewTool.LUT && lut
    fun isAvailable(tool: MultiviewTool) = (tool != MultiviewTool.LUT && tool != MultiviewTool.CAMERA) || cameras
    fun identifier(tool: MultiviewTool) = when (tool) {
        MultiviewTool.LUT -> "multiview.lut"
        MultiviewTool.FIT -> "multiview.fitFill"
        MultiviewTool.LAYOUT -> "multiview.layout"
        MultiviewTool.CAMERA -> "multiview.settings"
    }
    fun configure(tool: MultiviewTool) {
        if (tool != MultiviewTool.LUT) return
        val slot = services?.availability?.pictureLUTSlot(selected, occupied) ?: return
        services.configureLUT?.invoke(slot)
    }
    fun toggle(tool: MultiviewTool) {
        actions.feedback()
        when (tool) {
            MultiviewTool.LUT -> {
                if (services != null && services.availability.pictureLUTSlot(selected, occupied) == null) return
                actions.toggleLut()
            }
            MultiviewTool.FIT -> actions.setFill(!fill)
            MultiviewTool.LAYOUT ->
                actions.arrange(if (grid) MultiviewArrangement.CENTER_STAGE else MultiviewArrangement.GRID)
            MultiviewTool.CAMERA -> {
                val slot = if (services != null) services.availability.cameraSettingsSlot(selected, occupied)
                    else selected.takeIf { it in occupied } ?: occupied.minOrNull()
                if (slot != null) actions.openSettings(slot)
            }
        }
    }
    val glyph: @Composable (MultiviewTool, Color, Modifier) -> Unit = { tool, tint, iconModifier ->
        val icon = when (tool) {
            MultiviewTool.LUT -> null
            MultiviewTool.FIT -> if (fill) MonitorIcon.MINIMIZE else MonitorIcon.MAXIMIZE
            MultiviewTool.LAYOUT -> if (grid) MonitorIcon.LAYOUT_LIST else MonitorIcon.LAYOUT_GRID
            MultiviewTool.CAMERA -> MonitorIcon.SLIDERS_HORIZONTAL
        }
        // LUT wears the View Assist LUT glyph, as on iOS.
        if (icon == null) MonitorAssistIcon(MonitorAssistIcon.LUT, tint, iconModifier)
        else MonitorIcon(icon, null, iconModifier, tint)
    }
    if (fixed) {
        // Portrait Center stage: the same tools as a plain, always-visible column spanning
        // the secondary feeds. No chevron, drag or collapse.
        Column(modifier.glass(ControlShape).padding(4.dp)) {
            offered.forEach { tool ->
                val available = isAvailable(tool) && !closing
                Box(
                    Modifier.weight(1f).fillMaxWidth().heightIn(min = 44.dp)
                        .alpha(if (isAvailable(tool)) 1f else .4f)
                        .testTag(identifier(tool))
                        .semantics {
                            contentDescription = title(tool)
                            if (tool == MultiviewTool.LUT) stateDescription = if (isOn(tool)) "On" else "Off"
                            role = Role.Button
                        }
                        .monitorChromeClickable(enabled = available, onClickFeedback = actions.feedback,
                            onLongClick = if (tool == MultiviewTool.LUT && services?.configureLUT != null) ({ configure(tool) }) else null) {
                            toggle(tool)
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    glyph(tool, if (isOn(tool)) MonitorPalette.accent else MonitorPalette.text,
                        Modifier.size((cell * 29f / 54f).dp))
                }
            }
        }
        return
    }
    // Landscape stages mount the palette as Live View does: horizontal, bottom-leading.
    androidx.compose.runtime.CompositionLocalProvider(com.opencapture.monitorui.LocalMonitorAssistExpansion provides expansion) {
    Box(modifier, contentAlignment = if (horizontal) Alignment.BottomStart else Alignment.BottomCenter) {
        MonitorAssistPalette(
            tools = offered, portrait = !horizontal, locked = closing,
            isOn = ::isOn,
            title = ::title, label = { tool -> when (tool) {
                MultiviewTool.LUT -> "LUT"
                MultiviewTool.FIT -> if (fill) "FILL" else "FIT"
                MultiviewTool.LAYOUT -> if (grid) "FOCUS" else "GRID"
                MultiviewTool.CAMERA -> "CAM"
            } },
            hasOptions = { it == MultiviewTool.LUT && services?.configureLUT != null }, onOptions = ::configure,
            isAvailable = ::isAvailable,
            accessibilityLabel = ::title,
            accessibilityIdentifier = ::identifier,
            accessibilityValue = { if (it == MultiviewTool.LUT) { if (lut) "On" else "Off" } else null },
            expansionAccessibilityName = "Multiview tools", expansionAccessibilityIdentifier = "multiview.tools.expand",
            cellSize = cell, maxExpandedHeight = maxExpandedHeight,
            idOf = { it.name }, usage = presentation.toolUsage, onUsageChange = { presentation.toolUsage = it },
            onToggle = ::toggle,
            glyph = glyph,
            chevron = { expanded, vertical ->
                val icon = if (vertical) { if (expanded) MonitorIcon.CHEVRON_DOWN else MonitorIcon.CHEVRON_UP }
                    else { if (expanded) MonitorIcon.CHEVRON_LEFT else MonitorIcon.CHEVRON_RIGHT }
                MonitorIcon(icon, null, Modifier.size(14.dp), MonitorPalette.muted)
            },
        )
    }
    }
}

@Composable
private fun DisplayButton(clean: Boolean, modifier: Modifier, feedback: () -> Unit, onClick: () -> Unit) {
    Column(
        modifier.glass(ControlShape).monitorChromeClickable(onClickFeedback = feedback, onClick = onClick)
            .semantics {
                contentDescription = "Change display mode"
                stateDescription = if (clean) "Clean" else "Live"
                role = Role.Button
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
    ) {
        Text(
            "DISP", color = if (clean) Color.White else MonitorPalette.muted,
            style = MonitorTypography.text(12f, FontWeight.Bold).copy(letterSpacing = 0.4.sp),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Box(
                Modifier.size(14.dp, 3.dp).clip(CircleShape)
                    .background(if (clean) Color.White.copy(alpha = 0.28f) else MonitorPalette.accent),
            )
            Box(
                Modifier.size(14.dp, 3.dp).clip(CircleShape)
                    .background(if (clean) MonitorPalette.accent else Color.White.copy(alpha = 0.28f)),
            )
        }
    }
}

private class GroupRecordApproval(val plan: RecordPlan)

@Composable
private fun RecordAllButton(
    recording: Boolean, groupBusy: Boolean, confirm: Boolean, diameter: Float, modifier: Modifier,
    actions: MultiviewStageActions,
) {
    // The dialog holds the plan the operator saw ([MultiviewRecordContext]): a changed camera,
    // link, mode, availability or reported recording dismisses it; routine telemetry does not.
    val context = actions.recordContext(null)
    val plan = context.plan
    val enabled = context.canConfirm
    val visible = LocalMultiviewStageVisible.current
    val latestVisible by rememberUpdatedState(visible)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var pending by remember { mutableStateOf<GroupRecordApproval?>(null) }
    LaunchedEffect(plan, enabled, visible) { pending = null }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) pending = null
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            pending = null
        }
    }
    pending?.takeIf { visible }?.let { approved ->
        MultiviewRecordConfirmation(approved.plan, null, context.prompt,
            onDismiss = { if (pending === approved) pending = null }) {
            if (pending === approved) {
                pending = null
                val now = actions.recordContext(null)
                if (latestVisible && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
                    now.canConfirm && approved.plan == now.plan) actions.record(approved.plan, null)
            }
        }
    }
    val refusal = context.refusal
    Box(
        modifier.alpha(if (enabled || groupBusy) 1f else 0.4f)
            .monitorChromeClickable(enabled = enabled, onClickFeedback = actions.feedback) {
                val now = actions.recordContext(null)
                if (latestVisible && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && now.canConfirm) {
                    if (confirm) pending = GroupRecordApproval(now.plan) else actions.record(now.plan, null)
                }
            }
            .semantics {
                contentDescription = if (recording) "Stop all recording" else "Record all"
                if (refusal != null) stateDescription = refusal
                role = Role.Button
            }.testTag("multiview.recordAll"),
        contentAlignment = Alignment.Center,
    ) {
        MonitorRecordLamp(recording = recording, modifier = Modifier.size(diameter.dp))
        if (groupBusy) {
            CircularProgressIndicator(Modifier.size(24.dp), color = Color.White, strokeWidth = 2.dp)
        }
    }
}

/** Start or stop on every camera (`single` null) or on one camera, after the operator confirms. */
@Composable
public fun MultiviewRecordConfirmation(
    plan: RecordPlan, single: String?, prompt: String? = null, onDismiss: () -> Unit, onConfirm: () -> Unit,
) {
    val stopping = MultiviewRecordContext(plan).stopping
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(
            Modifier.fillMaxSize().monitorChromeClickable(onClick = onDismiss),
            contentAlignment = Alignment.BottomCenter,
        ) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp).monitorMaterial(MonitorMaterial.Expanded, ControlShape)
                    .padding(18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(prompt ?: if (stopping) "Stop recording?" else "Start recording?", color = MonitorPalette.text,
                    style = MonitorTypography.text(16f, FontWeight.SemiBold))
                (single ?: "All connected cameras".takeIf { prompt == null })?.let {
                    Text(it, color = MonitorPalette.muted, style = MonitorTypography.text(13f))
                }
                TextButton(onClick = onConfirm, modifier = Modifier.fillMaxWidth()) {
                    Text(if (stopping) "Stop" else "Start",
                        color = if (stopping) MonitorPalette.recording else MonitorPalette.accent)
                }
                TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
                    Text("Cancel", color = MonitorPalette.muted)
                }
            }
        }
    }
}

@Composable
private fun TileView(
    tiles: List<MultiviewTile?>,
    index: Int,
    compact: Boolean,
    clean: Boolean,
    enabled: Boolean,
    selected: Int,
    arrangement: MultiviewArrangement,
    busy: Boolean,
    groupBusy: Boolean,
    confirmRecording: Boolean,
    actions: MultiviewStageActions,
    footerStart: Float,
    inlineValues: Boolean,
    picture: @Composable (Int) -> Unit,
) {
    val tile = tiles[index]
    // The gesture outlives a recomposition; it calls the stage's latest actions.
    val current by rememberUpdatedState(actions)
    val focused = index == selected && tile != null
    var optionsOpen by remember { mutableStateOf(false) }
    var confirmRecord by remember { mutableStateOf<RecordPlan?>(null) }
    val context = if (tile != null) actions.recordContext(index) else null
    LaunchedEffect(clean, enabled, tile == null) {
        if (clean || !enabled || tile == null) optionsOpen = false
        if (!enabled || tile == null) confirmRecord = null
    }
    LaunchedEffect(context?.plan, context?.closing) { confirmRecord = null }
    Box(Modifier.fillMaxSize().background(MonitorPalette.surface, TileShape)) {
        if (tile != null) {
            picture(index)
            // A tile retains the same picture owner through layout, selection and rotation.
            Box(
                Modifier.fillMaxSize().pointerInput(index, enabled) {
                    if (!enabled) return@pointerInput
                    detectTapGestures(
                        onDoubleTap = { current.popupsClosed(); current.openLiveView(index) },
                        onTap = { current.select(index) },
                    )
                }.semantics {
                    contentDescription = "Select camera ${MultiviewTile.letter(index)}, ${tile.name}"
                    stateDescription = if (focused) "Selected" else "Not selected"
                    role = Role.Button
                    if (enabled) onClick { actions.select(index); true }
                },
            )
            TileOverlay(tile, index, focused, compact, clean, enabled, footerStart, inlineValues, actions) {
                actions.select(index)
                optionsOpen = true
            }
            Box(Modifier.align(Alignment.TopEnd).padding(6.dp)) {
                DropdownMenu(
                    expanded = optionsOpen,
                    onDismissRequest = {
                        optionsOpen = false
                        actions.popupsClosed()
                    },
                    modifier = Modifier.widthIn(min = 220.dp, max = 320.dp).heightIn(max = 520.dp)
                        .monitorMaterial(MonitorMaterial.Expanded, ControlShape),
                    containerColor = Color.Transparent, shadowElevation = 0.dp,
                ) {
                    tile.failure?.let { message ->
                        Text(message, modifier = Modifier.widthIn(max = 280.dp).padding(12.dp),
                            style = MonitorTypography.text(12f))
                    }
                    CameraMenuHeader(tile)
                    tile.actions.forEach { action ->
                        // The app's `enabled` decides the record option (its plan, group and closing state).
                        val record = action.kind == MultiviewCameraAction.Kind.RECORD
                        PopupAction(
                            action.title, enabled = action.enabled,
                            destructive = action.kind == MultiviewCameraAction.Kind.DESTRUCTIVE,
                            feedback = actions.feedback,
                        ) {
                            optionsOpen = false
                            when {
                                record -> context?.plan?.let { plan ->
                                    if (confirmRecording) confirmRecord = plan else actions.record(plan, index)
                                }
                                action.id == MultiviewCameraAction.LIVE_VIEW -> { actions.popupsClosed(); actions.openLiveView(index) }
                                else -> actions.perform(action.id, index)
                            }
                        }
                    }
                }
            }
            if (tile.status != null && !compact && !clean) {
                StatusCard(tile, actions, index, Modifier.align(Alignment.Center))
            }
        } else {
            // Center stage offers "Add camera" on the big tile while it is empty.
            val addSlot = selected.takeIf {
                arrangement == MultiviewArrangement.CENTER_STAGE && it in tiles.indices && tiles[it] == null
            } ?: tiles.indexOfFirst { it == null }
            if (addSlot == index && !clean) {
                Column(
                    Modifier.fillMaxSize()
                        .monitorChromeClickable(
                            enabled = enabled && !busy && !groupBusy, onClickFeedback = actions.feedback,
                        ) { actions.add(index) }
                        .semantics { contentDescription = "Add camera"; role = Role.Button },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterVertically),
                ) {
                    MonitorIcon(MonitorIcon.PLUS, null, Modifier.size(if (compact) 24.dp else 34.dp), MonitorPalette.muted)
                    Text("Add camera", color = MonitorPalette.muted,
                        style = MonitorTypography.text(if (compact) 10f else 14f, FontWeight.SemiBold))
                }
            } else if (!clean) {
                Text(MultiviewTile.letter(index), color = MonitorPalette.muted.copy(alpha = 0.35f),
                    style = MonitorTypography.text(16f), modifier = Modifier.align(Alignment.Center))
            }
        }
        val recordingNow = tile?.recording == true
        Box(Modifier.fillMaxSize().border(
            if (recordingNow) 3.dp else if (focused && !clean) 2.dp else 1.dp,
            when {
                recordingNow -> MonitorPalette.recording
                focused && !clean -> MonitorPalette.accent
                else -> Color.White.copy(alpha = 0.1f)
            }, TileShape,
        ))
    }
    confirmRecord?.let { approved ->
        MultiviewRecordConfirmation(approved, tile?.name.orEmpty(), context?.prompt, onDismiss = { confirmRecord = null }) {
            confirmRecord = null
            val now = actions.recordContext(index)
            if (approved == now.plan && !now.closing) actions.record(approved, index)
        }
    }
}

/** The camera's details above its actions. */
@Composable
private fun CameraMenuHeader(tile: MultiviewTile) {
    Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
        Text(tile.name, style = MonitorTypography.text(14f, FontWeight.SemiBold))
        Text(tile.model, style = MonitorTypography.text(12f))
        Text("TC ${tile.timecode ?: MultiviewTally.UNAVAILABLE}", style = MonitorTypography.readout(12f))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            MonitorBatteryOutlineRow(tile.battery ?: -1, tile.charging, camera = true, tile.batteryBars, tile.batteryBarCount)
            Text(tile.storage, style = MonitorTypography.text(12f))
        }
        Text("${tile.format} · ${tile.tally}", style = MonitorTypography.text(12f))
        tile.note?.let { Text(it, style = MonitorTypography.text(12f)) }
    }
}

@Composable
private fun PopupAction(
    title: String, enabled: Boolean, destructive: Boolean, feedback: () -> Unit, onClick: () -> Unit,
) {
    Text(
        title,
        color = if (destructive) MonitorPalette.recording else MonitorPalette.text,
        style = MonitorTypography.text(14f, FontWeight.Medium),
        maxLines = 2,
        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp)
            .alpha(if (enabled) 1f else 0.4f)
            .monitorChromeClickable(enabled = enabled, onClickFeedback = feedback, onClick = onClick)
            .semantics { role = Role.Button }
            .padding(horizontal = 14.dp, vertical = 12.dp),
    )
}

@Composable
private fun StatusCard(tile: MultiviewTile, actions: MultiviewStageActions, slot: Int, modifier: Modifier) {
    val status = tile.status ?: return
    Column(
        modifier.padding(16.dp).glass(RoundedCornerShape(16.dp)).padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (status.inProgress) {
            CircularProgressIndicator(Modifier.size(22.dp), color = MonitorPalette.text, strokeWidth = 2.dp)
        }
        Text(status.detail, color = MonitorPalette.text, textAlign = TextAlign.Center, style = MonitorTypography.text(13f))
        tile.footnote?.let {
            Text(it, color = MonitorPalette.text, textAlign = TextAlign.Center, style = MonitorTypography.text(12f))
        }
        val offered = status.actions
        // A lone first action takes its own row; the last two share one, as Reconnect and Remove.
        val single = if (offered.size > 2) offered.first() else null
        single?.let { action -> PillButton(action, actions, slot) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            offered.drop(if (single != null) 1 else 0).forEach { action -> PillButton(action, actions, slot) }
        }
    }
}

@Composable
private fun PillButton(action: MultiviewCameraAction, actions: MultiviewStageActions, slot: Int) {
    Box(
        Modifier.heightIn(min = 44.dp).alpha(if (action.enabled) 1f else 0.4f)
            .clip(RoundedCornerShape(10.dp))
            .background(GlassBright)
            .monitorChromeClickable(enabled = action.enabled, onClickFeedback = actions.feedback) {
                actions.perform(action.id, slot)
            }
            .semantics { role = Role.Button }
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            action.title,
            color = if (action.kind == MultiviewCameraAction.Kind.DESTRUCTIVE) MonitorPalette.recording
            else MonitorPalette.accent,
            style = MonitorTypography.text(15f, FontWeight.SemiBold),
        )
    }
}

/** Recovery is safety status, so Clean display keeps it and its camera actions available. */
@Composable
private fun TileOverlay(
    tile: MultiviewTile, index: Int, focused: Boolean, compact: Boolean, clean: Boolean, enabled: Boolean,
    footerStart: Float, inlineValues: Boolean, actions: MultiviewStageActions, onOptions: () -> Unit,
) {
    val feedback = actions.feedback
    Box(Modifier.fillMaxSize()) {
        if (!clean) {
            TileChrome(
                tile, index, focused, compact, enabled, actions, onOptions, footerStart = footerStart,
                values = if (inlineValues) tile.readouts else null,
            )
        }
        val status = tile.status
        if (status != null && (compact || clean)) {
            Box(
                Modifier.align(Alignment.Center).heightIn(min = 44.dp)
                    .background(Color.Black.copy(alpha = 0.8f), RoundedCornerShape(8.dp))
                    .monitorChromeClickable(enabled = enabled, onClickFeedback = feedback, onClick = onOptions)
                    .semantics {
                        contentDescription = "${status.text} Camera ${MultiviewTile.letter(index)} options"
                        role = Role.Button
                    }
                    .padding(horizontal = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(status.text, color = Color.White,
                    style = MonitorTypography.text(if (compact) 8f else 12f, FontWeight.SemiBold),
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Metadata stays inside every feed, including narrow thumbnails and portrait rows. */
@Composable
private fun TileChrome(
    tile: MultiviewTile,
    index: Int,
    focused: Boolean,
    compact: Boolean,
    enabled: Boolean,
    actions: MultiviewStageActions,
    onOptions: () -> Unit,
    footerStart: Float = 0f,
    /** Grid's selected tile shows its camera values between the footer's left and right. */
    values: List<MultiviewReadout>? = null,
) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val narrow = maxWidth < 200.dp
        val short = maxHeight < 80.dp
        val small = if (narrow) 7f else if (compact) 8f else 10f
        val edge = if (narrow) 4.dp else 6.dp
        val letter = MultiviewTile.letter(index)
        Row(
            Modifier.fillMaxWidth().align(Alignment.TopCenter)
                .padding(start = edge, top = edge, end = if (narrow) 28.dp else 50.dp, bottom = edge),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(if (narrow) 3.dp else 5.dp),
        ) {
            Box(
                Modifier.size(if (narrow) 14.dp else if (compact) 18.dp else 24.dp)
                    .background(if (focused) MonitorPalette.accent else Color.Black.copy(alpha = 0.45f),
                        RoundedCornerShape(4.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Text(letter, color = if (focused) Color.Black else Color.White,
                    style = MonitorTypography.text(if (compact) 9f else 13f, FontWeight.Bold))
            }
            Column(Modifier.weight(1f)) {
                Text(tile.name, color = Color.White,
                    style = MonitorTypography.text(if (narrow) 9f else if (compact) 10f else 13f, FontWeight.SemiBold),
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (!short) {
                    val timecode = tile.timecode ?: MultiviewTally.UNAVAILABLE
                    Text(tile.model, color = Color.White.copy(alpha = 0.7f), style = MonitorTypography.text(small),
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("TC $timecode", color = Color.White, style = MonitorTypography.readout(small),
                        maxLines = 1, modifier = Modifier.semantics { contentDescription = "Timecode $timecode" })
                }
            }
        }
        // Its full 44dp hit target does not force a tall header on landscape thumbnails.
        Box(
            Modifier.align(Alignment.TopEnd).size(44.dp)
                .monitorChromeClickable(enabled = enabled, onClickFeedback = actions.feedback, onClick = onOptions)
                .semantics { contentDescription = "Camera $letter options"; role = Role.Button },
            contentAlignment = Alignment.TopEnd,
        ) {
            MonitorIcon(MonitorIcon.ELLIPSIS, null, Modifier.padding(top = edge, end = edge).size(20.dp), Color.White)
        }
        Column(
            Modifier.fillMaxWidth().align(Alignment.BottomCenter).padding(start = footerStart.dp).padding(edge),
        ) {
            if (!compact) {
                Text(tile.format, color = Color.White.copy(alpha = 0.75f), style = MonitorTypography.text(small),
                    maxLines = 1)
            }
            tile.tileNote?.let {
                Text(it, color = Amber, style = MonitorTypography.text(small, FontWeight.Medium), maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.align(Alignment.End))
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                BatteryPill(tile.battery, tile.batteryBars, tile.batteryBarCount)
                Text(tile.storage, color = Color.White, style = MonitorTypography.readout(small), maxLines = 1,
                    modifier = (if (values == null) Modifier.weight(1f) else Modifier)
                        .semantics { contentDescription = "Storage ${tile.storage}" })
                if (values != null) {
                    // Inline with both sides; the values take what is left over.
                    Row(Modifier.weight(1f),
                        horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.Bottom) {
                        values.forEachIndexed { value, readout ->
                            ReadoutValue(readout, index, value, actions,
                                Modifier.weight(1f, fill = false).widthIn(max = 55.dp), 10f, 6f)
                        }
                    }
                }
                Tally(tile, small)
            }
        }
    }
}

@Composable
private fun Tally(tile: MultiviewTile, size: Float) {
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    val since = tile.recordingSince
    if (since != null) {
        LaunchedEffect(since) {
            while (true) {
                now = System.currentTimeMillis()
                delay(1_000)
            }
        }
    }
    Text(
        since?.let { MultiviewTally.running(((now - it) / 1_000).toInt()) } ?: tile.tally,
        color = if (tile.recording) MonitorPalette.recording else Color.White,
        style = MonitorTypography.readout(size, FontWeight.SemiBold), maxLines = 1,
    )
}

/**
 * The camera battery pill without its glyph; one width fits "100%" so values never jitter.
 * A camera that reports a coarse gauge shows its [bars], never a percent it did not report.
 */
@Composable
private fun BatteryPill(percent: Int?, bars: Int?, barCount: Int) {
    val level = bars?.let { it * 100 / barCount.coerceAtLeast(1) } ?: percent
    val tint = when {
        level == null -> MonitorPalette.text
        level <= 20 -> MonitorPalette.recording
        level <= 40 -> Amber
        else -> Good
    }
    Row(
        Modifier.size(40.dp, 20.dp).glass(RoundedCornerShape(7.dp)).padding(horizontal = 6.dp)
            .semantics {
                contentDescription = bars?.let { "Camera battery $it of $barCount bars" }
                    ?: percent?.let { "Camera battery $it percent" } ?: "Camera battery unavailable"
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (bars != null) MonitorGaugeBars(bars.toFloat() / barCount.coerceAtLeast(1), barCount, tint)
        else Text(percent?.let { "$it%" } ?: MultiviewTally.UNAVAILABLE, color = tint,
            style = MonitorTypography.readout(10f, FontWeight.Bold), maxLines = 1)
    }
}

/**
 * Add camera: one row per camera the app offers; the ones that cannot join say why.
 *
 * @param searching shown with a spinner while [rows] is empty and [empty] is null.
 * @param empty shown instead when nothing more will appear.
 */
@Composable
public fun MultiviewCameraPicker(
    rows: List<MultiviewPickerRow>,
    onCancel: () -> Unit,
    onPick: (String) -> Unit,
    searching: String = "Looking for nearby cameras…",
    empty: String? = null,
    footer: String? = null,
    feedback: () -> Unit = {},
) {
    val cardHeight = (maxOf(1, minOf(4, rows.size)) * 60 + 140).toFloat()
    ModalCard(maxHeight = cardHeight, tag = "multiview.cameraPicker") {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Add camera", color = MonitorPalette.text, style = MonitorTypography.text(20f, FontWeight.SemiBold),
                modifier = Modifier.weight(1f))
            Box(
                Modifier.heightIn(min = 44.dp).widthIn(min = 64.dp)
                    .monitorChromeClickable(onClickFeedback = feedback, onClick = onCancel)
                    .semantics { role = Role.Button },
                contentAlignment = Alignment.CenterStart,
            ) {
                Text("Cancel", color = MonitorPalette.accent, style = MonitorTypography.text(16f))
            }
        }
        val pickerScroll = rememberScrollState()
        Column(
            Modifier.weight(1f, fill = false).monitorScrollFade(pickerScroll).verticalScroll(pickerScroll)
                .padding(start = 20.dp, end = 20.dp, bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            for (row in rows) {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(TileShape).background(GlassBright)
                        .alpha(if (row.enabled) 1f else 0.5f)
                        .monitorChromeClickable(enabled = row.enabled, onClickFeedback = feedback) { onPick(row.id) }
                        .semantics { role = Role.Button }
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f).padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(row.title, color = MonitorPalette.text, maxLines = 2, style = MonitorTypography.text(16f))
                        row.detail?.let {
                            Text(it, color = MonitorPalette.muted, style = MonitorTypography.text(12f))
                        }
                    }
                    MonitorIcon(
                        if (row.limited) MonitorIcon.INFO else MonitorIcon.PLUS, null,
                        Modifier.size(20.dp), MonitorPalette.text,
                    )
                }
            }
            if (rows.isEmpty()) {
                Row(
                    Modifier.heightIn(min = 52.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    if (empty == null) {
                        CircularProgressIndicator(Modifier.size(20.dp), color = MonitorPalette.text, strokeWidth = 2.dp)
                    }
                    Text(empty ?: searching, color = MonitorPalette.text, style = MonitorTypography.text(16f))
                }
            }
            footer?.let {
                Text(it, color = MonitorPalette.muted, style = MonitorTypography.text(13f),
                    modifier = Modifier.padding(top = 4.dp))
            }
        }
    }
}

/** A bounded centered card: at most 460 dp wide, including landscape. */
@Composable
private fun ModalCard(maxHeight: Float, tag: String, content: @Composable ColumnScope.() -> Unit) {
    BoxWithConstraints(
        Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f))
            .pointerInput(Unit) { detectTapGestures { } },
        contentAlignment = Alignment.Center,
    ) {
        val width = minOf(460.dp, (maxWidth - 32.dp).coerceAtLeast(0.dp))
        val height = minOf(maxHeight.dp, (this.maxHeight - 24.dp).coerceAtLeast(0.dp))
        Column(
            Modifier.widthIn(max = width).fillMaxWidth().heightIn(max = height)
                .shadow(24.dp, TileShape)
                .glass(TileShape)
                .testTag(tag),
            content = content,
        )
    }
}
