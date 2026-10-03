package com.opencapture.monitorui.settings

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import kotlinx.coroutines.delay
import kotlin.math.floor
import kotlin.math.roundToInt

/** Stable capture-layout identity and supplied operator-facing title. */
public data class MonitorDisplayChoice(val id: String, val title: String)

/** A known visibility value and its admitted host action. */
public data class MonitorDisplayToggle(
    val id: String,
    val title: String,
    val isOn: Boolean,
    val accessibilityLabel: String = title,
    val help: String? = null,
    val action: () -> Unit,
)

/** An absent toggle means permanent inclusion, rather than an inert lit switch. */
public data class MonitorDisplayOrderItem(
    val id: String,
    val title: String,
    val isOn: Boolean,
    val supplement: String? = null,
    val highlighted: Boolean = false,
    val visibilityLabel: String = title,
    val visibilityValue: String = if (isOn) "Shown" else "Hidden",
    val reorderLabel: String? = null,
    val moveEarlierLabel: String? = null,
    val moveLaterLabel: String? = null,
    val positionLabel: String? = null,
    val positionDescription: String? = null,
    val toggle: (() -> Unit)? = null,
)

/** Supplied order, reset and direct destination actions; persistence stays with the host. */
public data class MonitorDisplayOrderGroup(
    val title: String,
    val caption: String,
    val items: List<MonitorDisplayOrderItem>,
    val reset: (() -> Unit)? = null,
    /** Direct destination index after removal of the dragged item. */
    val move: (String, Int) -> Unit,
)

/** Editor-led sections offer canvas editing; control-led sections keep visibility rows available. */
public enum class MonitorDisplaySectionStyle { EDITOR, CONTROLS }

/** Only an eligible host supplies the live editor action; storage stays outside UI. */
public data class MonitorDisplaySection(
    val id: String,
    val title: String,
    val caption: String,
    val reset: (() -> Unit)? = null,
    val editTitle: String = "Edit view",
    val editHint: String? = null,
    val edit: (() -> Unit)? = null,
    val unavailableEditHelp: String? = null,
    val visibility: List<MonitorDisplayToggle> = emptyList(),
    val readoutsTitle: String? = null,
    val readouts: List<MonitorDisplayToggle> = emptyList(),
    val pinsTitle: String? = null,
    val pins: List<MonitorDisplayToggle> = emptyList(),
    val tools: MonitorDisplayOrderGroup? = null,
    val style: MonitorDisplaySectionStyle = MonitorDisplaySectionStyle.EDITOR,
)

private val DisplayShape = RoundedCornerShape(12.dp)

/** Actual common Display section assembly over typed values and actions. */
@Composable
public fun MonitorDisplaySettings(
    layoutTitle: String = "Layout For",
    layoutHelp: String,
    choices: List<MonitorDisplayChoice>,
    selection: String,
    onSelect: (String) -> Unit,
    expandedSection: String?,
    onExpand: (String?) -> Unit,
    sections: List<MonitorDisplaySection>,
    order: MonitorDisplayOrderGroup,
    compact: Boolean = false,
    onInteraction: () -> Unit = {},
    scrollContext: MonitorSettingsScrollContext? = LocalMonitorSettingsScrollContext.current,
) {
    MonitorSettingsGroupCard(title = layoutTitle, caption = layoutHelp, captionMaxLines = 3) {
        MonitorSettingsChoices(options = choices.map { it.id }, selected = selection,
            testTag = "monitor.settings.display.capture",
            title = { id -> choices.first { it.id == id }.title }, onSelect = onSelect)
    }
    MonitorDisplaySections(sections, expandedSection, onExpand, compact, onInteraction, scrollContext)
    MonitorSettingsGroupCard(title = order.title, caption = order.caption, onReset = order.reset) {
        MonitorDisplayOrderList(order.items, order.move, onInteraction,
            scrollContext?.scrollState, scrollContext?.viewportBounds)
    }
}

/** Typed sections for hosts with or without a separate capture-layout picker and ordering. */
@Composable
public fun MonitorDisplaySections(
    sections: List<MonitorDisplaySection>,
    expandedSection: String? = null,
    onExpand: ((String?) -> Unit)? = null,
    compact: Boolean = false,
    onInteraction: () -> Unit = {},
    scrollContext: MonitorSettingsScrollContext? = LocalMonitorSettingsScrollContext.current,
) {
    sections.forEach { section ->
        key(section.id) {
            MonitorSettingsGroupCard(title = section.title, caption = section.caption, onReset = section.reset,
                captionMaxLines = Int.MAX_VALUE,
                expanded = if (onExpand == null) null else expandedSection == section.id,
                onExpandToggle = onExpand?.let { expand ->
                    { expand(if (expandedSection == section.id) null else section.id) }
                }) {
                Column(Modifier.testTag("monitor.settings.display.section.${section.id}"),
                    verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    section.edit?.let { edit ->
                        MonitorSettingsActionPill(title = section.editTitle, onClick = edit,
                            modifier = Modifier.testTag("monitor.settings.display.edit.${section.id}"))
                    } ?: section.unavailableEditHelp?.let { DisplayCaption(it) }
                    if (section.style == MonitorDisplaySectionStyle.CONTROLS) {
                        section.visibility.forEach { item ->
                            key(item.id) {
                                MonitorSettingsSwitchInlineRow(title = item.title, help = item.help,
                                    isOn = item.isOn, onToggle = item.action,
                                    testTag = "monitor.settings.display.toggle.${item.id}")
                            }
                        }
                    } else if (section.edit == null) {
                        MonitorDisplayToggleGrid(section.visibility, compact)
                    }
                    if (section.edit != null || section.style == MonitorDisplaySectionStyle.CONTROLS) {
                        if (section.readouts.isNotEmpty()) {
                            section.readoutsTitle?.let { DisplayCaption(it) }
                            MonitorDisplayToggleGrid(section.readouts, compact)
                        }
                        if (section.pins.isNotEmpty()) {
                            section.pinsTitle?.let { DisplayCaption(it) }
                            MonitorDisplayToggleGrid(section.pins, compact)
                        }
                        section.tools?.let { tools ->
                            DisplayCaption(tools.caption)
                            MonitorDisplayOrderList(tools.items, tools.move, onInteraction,
                                scrollContext?.scrollState, scrollContext?.viewportBounds)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DisplayCaption(text: String) {
    Text(text, style = MonitorTypography.text(11f, FontWeight.SemiBold), color = MonitorPalette.muted)
}

/** Complete labels and switches must fit before a pane gains another column. */
public fun monitorDisplayToggleColumnCount(
    compact: Boolean, availableWidthDp: Float, minimumCellWidthDp: Float = 0f,
): Int {
    require(availableWidthDp >= 0f && minimumCellWidthDp >= 0f) { "display toggle widths must not be negative" }
    if (!compact && availableWidthDp >= 480f && (availableWidthDp - 21f) / 4f >= minimumCellWidthDp) return 4
    return if ((availableWidthDp - 7f) / 2f >= minimumCellWidthDp) 2 else 1
}

/** Responsive native label measurement keeps each supplied toggle inside its card. */
@Composable
public fun MonitorDisplayToggleGrid(items: List<MonitorDisplayToggle>, compact: Boolean = false) {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val labelStyle = MonitorTypography.text(11.5f, FontWeight.SemiBold)
    val minimumCellWidth = with(density) {
        (items.maxOfOrNull { measurer.measure(it.title, labelStyle, softWrap = false, maxLines = 1).size.width } ?: 0).toDp().value
    } + 39f + 18f + 14f
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = monitorDisplayToggleColumnCount(compact, maxWidth.value, minimumCellWidth)
        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
            items.chunked(columns).forEach { row ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    row.forEach { item ->
                        MonitorSettingsDisplayToggle(item.title, item.isOn,
                            modifier = Modifier.weight(1f).testTag("monitor.settings.display.toggle.${item.id}")
                                .semantics {
                                    contentDescription = item.accessibilityLabel
                                    stateDescription = if (item.isOn) "On" else "Off"
                                },
                            onToggle = item.action)
                    }
                }
            }
        }
    }
}

/** Maps a held row position to the exact clamped destination. */
public fun monitorDisplayReorderIndex(pointerY: Float, rowHeight: Float, itemCount: Int): Int {
    require(rowHeight > 0f && itemCount > 0) { "settings reorder list must contain positive rows" }
    return floor(pointerY / rowHeight).toInt().coerceIn(0, itemCount - 1)
}

/** Only the trailing grip lane admits a reorder gesture. */
public fun monitorDisplayReorderGripHit(pointerX: Float, containerWidth: Float, gripWidth: Float): Boolean {
    require(containerWidth >= 0f && gripWidth > 0f) { "settings reorder grip must be positive" }
    return pointerX >= (containerWidth - gripWidth).coerceAtLeast(0f) && pointerX <= containerWidth
}

/** Signed per-frame parent-scroll demand at the actual viewport edge. */
public fun monitorDisplayReorderAutoScrollDelta(pointerRootY: Float, viewportTop: Float,
    viewportBottom: Float, edgeThreshold: Float, maximumStep: Float): Float {
    require(viewportBottom >= viewportTop && edgeThreshold > 0f && maximumStep >= 0f) {
        "settings reorder viewport must be valid"
    }
    val topDistance = pointerRootY - viewportTop
    if (topDistance < edgeThreshold) return -maximumStep * ((edgeThreshold - topDistance) / edgeThreshold).coerceIn(0f, 1f)
    val bottomDistance = viewportBottom - pointerRootY
    if (bottomDistance < edgeThreshold) return maximumStep * ((edgeThreshold - bottomDistance) / edgeThreshold).coerceIn(0f, 1f)
    return 0f
}

/** Real trailing-handle drag with accessible moves and the actual parent's edge autoscroll. */
@Composable
public fun MonitorDisplayOrderList(
    items: List<MonitorDisplayOrderItem>,
    move: (String, Int) -> Unit,
    onInteraction: () -> Unit = {},
    parentScrollState: ScrollState? = null,
    viewportBounds: Rect? = null,
) {
    val latestItems by rememberUpdatedState(items)
    val latestMove by rememberUpdatedState(move)
    val latestInteraction by rememberUpdatedState(onInteraction)
    var draggingID by remember { mutableStateOf<String?>(null) }
    var dragPosition by remember { mutableStateOf(Offset.Zero) }
    var dragRootY by remember { mutableStateOf<Float?>(null) }
    var listBounds by remember { mutableStateOf<Rect?>(null) }
    val rowHeight = 50.dp
    val gripWidth = 48.dp
    val density = LocalDensity.current
    val rowHeightPx = with(density) { rowHeight.toPx() }
    val gripWidthPx = with(density) { gripWidth.toPx() }
    val edgeThresholdPx = with(density) { 48.dp.toPx() }
    val maximumScrollStepPx = with(density) { 12.dp.toPx() }

    LaunchedEffect(draggingID, dragRootY, viewportBounds, parentScrollState) {
        val scroll = parentScrollState ?: return@LaunchedEffect
        val rootY = dragRootY ?: return@LaunchedEffect
        val viewport = viewportBounds ?: return@LaunchedEffect
        while (draggingID != null) {
            val delta = monitorDisplayReorderAutoScrollDelta(rootY, viewport.top, viewport.bottom,
                edgeThresholdPx, maximumScrollStepPx)
            if (delta == 0f) return@LaunchedEffect
            scroll.scrollBy(delta)
            delay(16)
            val id = draggingID ?: return@LaunchedEffect
            val bounds = listBounds ?: continue
            val current = latestItems
            if (current.isNotEmpty() && current.any { it.id == id }) {
                val target = monitorDisplayReorderIndex(rootY - bounds.top, rowHeightPx, current.size)
                if (current.indexOfFirst { it.id == id } != target) latestMove(id, target)
            }
        }
    }
    BoxWithConstraints(
        Modifier.fillMaxWidth().height(rowHeight * items.size)
            .onGloballyPositioned { listBounds = it.boundsInRoot() }
            .pointerInput(Unit) {
                detectDragGesturesAfterLongPress(
                    onDragStart = { start ->
                        if (monitorDisplayReorderGripHit(start.x, size.width.toFloat(), gripWidthPx)) {
                            val current = latestItems
                            if (current.isNotEmpty()) {
                                draggingID = current[monitorDisplayReorderIndex(start.y, rowHeightPx, current.size)].id
                                dragPosition = start
                                dragRootY = listBounds?.top?.plus(start.y)
                                latestInteraction()
                            }
                        }
                    },
                    onDrag = { change, _ ->
                        val id = draggingID
                        if (id != null) {
                            change.consume()
                            dragPosition = change.position
                            dragRootY = listBounds?.top?.plus(change.position.y)
                            val current = latestItems
                            if (current.isNotEmpty() && current.any { it.id == id }) {
                                val target = monitorDisplayReorderIndex(change.position.y, rowHeightPx, current.size)
                                if (current.indexOfFirst { it.id == id } != target) latestMove(id, target)
                            }
                        }
                    },
                    onDragEnd = { draggingID = null; dragRootY = null },
                    onDragCancel = { draggingID = null; dragRootY = null },
                )
            },
    ) {
        val listHeightPx = constraints.maxHeight.toFloat()
        items.forEachIndexed { index, item ->
            key(item.id) {
                val dragging = item.id == draggingID
                val y = if (dragging) (dragPosition.y - rowHeightPx / 2f)
                    .coerceIn(0f, (listHeightPx - rowHeightPx).coerceAtLeast(0f)) else index * rowHeightPx
                val actions = buildList {
                    if (index > 0) add(CustomAccessibilityAction(item.moveEarlierLabel ?: "Move ${item.title} earlier") {
                        latestMove(item.id, index - 1); latestInteraction(); true
                    })
                    if (index < items.lastIndex) add(CustomAccessibilityAction(item.moveLaterLabel ?: "Move ${item.title} later") {
                        latestMove(item.id, index + 1); latestInteraction(); true
                    })
                }
                Column(Modifier.offset { IntOffset(0, y.roundToInt()) }.fillMaxWidth().height(rowHeight)
                    .graphicsLayer {
                        scaleX = if (dragging) 1.02f else 1f; scaleY = if (dragging) 1.02f else 1f
                        shadowElevation = if (dragging) 12.dp.toPx() else 0f; shape = DisplayShape
                    }.zIndex(if (dragging) 1f else 0f)
                    .background(if (dragging) MonitorPalette.surface else Color.Transparent)) {
                    if (index != 0) Box(Modifier.fillMaxWidth().height(1.dp).background(MonitorPalette.border))
                    Row(Modifier.fillMaxWidth().weight(1f), horizontalArrangement = Arrangement.spacedBy(9.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(22.dp).background(MonitorPalette.surface, CircleShape)
                            .semantics { contentDescription = item.positionDescription ?: "Position ${index + 1}" },
                            contentAlignment = Alignment.Center) {
                            Text(item.positionLabel ?: "${index + 1}", style = MonitorTypography.readout(9f, FontWeight.Medium),
                                color = MonitorPalette.muted)
                        }
                        Text(item.title, style = MonitorTypography.text(12.5f, FontWeight.SemiBold),
                            color = if (item.highlighted) MonitorPalette.accent else if (item.isOn) MonitorPalette.text else MonitorPalette.muted,
                            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        if (item.toggle != null) {
                            Box(Modifier.clickable(interactionSource = remember { MutableInteractionSource() },
                                indication = null, role = Role.Switch, onClick = item.toggle)
                                .semantics { contentDescription = item.visibilityLabel; stateDescription = item.visibilityValue }
                                .testTag("monitor.settings.display.visibility.${item.id}")) {
                                MonitorSettingsSwitchGraphic(item.isOn)
                            }
                        } else if (item.supplement != null) {
                            MonitorSettingsValueText(item.supplement)
                        }
                        Box(Modifier.width(gripWidth).fillMaxHeight()
                            .testTag("monitor.settings.display.grip.${item.id}")
                            .semantics {
                                contentDescription = item.reorderLabel ?: "Reorder ${item.title}, position ${index + 1}"
                                customActions = actions
                            }, contentAlignment = Alignment.Center) {
                            Canvas(Modifier.size(18.dp, 14.dp)) {
                                listOf(2f, 7f, 12f).forEach { yOffset ->
                                    drawLine(MonitorPalette.faint, Offset(1.dp.toPx(), yOffset.dp.toPx()),
                                        Offset(size.width - 1.dp.toPx(), yOffset.dp.toPx()),
                                        strokeWidth = 1.6.dp.toPx(), cap = StrokeCap.Round)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
