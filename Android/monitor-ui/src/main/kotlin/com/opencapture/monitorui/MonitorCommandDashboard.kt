package com.opencapture.monitorui

import android.os.SystemClock
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * One command dashboard value. [kind] is the persisted reorder identity (null: the tile keeps its
 * place); [request] is the host's write intent (null: read-only).
 */
data class MonitorCommandTile<K : Any, R : Any>(
    val kind: K? = null,
    val title: String,
    val value: String,
    val request: R? = null,
    val unavailableReason: String? = null,
    /** Accent-tinted side value (iOS `.cmd-stile.amber`). */
    val amber: Boolean = false,
    /** Dimmed side value (iOS `.cmd-stile.muted`), a placeholder with no write path. */
    val muted: Boolean = false,
)

/** One titled side-column group. Cells pack two per row; a leftover cell spans the row. */
data class MonitorCommandSection<K : Any, R : Any>(
    val title: String,
    val cells: List<MonitorCommandTile<K, R>>,
)

/** The health strip readouts, formatted by the host. [temperatureOk] paints the temperature good. */
data class MonitorCommandHealth(
    val temperature: String,
    val temperatureOk: Boolean,
    val storage: String,
    val camera: String,
    val lens: String,
)

/**
 * The hero band reads the header's own [MonitorStatusPresentation] (SwiftUI twin:
 * `MonitorStatusPresentation.commandHeroTimecode`): the timecode split before its frame field (the
 * part the accent paints). A body without timecode leaves it null, so the hero shows no frozen
 * 00:00:00:00.
 */
val MonitorStatusPresentation.commandHeroTimecode: Pair<String, String>?
    get() {
        val value = timecode?.takeIf { it.isNotEmpty() } ?: return null
        val split = value.indexOfLast { it == ':' || it == ';' }
        return if (split < 0) value to "" else value.substring(0, split) to value.substring(split)
    }

/** The hero's spoken value: the header's record words, then the timecode when there is one. */
val MonitorStatusPresentation.commandHeroAccessibilityValue: String
    get() = listOfNotNull(recordingAccessibilityLabel, timecode?.takeIf { it.isNotEmpty() }).joinToString(", ")

/** Drops duplicates and kinds outside [all], then appends the kinds the order lacks in [all]'s order. */
fun <K> monitorCommandTileOrder(order: List<K>, all: List<K>): List<K> {
    val unique = order.distinct().filter(all::contains)
    return unique + all.filterNot(unique::contains)
}

/** Moves [kind] to [targetIndex] of the normalized order, keeping it complete. */
fun <K> moveMonitorCommandTile(order: List<K>, kind: K, targetIndex: Int, all: List<K>): List<K> {
    val normalized = monitorCommandTileOrder(order, all).toMutableList()
    if (!normalized.remove(kind)) return normalized
    normalized.add(targetIndex.coerceIn(0, normalized.size), kind)
    return normalized
}

private const val COMMAND_GRID_COLUMNS = 3
private const val COMMAND_GRID_SPACING_DP = 9
private const val COMMAND_REORDER_CLICK_SUPPRESSION_MS = 150L
private const val COMMAND_PORTRAIT_GRID_ROW_HEIGHT_DP = 76
/** iOS CommandSmallTile minHeight, landscape side column. */
private val COMMAND_SIDE_TILE_MIN_HEIGHT = 42.dp
private val COMMAND_PORTRAIT_SIDE_TILE_HEIGHT = 44.dp
private val CommandShape = RoundedCornerShape(12.dp)
/** Gap between the hero, the health strip and the grid (iOS `MonitorCommandGridLayout.stackSpacing`). */
private val COMMAND_STACK_SPACING = 8.dp

/** Hero band height (iOS `MonitorCommandGridLayout.heroHeight`). */
internal fun commandHeroHeightDp(portrait: Boolean): Float = if (portrait) 80f else 56f

/** Hero timecode size (iOS `MonitorCommandGridLayout.heroTimecodeSize`). */
internal fun commandHeroTimecodeSize(portrait: Boolean): Float = if (portrait) 60f else 46f

/** Landscape side column width: 27 percent of the dashboard, never under 160 (iOS `sideColumnWidth`). */
internal fun commandSideColumnWidthDp(dashboardWidthDp: Float): Float = maxOf(160f, dashboardWidthDp * 0.27f)
private val CommandGood = Color(0.18f, 0.78f, 0.42f)

/** Rows of the primary grid. */
internal fun commandGridRows(tileCount: Int, columns: Int = COMMAND_GRID_COLUMNS): Int {
    require(columns > 0) { "Command dashboard grid needs at least one column." }
    return (tileCount.coerceAtLeast(1) + columns - 1) / columns
}

/** Resolves one drag position to a clamped row-major grid slot. */
internal fun commandGridSlot(
    position: Offset,
    tileWidth: Float,
    rowHeight: Float,
    spacing: Float,
    columns: Int,
    itemCount: Int,
): Int {
    require(tileWidth > 0f && rowHeight > 0f) { "command grid cells must be positive" }
    require(spacing >= 0f && columns > 0 && itemCount > 0) {
        "command grid geometry must contain at least one item"
    }
    val column = floor(position.x / (tileWidth + spacing)).toInt().coerceIn(0, columns - 1)
    val row = floor(position.y / (rowHeight + spacing)).toInt().coerceAtLeast(0)
    return (row * columns + column).coerceIn(0, itemCount - 1)
}

/** Returns a tile only when a press lands inside its painted cell, never in a gutter. */
internal fun commandGridHitSlot(
    position: Offset,
    tileWidth: Float,
    rowHeight: Float,
    spacing: Float,
    columns: Int,
    itemCount: Int,
): Int? {
    require(tileWidth > 0f && rowHeight > 0f) { "command grid cells must be positive" }
    require(spacing >= 0f && columns > 0 && itemCount > 0) {
        "command grid geometry must contain at least one item"
    }
    if (position.x < 0f || position.y < 0f) return null
    val columnStride = tileWidth + spacing
    val rowStride = rowHeight + spacing
    val column = floor(position.x / columnStride).toInt()
    val row = floor(position.y / rowStride).toInt()
    if (column !in 0 until columns) return null
    if (position.x - column * columnStride >= tileWidth) return null
    if (position.y - row * rowStride >= rowHeight) return null
    return (row * columns + column).takeIf { it in 0 until itemCount }
}

/** The compact portrait grid height, leaving the sections below it a scrollable region. */
internal fun commandPortraitGridHeightDp(tileCount: Int): Int {
    val rows = commandGridRows(tileCount)
    return rows * COMMAND_PORTRAIT_GRID_ROW_HEIGHT_DP + (rows - 1) * COMMAND_GRID_SPACING_DP
}

/** Keeps full camera values visible inside the tight three-column portrait grid. */
internal fun commandTileValueSize(value: String): Float =
    when {
        value.length <= 8 -> 24f
        value.length <= 11 -> 20f
        else -> 16f
    }

/** Spoken label of the side column, from its section titles ("Image, Focus, and Audio controls."). */
internal fun commandSideDescription(titles: List<String>): String {
    val list = when (titles.size) {
        0, 1 -> titles.joinToString()
        2 -> titles.joinToString(" and ")
        else -> titles.dropLast(1).joinToString() + ", and " + titles.last()
    }
    return "$list controls. Swipe up to reveal more command controls."
}

/** The live surface's Sora face (tabular figures for values) without font padding. */
private fun commandStyle(size: Float, weight: FontWeight, mono: Boolean = false): TextStyle =
    (if (mono) MonitorTypography.readout(size, weight) else MonitorTypography.text(size, weight)).copy(
        lineHeight = size.sp,
        platformStyle = PlatformTextStyle(includeFontPadding = false),
    )

/** The live readout caption (`MonitorCameraValues` label): Sora semibold at the shared size and tracking. */
private val commandLabelStyle: TextStyle
    get() = commandStyle(MonitorLayoutPolicy.READOUT_LABEL_SIZE, FontWeight.SemiBold)
        .copy(letterSpacing = MonitorLayoutPolicy.READOUT_LABEL_TRACKING.sp)

/**
 * The command dashboard (SwiftUI twin: MonitorUI `MonitorCommandDashboard`): a reorderable grid of [tiles] and the
 * [sections] column; landscape adds the [health] strip ending in [healthTrailing]. [hero], the
 * header's status presentation, heads it with the record chip and hero timecode. Landscape stacks hero, health and grid on the left
 * beside a full-height side column; portrait pins the hero over the compact grid and the sections
 * in one scroller. Type is the live surface's readout captions and Sora tabular values. [pending] is true while any write
 * is in flight and [applying] names the request it carries. Long press and drag reorders a
 * tile with a [MonitorCommandTile.kind] through [onMoveTile]; a tap opens its request.
 */
@Composable
fun <K : Any, R : Any> MonitorCommandDashboard(
    tiles: List<MonitorCommandTile<K, R>>,
    sections: List<MonitorCommandSection<K, R>>,
    health: MonitorCommandHealth,
    portrait: Boolean,
    controlsEnabled: Boolean,
    pending: Boolean,
    applying: (R) -> Boolean,
    onOpenControl: (R) -> Unit,
    onMoveTile: (K, Int) -> Unit,
    hero: MonitorStatusPresentation? = null,
    healthTrailing: @Composable () -> Unit,
) {
    if (portrait) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(COMMAND_STACK_SPACING)) {
            hero?.let { CommandHeroBand(it, portrait = true) }
            Column(
                Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                MonitorCommandGrid(
                    tiles, controlsEnabled, pending, applying, onOpenControl, onMoveTile,
                    Modifier.fillMaxWidth().height(commandPortraitGridHeightDp(tiles.size).dp),
                )
                CommandSections(sections, controlsEnabled, pending, applying, onOpenControl, compact = false)
            }
        }
    } else {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val sideWidth = commandSideColumnWidthDp(maxWidth.value).dp
            // The baseline `.cmd-body` split: hero, health and grid on the left; the side column
            // runs the full height beside them.
            Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(
                    Modifier.weight(1f).fillMaxHeight(),
                    verticalArrangement = Arrangement.spacedBy(COMMAND_STACK_SPACING),
                ) {
                    hero?.let { CommandHeroBand(it, portrait = false) }
                    CommandHealthStrip(health, healthTrailing)
                    MonitorCommandGrid(
                        tiles, controlsEnabled, pending, applying, onOpenControl, onMoveTile,
                        Modifier.fillMaxWidth().weight(1f),
                    )
                }
                CommandSideColumn(
                    sections, controlsEnabled, pending, applying, onOpenControl,
                    Modifier.width(sideWidth).fillMaxHeight(),
                )
            }
        }
    }
}

/** The hero band: the record chip, then the hero timecode with its frame field in the accent. */
@Composable
private fun CommandHeroBand(hero: MonitorStatusPresentation, portrait: Boolean) {
    val description = hero.commandHeroAccessibilityValue
    Row(
        Modifier
            .fillMaxWidth()
            .height(commandHeroHeightDp(portrait).dp)
            .semantics(mergeDescendants = true) { contentDescription = "Timecode $description" }
            .testTag("monitor.command.hero"),
        horizontalArrangement = Arrangement.spacedBy(11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommandRecordChip(hero)
        hero.commandHeroTimecode?.let { (seconds, frames) ->
            // Fit both ways: the user's font scale can make even a short timecode taller than the band.
            BoxWithConstraints(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.CenterStart) {
                FitScale(maxWidth, maxHeight) {
                    Text(
                        buildAnnotatedString {
                            withStyle(SpanStyle(color = MonitorPalette.text)) { append(seconds) }
                            withStyle(SpanStyle(color = MonitorPalette.accent)) { append(frames) }
                        },
                        style = commandStyle(commandHeroTimecodeSize(portrait), FontWeight.Medium, mono = true),
                        maxLines = 1,
                        softWrap = false,
                    )
                }
            }
        }
    }
}

/** The header's record word: REC in the recording red with its lamp, STBY muted, unknown a dash. */
@Composable
private fun CommandRecordChip(hero: MonitorStatusPresentation) {
    val recording = hero.recording == true
    // iOS `monitorPulse(period: recPulseDuration)`: 1.6 s cycle down to a 0.25 floor while recording.
    val pulse = monitorPulsePhase(1600, enabled = recording)
    Row(
        Modifier
            .clip(CircleShape)
            .background(MonitorPalette.surface, CircleShape)
            .border(1.dp, if (recording) MonitorPalette.recording.copy(alpha = .6f) else MonitorPalette.border, CircleShape)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(8.dp)
                .graphicsLayer { alpha = if (hero.recording == null) .5f else 1f - .75f * pulse }
                .background(if (recording) MonitorPalette.recording else MonitorDesign.faint, CircleShape),
        )
        Text(
            hero.recordingLabel,
            style = commandStyle(11f, FontWeight.SemiBold).copy(letterSpacing = MonitorLayoutPolicy.READOUT_LABEL_TRACKING.sp),
            color = if (recording) MonitorPalette.recording else MonitorPalette.muted,
            maxLines = 1,
        )
    }
}

/** Temp / Storage / Camera / Lens readouts and the host's trailing chip (iOS `CommandHealthStrip`). */
@Composable
private fun CommandHealthStrip(health: MonitorCommandHealth, trailing: @Composable () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(CommandShape)
            .background(MonitorPalette.surface, CommandShape)
            .border(1.dp, MonitorPalette.border, CommandShape)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CommandStatusBlock(
            "Temp",
            health.temperature,
            Modifier.weight(0.7f, fill = false).widthIn(min = 52.dp, max = 148.dp),
            good = health.temperatureOk,
        )
        CommandStatusBlock("Storage", health.storage, Modifier.weight(1.1f).widthIn(min = 52.dp, max = 148.dp))
        CommandStatusBlock("Camera", health.camera, Modifier.weight(1f).widthIn(min = 52.dp, max = 148.dp))
        CommandStatusBlock("Lens", health.lens, Modifier.weight(1.25f).widthIn(min = 52.dp, max = 148.dp))
        // The trailing chip keeps its natural size (iOS fixedSize + layoutPriority).
        trailing()
    }
}

@Composable
private fun CommandStatusBlock(label: String, value: String, modifier: Modifier = Modifier, good: Boolean = false) {
    Column(
        modifier.semantics { contentDescription = "$label $value" },
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            label.uppercase(),
            style = commandLabelStyle,
            color = MonitorPalette.muted,
            maxLines = 1,
        )
        Text(
            value,
            // iOS: 12 medium Sora tabular, shrinking to fit (`minimumScaleFactor(0.55)`).
            style = commandStyle(12f, FontWeight.Medium, mono = true),
            color = if (good) CommandGood else MonitorPalette.text,
            maxLines = 1,
            autoSize = TextAutoSize.StepBased(6.6.sp, 12.sp, 0.5.sp),
            overflow = TextOverflow.Clip,
        )
    }
}

/** The three-column primary grid: tap opens a tile's request, long press and drag reorders it. */
@Composable
internal fun <K : Any, R : Any> MonitorCommandGrid(
    tiles: List<MonitorCommandTile<K, R>>,
    controlsEnabled: Boolean,
    pending: Boolean,
    applying: (R) -> Boolean,
    onOpenControl: (R) -> Unit,
    onMoveTile: (K, Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val columns = COMMAND_GRID_COLUMNS
    val spacing = COMMAND_GRID_SPACING_DP.dp
    val rows = commandGridRows(tiles.size, columns)
    val latestTiles by rememberUpdatedState(tiles)
    val latestMoveTile by rememberUpdatedState(onMoveTile)
    val latestOpenControl by rememberUpdatedState(onOpenControl)
    var draggingKind by remember { mutableStateOf<K?>(null) }
    var dragPosition by remember { mutableStateOf(Offset.Zero) }
    var suppressCameraClicksUntil by remember { mutableLongStateOf(0L) }
    val density = LocalDensity.current
    BoxWithConstraints(modifier.clipToBounds()) {
        // iOS MonitorCommandGrid: max(44, (height - spacing * (rows-1)) / rows)
        val rowHeight = maxOf(44.dp, (maxHeight - spacing * (rows - 1)) / rows)
        val spacingPx = with(density) { spacing.toPx() }
        val tileWidth = (maxWidth - spacing * (columns - 1)) / columns
        val tileWidthPx = with(density) { tileWidth.toPx() }
        val rowHeightPx = with(density) { rowHeight.toPx() }
        val viewportWidthPx = constraints.maxWidth.toFloat()
        val viewportHeightPx = constraints.maxHeight.toFloat()
        Box(
            Modifier.fillMaxSize()
                .pointerInput(tileWidthPx, rowHeightPx, spacingPx, columns) {
                    detectDragGesturesAfterLongPress(
                        onDragStart = { start ->
                            val current = latestTiles
                            if (current.isNotEmpty()) {
                                val index =
                                    commandGridHitSlot(start, tileWidthPx, rowHeightPx, spacingPx, columns, current.size)
                                index?.let(current::getOrNull)?.kind?.let { kind ->
                                    suppressCameraClicksUntil = Long.MAX_VALUE
                                    draggingKind = kind
                                    dragPosition = start
                                }
                            }
                        },
                        onDrag = { change, _ ->
                            val kind = draggingKind
                            if (kind != null) {
                                change.consume()
                                dragPosition = change.position
                                val current = latestTiles
                                if (current.isNotEmpty()) {
                                    val target =
                                        commandGridSlot(
                                            change.position, tileWidthPx, rowHeightPx, spacingPx, columns, current.size,
                                        )
                                    if (current.indexOfFirst { it.kind == kind } != target) {
                                        latestMoveTile(kind, target)
                                    }
                                }
                            }
                        },
                        onDragEnd = {
                            if (draggingKind != null) {
                                suppressCameraClicksUntil =
                                    SystemClock.uptimeMillis() + COMMAND_REORDER_CLICK_SUPPRESSION_MS
                            }
                            draggingKind = null
                        },
                        onDragCancel = {
                            if (draggingKind != null) {
                                suppressCameraClicksUntil =
                                    SystemClock.uptimeMillis() + COMMAND_REORDER_CLICK_SUPPRESSION_MS
                            }
                            draggingKind = null
                        },
                    )
                },
        ) {
            tiles.forEachIndexed { index, tile ->
                val kind = tile.kind
                key(kind ?: "${tile.title}-$index") {
                    val dragging = kind != null && kind == draggingKind
                    val slotX = (index % columns) * (tileWidthPx + spacingPx)
                    val slotY = (index / columns) * (rowHeightPx + spacingPx)
                    val offset =
                        if (dragging) {
                            IntOffset(
                                (dragPosition.x - tileWidthPx / 2f)
                                    .coerceIn(0f, (viewportWidthPx - tileWidthPx).coerceAtLeast(0f))
                                    .roundToInt(),
                                (dragPosition.y - rowHeightPx / 2f)
                                    .coerceIn(0f, (viewportHeightPx - rowHeightPx).coerceAtLeast(0f))
                                    .roundToInt(),
                            )
                        } else {
                            IntOffset(slotX.roundToInt(), slotY.roundToInt())
                        }
                    CommandTile(
                        tile = tile,
                        index = index,
                        tileCount = tiles.size,
                        controlsEnabled = controlsEnabled,
                        pending = pending,
                        applying = applying,
                        onOpenControl = { request ->
                            if (SystemClock.uptimeMillis() >= suppressCameraClicksUntil) {
                                latestOpenControl(request)
                            }
                        },
                        onMoveTo = { target -> kind?.let { latestMoveTile(it, target) } },
                        modifier =
                            Modifier.offset { offset }
                                .width(tileWidth)
                                .height(rowHeight)
                                // iOS: scaleEffect(1.06) + shadow(radius: 16, y: 8) while dragging.
                                .graphicsLayer {
                                    scaleX = if (dragging) 1.06f else 1f
                                    scaleY = if (dragging) 1.06f else 1f
                                    shadowElevation = if (dragging) 16.dp.toPx() else 0f
                                    shape = CommandShape
                                    clip = true
                                }
                                .zIndex(if (dragging) 1f else 0f),
                    )
                }
            }
        }
    }
}

/** One grid value with direct drag and accessibility reorder actions. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun <K : Any, R : Any> CommandTile(
    tile: MonitorCommandTile<K, R>,
    index: Int,
    tileCount: Int,
    controlsEnabled: Boolean,
    pending: Boolean,
    applying: (R) -> Boolean,
    onOpenControl: (R) -> Unit,
    onMoveTo: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val request = tile.request
    val applyingThisControl = request != null && pending && applying(request)
    // Stay tappable while another control writes: applies coalesce.
    val controlEnabled = request != null && controlsEnabled
    // Layout is app-local, so read-only values stay reorderable without implying a write path.
    val canMove = tile.kind != null
    val interactive = controlEnabled || canMove
    val reorderActions =
        buildList {
            if (canMove && index > 0) {
                add(CustomAccessibilityAction("Move ${tile.title} earlier") { onMoveTo(index - 1); true })
            }
            if (canMove && index < tileCount - 1) {
                add(CustomAccessibilityAction("Move ${tile.title} later") { onMoveTo(index + 1); true })
            }
        }
    val reorderHint = if (canMove) " Long press and drag to reorder." else ""
    val description =
        buildString {
            append("${tile.title}: ${tile.value}")
            when {
                applyingThisControl -> append(". Applying change.")
                pending -> append(". Another control is being applied.")
                request == null ->
                    append(". ${tile.unavailableReason ?: "Read-only."}$reorderHint")
                !controlsEnabled -> append(". Controls are locked.$reorderHint")
                else -> append(
                    if (canMove) ". Double tap to change; long press and drag to reorder."
                    else ". Double tap to change.",
                )
            }
        }
    // iOS CommandTile: pad h12/v8, readout caption title, value 24 medium Sora tabular, corner radius 12.
    Column(
        modifier
            .clip(CommandShape)
            .background(MonitorPalette.surface, CommandShape)
            .border(1.dp, MonitorPalette.border, CommandShape)
            .semantics(mergeDescendants = true) {
                contentDescription = description
                customActions = reorderActions
                if (!interactive) disabled()
            }
            .combinedClickable(
                enabled = interactive,
                onClickLabel = if (controlEnabled) "Change ${tile.title}" else null,
                onClick = { request?.takeIf { controlEnabled }?.let(onOpenControl) },
            )
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            tile.title.uppercase(),
            // iOS CommandTile title: the readout caption, shrinking to fit (`minimumScaleFactor(0.64)`).
            style = commandLabelStyle,
            color = MonitorPalette.muted,
            maxLines = 1,
            autoSize = TextAutoSize.StepBased(5.8.sp, 9.sp, 0.2.sp),
            overflow = TextOverflow.Clip,
        )
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            FitScale(maxWidth) {
                Text(
                    tile.value,
                    style = commandStyle(commandTileValueSize(tile.value), FontWeight.Medium, mono = true),
                    color = if (controlEnabled) MonitorPalette.text else MonitorPalette.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Clip,
                )
            }
        }
    }
}

/** The scale that fits a [width] x [height] child inside [maxWidth] x [maxHeight]; never above 1. */
internal fun commandFitScale(width: Float, height: Float, maxWidth: Float, maxHeight: Float): Float =
    minOf(1f, if (width > 0f) maxWidth / width else 1f, if (height > 0f) maxHeight / height else 1f)
        .coerceAtLeast(0f)

/**
 * Measures its child unbounded and scales it down (top-start anchored) to fit [maxWidth] and
 * [maxHeight], the Compose analog of iOS `minimumScaleFactor`.
 */
@Composable
private fun FitScale(maxWidth: Dp, maxHeight: Dp = Dp.Infinity, content: @Composable () -> Unit) {
    Layout(content) { measurables, _ ->
        val placeable = measurables.first().measure(Constraints())
        val heightPx = if (maxHeight == Dp.Infinity) Float.POSITIVE_INFINITY else maxHeight.toPx()
        val scale = commandFitScale(
            placeable.width.toFloat(), placeable.height.toFloat(), maxWidth.toPx(), heightPx,
        )
        layout((placeable.width * scale).toInt(), (placeable.height * scale).toInt()) {
            placeable.placeWithLayer(0, 0) {
                scaleX = scale
                scaleY = scale
                transformOrigin = TransformOrigin(0f, 0f)
            }
        }
    }
}

/** The landscape side column: the sections in a scroller that says when more wait below. */
@Composable
private fun <K : Any, R : Any> CommandSideColumn(
    sections: List<MonitorCommandSection<K, R>>,
    controlsEnabled: Boolean,
    pending: Boolean,
    applying: (R) -> Boolean,
    onOpenControl: (R) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scrollState = rememberScrollState()
    val description = commandSideDescription(sections.map { it.title })
    Box(modifier.clipToBounds()) {
        Box(
            Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .semantics { contentDescription = description },
        ) {
            CommandSections(
                sections, controlsEnabled, pending, applying, onOpenControl, compact = true,
                Modifier.fillMaxWidth().padding(bottom = 8.dp),
            )
        }
        if (scrollState.canScrollForward) {
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .height(44.dp)
                    .background(Brush.verticalGradient(listOf(Color.Transparent, MonitorPalette.backgroundDeep))),
            )
            Text(
                "MORE ⌄",
                style = commandLabelStyle,
                color = MonitorPalette.muted,
                modifier =
                    Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 3.dp)
                        .semantics { contentDescription = "More command controls below. Swipe up to reveal them." },
            )
        }
    }
}

/** The section stack (iOS CommandSideColumn), shared by the side column and portrait. */
@Composable
private fun <K : Any, R : Any> CommandSections(
    sections: List<MonitorCommandSection<K, R>>,
    controlsEnabled: Boolean,
    pending: Boolean,
    applying: (R) -> Boolean,
    onOpenControl: (R) -> Unit,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    // iOS CommandSections VStack spacing: 4 between sections; section title the readout caption,
    // rows VStack spacing 5, row HStack spacing 6.
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        sections.forEach { section ->
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    section.title.uppercase(),
                    style = commandLabelStyle,
                    maxLines = 1,
                    color = MonitorPalette.faint,
                    modifier = Modifier.padding(start = 2.dp),
                )
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    // iOS CommandSections: pairs, a leftover cell spans the row (prototype `.span2`).
                    section.cells.chunked(2).forEach { row ->
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            row.forEach { cell ->
                                CommandSmallTile(
                                    cell, controlsEnabled, pending, applying, onOpenControl, compact,
                                    Modifier.weight(1f),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun <K : Any, R : Any> CommandSmallTile(
    cell: MonitorCommandTile<K, R>,
    controlsEnabled: Boolean,
    pending: Boolean,
    applying: (R) -> Boolean,
    onOpenControl: (R) -> Unit,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    val request = cell.request
    val applyingThisControl = request != null && pending && applying(request)
    val enabled = request != null && controlsEnabled
    val description =
        buildString {
            append("${cell.title}: ${cell.value}")
            when {
                applyingThisControl -> append(". Applying change.")
                pending -> append(". Another control is being applied.")
                request == null -> append(". ${cell.unavailableReason ?: "Read-only."}")
                !controlsEnabled -> append(". Controls are locked.")
                else -> append(". Double tap to change.")
            }
        }
    // iOS CommandSmallTile: minHeight 42, pad h10/v6, caption title muted, value 15 medium Sora tabular.
    val valueColor =
        when {
            cell.amber -> MonitorPalette.accent
            cell.muted -> MonitorPalette.faint
            enabled -> MonitorPalette.text
            else -> MonitorPalette.muted
        }
    Column(
        modifier
            .heightIn(min = if (compact) COMMAND_SIDE_TILE_MIN_HEIGHT else COMMAND_PORTRAIT_SIDE_TILE_HEIGHT)
            .clip(CommandShape)
            .background(MonitorPalette.surface, CommandShape)
            .border(1.dp, MonitorPalette.border, CommandShape)
            .semantics(mergeDescendants = true) {
                contentDescription = description
                if (!enabled) disabled()
            }
            .combinedClickable(
                enabled = enabled,
                onClickLabel = "Change ${cell.title}",
                onClick = { request?.let(onOpenControl) },
            )
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        // Both shrink to fit rather than clip, matching iOS's 0.66 / 0.55 minimum scale factors.
        Text(
            cell.title.uppercase(),
            style = commandLabelStyle,
            color = MonitorPalette.muted,
            maxLines = 1,
            autoSize = TextAutoSize.StepBased(5.9.sp, 9.sp, 0.2.sp),
            overflow = TextOverflow.Clip,
        )
        Text(
            cell.value,
            style = commandStyle(15f, FontWeight.Medium, mono = true),
            color = valueColor,
            maxLines = 1,
            autoSize = TextAutoSize.StepBased(8.2.sp, 15.sp, 0.5.sp),
            overflow = TextOverflow.Clip,
        )
    }
}
