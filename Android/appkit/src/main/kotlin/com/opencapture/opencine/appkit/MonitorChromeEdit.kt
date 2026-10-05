package com.opencapture.opencine.appkit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.monitorChromeClickable
import com.opencapture.monitorui.monitorMaterial
import kotlin.math.max
import kotlin.math.min

private const val BADGE = 26f
private const val BADGE_GAP = 4f
private const val EDGE_INSET = 16f
private const val OVERHANG = 4f

/** The pill over the monitor while the operator edits [mode]'s visible chrome. */
@Composable
public fun MonitorChromeEditBanner(
    mode: MonitorDisplayMode,
    modifier: Modifier = Modifier,
    onDone: () -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    Row(
        modifier
            .monitorMaterial(MonitorMaterial.Expanded, RoundedCornerShape(50))
            .padding(start = 12.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        MonitorIcon(MonitorIcon.EYE, null, Modifier.size(11.dp), MonitorPalette.accent)
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text("Editing ${mode.title}", color = MonitorPalette.text, style = MonitorTypography.text(11.5f, FontWeight.SemiBold))
            Text("Tap an eye to show or hide it", color = MonitorPalette.muted, style = MonitorTypography.text(10f))
        }
        Box(
            Modifier
                .clip(RoundedCornerShape(50))
                .background(MonitorPalette.accent)
                .monitorChromeClickable(onClickFeedback = { haptics.selection() }, onClick = onDone)
                .padding(horizontal = 12.dp, vertical = 6.dp),
        ) {
            Text("Done", color = MonitorPalette.background, style = MonitorTypography.text(11.5f, FontWeight.Bold))
        }
    }
}

/** One eye badge per box, placed on a free corner or edge of its box inside the viewport. */
@Composable
public fun MonitorChromeEditBadgeLayer(
    boxes: List<Pair<MonitorDisplaySection, MonitorRect>>,
    viewportWidth: Float,
    viewportHeight: Float,
    visible: (MonitorDisplaySection) -> Boolean,
    onToggle: (MonitorDisplaySection) -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    val frames = badgeFrames(boxes, viewportWidth, viewportHeight)
    frames.forEach { (section, frame) ->
        val on = visible(section)
        Box(
            Modifier
                .offset(frame.x.dp, frame.y.dp)
                .size(BADGE.dp)
                .clip(CircleShape)
                .background(if (on) MonitorPalette.accent else Color.Black.copy(alpha = 0.9f))
                .border(1.dp, MonitorPalette.text.copy(alpha = 0.55f), CircleShape)
                .monitorChromeClickable(onClickFeedback = { haptics.selection() }, onClick = { onToggle(section) }),
            contentAlignment = Alignment.Center,
        ) {
            MonitorIcon(if (on) MonitorIcon.EYE else MonitorIcon.EYE_OFF, null, Modifier.size(11.dp),
                if (on) MonitorPalette.background else MonitorPalette.text)
        }
    }
}

/** Dashed outline on an editable module while editing; accent when shown, muted when hidden. */
public fun Modifier.monitorChromeEditStroke(editing: Boolean, visible: Boolean): Modifier {
    if (!editing) return this
    val color = if (visible) MonitorPalette.accent.copy(alpha = 0.75f) else MonitorPalette.muted.copy(alpha = 0.75f)
    return drawWithContent {
        drawContent()
        drawRoundRect(
            color = color,
            cornerRadius = CornerRadius(8.dp.toPx()),
            style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f))),
        )
    }
}

/** The editable boxes of [layout] whose section [mounts]; the lock box also while [uiLocked]. */
public fun monitorChromeEditBoxes(
    layout: LiveMonitorLayout,
    mounts: (MonitorDisplaySection) -> Boolean,
    uiLocked: Boolean,
    zoom: MonitorRect,
    stick: MonitorRect,
    statusChips: Map<MonitorDisplaySection, MonitorRect> = emptyMap(),
): List<Pair<MonitorDisplaySection, MonitorRect>> {
    val out = mutableListOf<Pair<MonitorDisplaySection, MonitorRect>>()
    fun add(section: MonitorDisplaySection, rect: MonitorRect) {
        if (!rect.isEmpty) out += section to rect
    }
    if (mounts(MonitorDisplaySection.STATUS_BAR)) add(MonitorDisplaySection.STATUS_BAR, layout.topDeck)
    for (section in TOP_STATUS_CHIPS) {
        if (mounts(section)) statusChips[section]?.let { add(section, it) }
    }
    if (mounts(MonitorDisplaySection.LOCK_BUTTON) || uiLocked) add(MonitorDisplaySection.LOCK_BUTTON, layout.lock)
    if (mounts(MonitorDisplaySection.BATTERIES)) add(MonitorDisplaySection.BATTERIES, layout.battery)
    if (mounts(MonitorDisplaySection.RAIL_SETTINGS)) add(MonitorDisplaySection.RAIL_SETTINGS, layout.settings)
    if (mounts(MonitorDisplaySection.RAIL_MEDIA)) add(MonitorDisplaySection.RAIL_MEDIA, layout.media)
    if (mounts(MonitorDisplaySection.RAIL_RECORD)) add(MonitorDisplaySection.RAIL_RECORD, layout.record)
    if (mounts(MonitorDisplaySection.TOOL_BAR)) add(MonitorDisplaySection.TOOL_BAR, layout.assist)
    if (mounts(MonitorDisplaySection.CAMERA_VALUES)) add(MonitorDisplaySection.CAMERA_VALUES, layout.capture)
    if (mounts(MonitorDisplaySection.ZOOM_CHIP)) add(MonitorDisplaySection.ZOOM_CHIP, zoom)
    if (mounts(MonitorDisplaySection.GIMBAL_STICK)) add(MonitorDisplaySection.GIMBAL_STICK, stick)
    return out
}

private val TOP_STATUS_CHIPS =
    listOf(
        MonitorDisplaySection.REC_READOUT,
        MonitorDisplaySection.TIMECODE,
        MonitorDisplaySection.FORMAT,
        MonitorDisplaySection.COLOR,
        MonitorDisplaySection.STORAGE,
        MonitorDisplaySection.FPS,
    )

private enum class BadgeAnchor {
    TOP_LEADING,
    TOP,
    TOP_TRAILING,
    LEADING,
    TRAILING,
    BOTTOM_LEADING,
    BOTTOM,
    BOTTOM_TRAILING,
    ;

    fun frame(box: MonitorRect): MonitorRect {
        val inner = BADGE - OVERHANG
        val midX = box.midX - BADGE / 2f
        val midY = box.midY - BADGE / 2f
        val x =
            when (this) {
                TOP_LEADING, LEADING, BOTTOM_LEADING -> box.minX - OVERHANG
                TOP, BOTTOM -> midX
                TOP_TRAILING, TRAILING, BOTTOM_TRAILING -> box.maxX - inner
            }
        val y =
            when (this) {
                TOP_LEADING, TOP, TOP_TRAILING -> box.minY - OVERHANG
                LEADING, TRAILING -> midY
                BOTTOM_LEADING, BOTTOM, BOTTOM_TRAILING -> box.maxY - inner
            }
        return MonitorRect(x, y, BADGE, BADGE)
    }
}

private fun badgeFrames(
    boxes: List<Pair<MonitorDisplaySection, MonitorRect>>,
    vw: Float,
    vh: Float,
): List<Pair<MonitorDisplaySection, MonitorRect>> {
    val playable =
        MonitorRect(
            min(EDGE_INSET, max(0f, vw - BADGE)),
            min(EDGE_INSET, max(0f, vh - BADGE)),
            max(BADGE, vw - 2f * EDGE_INSET),
            max(BADGE, vh - 2f * EDGE_INSET),
        )
    val placed = mutableListOf<MonitorRect>()
    val result = mutableListOf<Pair<MonitorDisplaySection, MonitorRect>>()
    for ((section, box) in boxes) {
        if (box.isEmpty) continue
        val preferTrailing = box.midX < vw / 2f
        val preferBottom = box.midY < vh / 2f
        val candidates =
            BadgeAnchor.entries
                .sortedBy { rank(it, preferTrailing, preferBottom) }
                .map { clampBadge(it.frame(box), playable) }
        val choice =
            candidates.firstOrNull { candidate ->
                placed.none { overlaps(it, candidate) }
            } ?: candidates.first()
        placed += choice
        result += section to choice
    }
    return result
}

private fun clampBadge(frame: MonitorRect, playable: MonitorRect): MonitorRect {
    val x = min(max(frame.minX, playable.minX), playable.maxX - frame.width)
    val y = min(max(frame.minY, playable.minY), playable.maxY - frame.height)
    return MonitorRect(x, y, frame.width, frame.height)
}

private fun overlaps(a: MonitorRect, b: MonitorRect): Boolean =
    a.minX < b.maxX + BADGE_GAP &&
        b.minX < a.maxX + BADGE_GAP &&
        a.minY < b.maxY + BADGE_GAP &&
        b.minY < a.maxY + BADGE_GAP

private fun rank(anchor: BadgeAnchor, preferTrailing: Boolean, preferBottom: Boolean): Int {
    val horizontal =
        when (anchor) {
            BadgeAnchor.TOP_TRAILING, BadgeAnchor.TRAILING, BadgeAnchor.BOTTOM_TRAILING ->
                if (preferTrailing) 0 else 2
            BadgeAnchor.TOP_LEADING, BadgeAnchor.LEADING, BadgeAnchor.BOTTOM_LEADING ->
                if (preferTrailing) 2 else 0
            BadgeAnchor.TOP, BadgeAnchor.BOTTOM -> 1
        }
    val vertical =
        when (anchor) {
            BadgeAnchor.BOTTOM_LEADING, BadgeAnchor.BOTTOM, BadgeAnchor.BOTTOM_TRAILING ->
                if (preferBottom) 0 else 2
            BadgeAnchor.TOP_LEADING, BadgeAnchor.TOP, BadgeAnchor.TOP_TRAILING ->
                if (preferBottom) 2 else 0
            BadgeAnchor.LEADING, BadgeAnchor.TRAILING -> 1
        }
    return horizontal + vertical
}
