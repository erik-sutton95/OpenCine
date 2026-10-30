package com.opencapture.monitorui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.layoutId
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

/** [annotation] is spoken after the value; iOS shows [valueIcon] before and [badgeIcon] after it. */
@Immutable
data class MonitorValue(val id: String, val label: String, val value: String,
    val selected: Boolean = false, val annotation: String? = null,
    val valueIcon: MonitorIcon? = null, val badgeIcon: MonitorIcon? = null, val enabled: Boolean = true,
    /** The camera owns or locks this value: drawn muted (iOS `MonitorOperatorLiveReadoutStyle`). */
    val dimmed: Boolean = false)

/** Opacity of a camera-owned value; twin of Swift `MonitorOperatorLiveReadoutStyle.dimmedOpacity`. */
const val MONITOR_DIMMED_VALUE_ALPHA: Float = 0.55f

/** Camera values are ready-to-display data; adapters retain interpretation and writes. */
@Composable
fun MonitorCameraValues(values: List<MonitorValue>, enabled: Boolean, portrait: Boolean,
    modifier: Modifier = Modifier, itemModifier: (String) -> Modifier = { Modifier },
    quickControl: (String) -> MonitorQuickControl? = { null },
    onQuickCommit: (String, MonitorQuickControl, String) -> Unit = { _, _, _ -> },
    quickPreview: (@Composable (String, MonitorQuickPreview, Float) -> Unit)? = null,
    onQuickActiveChange: (Boolean) -> Unit = {},
    quickBottomClearanceDp: Float = 0f,
    columns: Int? = null,
    gestureOwner: MonitorQuickGestureOwner? = null,
    onHold: (String) -> (() -> Unit)? = { null },
    /**
     * The status row's trailing corner ([MonitorStatusCorner]): one trailing row at natural
     * widths, narrowed toward each whole caption only when short, with previews from the top.
     */
    corner: Boolean = false,
    onOpen: (String) -> Unit) {
    val owner = gestureOwner ?: remember { MonitorQuickGestureOwner() }
    val notifyQuickActive by rememberUpdatedState(onQuickActiveChange)
    LaunchedEffect(owner.active) { notifyQuickActive(owner.active != null) }
    DisposableEffect(Unit) { onDispose { notifyQuickActive(false) } }
    val density = LocalDensity.current
    val configuration = LocalConfiguration.current
    val tablet = minOf(configuration.screenWidthDp, configuration.screenHeightDp) >= 600
    val measurer = rememberTextMeasurer()
    val valueSize = MonitorLayoutPolicy.readoutValueSize(tablet)
    val valueStyle = MonitorTypography.readout(valueSize, FontWeight.Medium)
        .copy(lineHeight = valueSize.sp)
    val labelStyle = MonitorTypography.text(MonitorLayoutPolicy.READOUT_LABEL_SIZE, FontWeight.SemiBold)
        .copy(lineHeight = 10.sp, letterSpacing = MonitorLayoutPolicy.READOUT_LABEL_TRACKING.sp)
    val measured = values.map { item ->
        val valueWidth = with(density) { measurer.measure(item.value, valueStyle, maxLines = 1).size.width.toDp().value }
        val labelWidth = with(density) { measurer.measure(item.label, labelStyle, maxLines = 1).size.width.toDp().value }
        val icons = (if (item.valueIcon != null) 20f else 0f) + (if (item.badgeIcon != null) 14f else 0f)
        Triple(valueWidth + icons, labelWidth, icons)
    }
    val intrinsic = measured.map { (value, label, _) -> maxOf(value, label) + 8f }
    BoxWithConstraints(if (corner) modifier else modifier.fillMaxWidth()) {
        if (corner) {
            val widths = MonitorStatusCorner.widths(intrinsic.map { maxOf(44f, it) },
                measured.map { (_, label, _) -> label + 8f }, maxWidth.value)
            Row(horizontalArrangement = Arrangement.spacedBy(MonitorStatusCorner.TILE_SPACING.dp),
                verticalAlignment = Alignment.CenterVertically) {
                values.forEachIndexed { index, item ->
                    // A narrowed tile scales its value (iOS minimumScaleFactor 0.65), never its caption.
                    val room = widths[index] - 8f - measured[index].third
                    val scale = (room / measured[index].first.coerceAtLeast(1f)).coerceIn(0.65f, 1f)
                    MonitorCameraValueTile(item, Modifier.width(widths[index].dp).heightIn(min = 34.dp),
                        valueStyle.copy(fontSize = valueStyle.fontSize * scale), labelStyle, enabled, owner,
                        itemModifier, quickControl, onQuickCommit, quickPreview, notifyQuickActive,
                        quickBottomClearanceDp, onHold, onOpen, fromTop = true)
                }
            }
            return@BoxWithConstraints
        }
        val rowWidth = maxWidth
        val columnCount = columns?.coerceIn(1, values.size.coerceAtLeast(1))
            ?: MonitorLayoutPolicy.valueColumns(values.size, portrait, tablet)
        val grid = portrait && !tablet
        val gap = if (grid) 14f else ((maxWidth.value - intrinsic.sum()) / (values.size - 1).coerceAtLeast(1)).coerceIn(16f, 34f)
        Column(verticalArrangement = Arrangement.spacedBy(if (grid) 10.dp else 8.dp)) {
            values.chunked(columnCount).forEachIndexed { rowIndex, row ->
                Row(Modifier.then(if (grid) Modifier.fillMaxWidth() else Modifier.horizontalScroll(rememberScrollState()).widthIn(min = rowWidth)),
                    horizontalArrangement = Arrangement.spacedBy(gap.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.Bottom) {
                    row.forEachIndexed { column, item ->
                        MonitorCameraValueTile(item,
                            Modifier.then(if (grid) Modifier.weight(1f) else Modifier.width(intrinsic[rowIndex * columnCount + column].dp))
                                .heightIn(min = if (grid) 32.dp else 34.dp),
                            valueStyle, labelStyle, enabled, owner, itemModifier, quickControl, onQuickCommit,
                            quickPreview, notifyQuickActive, quickBottomClearanceDp, onHold, onOpen, fromTop = false)
                    }
                    if (grid) repeat(columnCount - row.size) { Box(Modifier.weight(1f)) }
                }
            }
        }
    }
}

/** One camera value tile: the strip's and the status corner's, with the shared readout gesture. */
@Composable
private fun MonitorCameraValueTile(item: MonitorValue, sizing: Modifier, valueStyle: TextStyle, labelStyle: TextStyle,
    enabled: Boolean, owner: MonitorQuickGestureOwner, itemModifier: (String) -> Modifier,
    quickControl: (String) -> MonitorQuickControl?, onQuickCommit: (String, MonitorQuickControl, String) -> Unit,
    quickPreview: (@Composable (String, MonitorQuickPreview, Float) -> Unit)?, notifyQuickActive: (Boolean) -> Unit,
    quickBottomClearanceDp: Float, onHold: (String) -> (() -> Unit)?, onOpen: (String) -> Unit, fromTop: Boolean) {
    val renderPreview: (@Composable (MonitorQuickPreview, Float) -> Unit)? =
        if (quickPreview == null) null else { preview, maxHeight -> quickPreview(item.id, preview, maxHeight) }
    Column(sizing
        .then(itemModifier(item.id))
        .background(if (item.selected) MonitorPalette.accent.copy(alpha = .14f) else Color.Transparent, RoundedCornerShape(8.dp))
        .monitorReadoutGesture(quickControl(item.id), enabled && item.enabled && (owner.owner == null || owner.owner == item.id),
            { onOpen(item.id) }, { source, value -> onQuickCommit(item.id, source, value) },
            quickBottomClearanceDp, owner, item.id,
            renderPreview, fromTop = fromTop, onPreviewBegin = { notifyQuickActive(true) }, onHold = onHold(item.id))
        .semantics {
            contentDescription = "${item.label} ${item.value}${item.annotation?.let { ", $it" }.orEmpty()}"
            if (!item.enabled) disabled()
        }
        .monitorReadoutShadow()
        .padding(horizontal = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically)) {
        val valueTint = if (item.selected) MonitorPalette.accent else MonitorPalette.text
        Row(Modifier.alpha(if (item.dimmed) MONITOR_DIMMED_VALUE_ALPHA else 1f),
            horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
            item.valueIcon?.let { MonitorIcon(it, null, Modifier.size(17.dp), valueTint) }
            Text(item.value, color = valueTint, style = valueStyle, maxLines = 1, softWrap = false)
            item.badgeIcon?.let { MonitorIcon(it, null, Modifier.size(11.dp), valueTint) }
        }
        Text(item.label, color = if (item.selected) MonitorPalette.accent else MonitorPalette.muted,
            style = labelStyle, maxLines = 1)
    }
}

/** Native icon artwork is an adapter slot, so the engine has no brand/icon dependency. */
@Composable
fun MonitorAuxCircleButton(modifier: Modifier = Modifier, glyph: @Composable (Color) -> Unit) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Box(Modifier.fillMaxSize(0.54f), contentAlignment = Alignment.Center) {
            glyph(MonitorPalette.text.copy(alpha = 0.86f))
        }
    }
}

@Composable
fun MonitorActionButton(label: String, modifier: Modifier = Modifier, selected: Boolean = false,
    enabled: Boolean = true, side: Dp = 44.dp, onClick: () -> Unit, glyph: @Composable (Color) -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    val tint = if (selected) MonitorPalette.accent else MonitorPalette.text
    Box(modifier.size(side).clip(shape)
        .background(if (selected) MonitorPalette.accent.copy(alpha = .14f) else MonitorPalette.tile)
        .border(1.dp, if (selected) MonitorPalette.accent.copy(alpha = .3f) else Color.Transparent, shape)
        .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
        .semantics { contentDescription = label }, contentAlignment = Alignment.Center) { glyph(tint) }
}

/** Navigation and detail are composed once; rotation only remeasures the slots. */
object MonitorPageLayoutPolicy {
    const val NAV = "nav"
    const val BODY = "body"
    const val LANDSCAPE_NAV_WIDTH = 170f
    const val GAP = 10f

    data class Slots(
        val navX: Float, val navY: Float, val navW: Float, val navH: Float,
        val bodyX: Float, val bodyY: Float, val bodyW: Float, val bodyH: Float,
    )

    fun portrait(width: Float, height: Float): Boolean = height > width

    /** Geometry only. Compose identity comes from the single Layout content slot. */
    fun slots(
        width: Float,
        height: Float,
        portraitNavHeight: Float = 56f,
        portrait: Boolean = MonitorPageLayoutPolicy.portrait(width, height),
        navigationWidth: Float = LANDSCAPE_NAV_WIDTH,
    ): Slots {
        val w = width.coerceAtLeast(0f)
        val h = height.coerceAtLeast(0f)
        return if (portrait) {
            val navH = portraitNavHeight.coerceIn(0f, h)
            val bodyH = (h - navH - GAP).coerceAtLeast(0f)
            Slots(0f, 0f, w, navH, 0f, navH + GAP, w, bodyH)
        } else {
            val navW = navigationWidth.coerceAtMost(w)
            val bodyW = (w - navW - GAP).coerceAtLeast(0f)
            Slots(0f, 0f, navW, h, navW + GAP, 0f, bodyW, h)
        }
    }
}

/** Same type scale as the Your cameras header. */
@Composable
fun MonitorPageHeading(title: String, kicker: String) {
    val config = LocalConfiguration.current
    val tablet = minOf(config.screenWidthDp, config.screenHeightDp) >= 600
    Column(Modifier.fillMaxWidth().heightIn(min = 34.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        // iOS `MonitorPageHeading` uppercases the brand line.
        Text(if (MonitorIosParity.enabled) kicker.uppercase() else kicker, color = MonitorPalette.accent,
            style = MonitorTypography.text(8.5f, FontWeight.Bold).copy(letterSpacing = 1.7.sp), maxLines = 1)
        Text(title, color = MonitorPalette.text,
            style = MonitorTypography.text(MonitorLayoutPolicy.cameraPageTitleSize(tablet), FontWeight.SemiBold)
                .copy(letterSpacing = (-0.2).sp),
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/**
 * A page frame (Swift twin: `MonitorPage`). The optional [back] control sits beside the heading in
 * portrait and in its own column before the navigation card in landscape, as on iOS.
 */
@Composable
fun MonitorPageScaffold(
    modifier: Modifier = Modifier,
    navigationWidth: Float = MonitorPageLayoutPolicy.LANDSCAPE_NAV_WIDTH,
    heading: (@Composable () -> Unit)? = null,
    back: (@Composable () -> Unit)? = null,
    navigation: @Composable (portrait: Boolean) -> Unit,
    content: @Composable () -> Unit,
) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val portrait = MonitorPageLayoutPolicy.portrait(maxWidth.value, maxHeight.value)
        val density = LocalDensity.current
        val landscapeNav = with(density) { navigationWidth.dp.toPx().roundToInt() }
        Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (!portrait && back != null) back()
        Layout(
            modifier = Modifier.weight(1f).fillMaxHeight(),
            content = {
                Box(
                    Modifier.layoutId(MonitorPageLayoutPolicy.NAV)
                        .background(MonitorPalette.surface, RoundedCornerShape(12.dp))
                        .border(1.dp, MonitorPalette.border, RoundedCornerShape(12.dp))
                        .padding(10.dp),
                ) {
                    Column(
                        if (portrait) Modifier.fillMaxWidth() else Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.spacedBy(9.dp),
                    ) {
                        if (portrait && back != null) {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                                back()
                                if (heading != null) Box(Modifier.weight(1f)) { heading() }
                            }
                        } else if (heading != null) {
                            Box(Modifier.fillMaxWidth()) { heading() }
                        }
                        Box(
                            if (portrait) Modifier.fillMaxWidth()
                            else Modifier.weight(1f).fillMaxWidth(),
                        ) { navigation(portrait) }
                    }
                }
                Box(Modifier.layoutId(MonitorPageLayoutPolicy.BODY)) { content() }
            },
        ) { measurables, constraints ->
            val nav = measurables.first { it.layoutId == MonitorPageLayoutPolicy.NAV }
            val body = measurables.first { it.layoutId == MonitorPageLayoutPolicy.BODY }
            val navWidth = if (portrait) constraints.maxWidth else landscapeNav.coerceAtMost(constraints.maxWidth)
            val navPlaceable = nav.measure(Constraints(
                minWidth = navWidth, maxWidth = navWidth,
                minHeight = if (portrait) 0 else constraints.maxHeight,
                maxHeight = constraints.maxHeight,
            ))
            val slots = MonitorPageLayoutPolicy.slots(
                constraints.maxWidth / density.density,
                constraints.maxHeight / density.density,
                navPlaceable.height / density.density,
                portrait = portrait,
                navigationWidth = navigationWidth,
            )
            fun pixels(points: Float) = (points * density.density).roundToInt()
            val bodyPlaceable = body.measure(Constraints.fixed(pixels(slots.bodyW), pixels(slots.bodyH)))
            layout(constraints.maxWidth, constraints.maxHeight) {
                navPlaceable.place(pixels(slots.navX), pixels(slots.navY))
                bodyPlaceable.place(pixels(slots.bodyX), pixels(slots.bodyY))
            }
        }
        }
    }
}

/** Catalog mechanics are common; item identity, cache state and actions stay in the adapter. */
@Composable
fun <T> MonitorCatalogGrid(items: List<T>, columns: Int, key: (T) -> Any,
    modifier: Modifier = Modifier, state: LazyGridState = rememberLazyGridState(),
    cell: @Composable (T) -> Unit) {
    LazyVerticalGrid(columns = GridCells.Fixed(columns.coerceAtLeast(1)), modifier = modifier.monitorScrollFade(state), state = state,
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp)) {
        items(items, key = key) { cell(it) }
    }
}

enum class MonitorThumbnailSize { SMALL, MEDIUM, LARGE }

fun monitorCatalogColumns(size: MonitorThumbnailSize, tablet: Boolean): Int = when (size) {
    MonitorThumbnailSize.SMALL -> if (tablet) 5 else 3
    MonitorThumbnailSize.MEDIUM -> if (tablet) 4 else 2
    MonitorThumbnailSize.LARGE -> if (tablet) 2 else 1
}

@Composable
fun MonitorSettingsCard(title: String? = null, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(MonitorPalette.surface)
        .padding(horizontal = 13.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(MonitorLayoutPolicy.SETTINGS_TITLE_CONTENT_GAP.dp)) {
        if (!title.isNullOrBlank()) Text(title.uppercase(), color = MonitorPalette.muted,
            style = MonitorTypography.text(9f, FontWeight.SemiBold).copy(letterSpacing = 1.2.sp))
        content()
    }
}

/** Inspector control group over the picture, independent of a tool taxonomy. */
@Composable
fun MonitorOptionGroup(content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
        .background(Color.White.copy(alpha = .035f))
        .border(1.dp, Color.White.copy(alpha = .06f), RoundedCornerShape(10.dp))
        .padding(horizontal = 12.dp)) { content() }
}

/** Quiet bottom handle shared by capture card presentations. */
@Composable
fun MonitorPanelGrabber() {
    Box(Modifier.fillMaxWidth().padding(top = 4.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(36.dp, 4.dp).background(Color.White.copy(alpha = .28f), RoundedCornerShape(2.dp)))
    }
}
