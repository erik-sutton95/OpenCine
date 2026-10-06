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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
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

/**
 * What the chrome editor needs from an app (iOS `ChromeEditHost`): its own sections and DISP
 * modes, their names, which sections a mode offers, and the operator's per-mode choice.
 */
public interface ChromeEditHost<S, M> {
    /** Every section, in badge placement priority (containers before what nests in them). */
    public val chromeEditSections: List<S>
    public fun chromeSectionTitle(section: S): String
    /** The stable name in the badge's test tag. */
    public fun chromeSectionID(section: S): String
    public fun chromeModeTitle(mode: M): String
    public fun isChromeConfigurable(section: S, mode: M): Boolean
    public fun isChromeVisible(section: S, mode: M): Boolean
    public fun toggleChrome(section: S, mode: M)
    public fun endChromeEditing()
}

/**
 * Outlines [section] while [mode] is edited and offers it (dimmed when hidden) and reports its
 * drawn bounds, in root dp, for its eye badge. A no-op outside the editor.
 */
@Composable
public fun <S, M> Modifier.chromeEditable(
    host: ChromeEditHost<S, M>,
    section: S,
    mode: M?,
    onBounds: (S, MonitorRect) -> Unit,
): Modifier {
    if (mode == null || !host.isChromeConfigurable(section, mode)) return this
    val on = host.isChromeVisible(section, mode)
    val density = LocalDensity.current
    return this
        .onGloballyPositioned {
            val r = it.boundsInRoot()
            with(density) { onBounds(section, MonitorRect(r.left.toDp().value, r.top.toDp().value, r.width.toDp().value, r.height.toDp().value)) }
        }
        // Outside the alpha layer, so a hidden element's outline stays readable at 30%.
        .monitorChromeEditStroke(editing = true, visible = on)
        .alpha(if (on) 1f else 0.3f)
}

/** The eye badges over every measured section of [mode], in the host's placement order. */
@Composable
public fun <S, M> ChromeEditBadges(
    host: ChromeEditHost<S, M>,
    mode: M,
    boxes: Map<S, MonitorRect>,
    viewportWidth: Float,
    viewportHeight: Float,
    /** Hit area around each badge, in dp; the disc itself when smaller. */
    touchTarget: Float = MonitorChromeEditBadgeLayout.BADGE_SIZE,
) {
    MonitorChromeEditBadgeLayer(
        boxes = host.chromeEditSections.mapNotNull { section -> boxes[section]?.let { section to it } },
        viewportWidth = viewportWidth,
        viewportHeight = viewportHeight,
        visible = { host.isChromeVisible(it, mode) },
        onToggle = { host.toggleChrome(it, mode) },
        touchTarget = touchTarget,
        label = host::chromeSectionTitle,
        tag = { "monitor.chromeEdit.${host.chromeSectionID(it)}" },
    )
}

/** Names the mode being edited; Done ends editing. */
@Composable
public fun <S, M> ChromeEditDoneBanner(host: ChromeEditHost<S, M>, mode: M, modifier: Modifier = Modifier) {
    MonitorChromeEditBanner(host.chromeModeTitle(mode), modifier, host::endChromeEditing)
}

/** The pill over the monitor while the operator edits [mode]'s visible chrome. */
@Composable
public fun MonitorChromeEditBanner(
    mode: MonitorDisplayMode,
    modifier: Modifier = Modifier,
    onDone: () -> Unit,
) {
    MonitorChromeEditBanner(mode.title, modifier, onDone)
}

/** The pill over the monitor while the operator edits the chrome of the mode named [modeTitle]. */
@Composable
public fun MonitorChromeEditBanner(
    modeTitle: String,
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
            Text("Editing $modeTitle", color = MonitorPalette.text, style = MonitorTypography.text(11.5f, FontWeight.SemiBold))
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

/**
 * One eye badge per box, placed on a free corner or edge of its box inside the viewport. [label]
 * and [tag] name each badge for accessibility and tests; [touchTarget] (dp) grows the hit area
 * past the disc.
 */
@Composable
public fun <K> MonitorChromeEditBadgeLayer(
    boxes: List<Pair<K, MonitorRect>>,
    viewportWidth: Float,
    viewportHeight: Float,
    visible: (K) -> Boolean,
    onToggle: (K) -> Unit,
    touchTarget: Float = BADGE,
    label: ((K) -> String)? = null,
    tag: ((K) -> String)? = null,
) {
    val haptics = LocalOperatorHaptics.current
    val frames = MonitorChromeEditBadgeLayout.badgeFrames(boxes, viewportWidth, viewportHeight)
    val pad = max(0f, touchTarget - BADGE) / 2f
    frames.forEach { (section, frame) ->
        val on = visible(section)
        val disc =
            Modifier
                .size(BADGE.dp)
                .clip(CircleShape)
                .background(if (on) MonitorPalette.accent else Color.Black.copy(alpha = 0.9f))
                .border(1.dp, MonitorPalette.text.copy(alpha = 0.55f), CircleShape)
        val click =
            Modifier
                .monitorChromeClickable(onClickFeedback = { haptics.selection() }, onClick = { onToggle(section) })
                .then(label?.let { name -> Modifier.semantics { contentDescription = name(section); stateDescription = if (on) "Shown" else "Hidden" } } ?: Modifier)
                .then(tag?.let { Modifier.testTag(it(section)) } ?: Modifier)
        val eye = @Composable {
            MonitorIcon(if (on) MonitorIcon.EYE else MonitorIcon.EYE_OFF, null, Modifier.size(11.dp),
                if (on) MonitorPalette.background else MonitorPalette.text)
        }
        if (pad == 0f) {
            Box(Modifier.offset(frame.x.dp, frame.y.dp).then(disc).then(click), contentAlignment = Alignment.Center) { eye() }
        } else {
            // A transparent square centred on the disc carries the tap.
            Box(Modifier.offset((frame.x - pad).dp, (frame.y - pad).dp).size(touchTarget.dp).then(click), contentAlignment = Alignment.Center) {
                Box(disc, contentAlignment = Alignment.Center) { eye() }
            }
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

/** Where the Edit view puts each eye badge (iOS `MonitorChromeEditBadgeLayout`). */
public object MonitorChromeEditBadgeLayout {
    public const val BADGE_SIZE: Float = BADGE

    /**
     * Badge frames for [boxes] in the same space; [boxes] order is the placement priority and
     * unmeasured (empty) boxes get no badge.
     */
    public fun <K> badgeFrames(boxes: List<Pair<K, MonitorRect>>, viewportWidth: Float, viewportHeight: Float): List<Pair<K, MonitorRect>> =
        placeBadges(boxes, viewportWidth, viewportHeight)
}

private fun <K> placeBadges(
    boxes: List<Pair<K, MonitorRect>>,
    vw: Float,
    vh: Float,
): List<Pair<K, MonitorRect>> {
    val playable =
        MonitorRect(
            min(EDGE_INSET, max(0f, vw - BADGE)),
            min(EDGE_INSET, max(0f, vh - BADGE)),
            max(BADGE, vw - 2f * EDGE_INSET),
            max(BADGE, vh - 2f * EDGE_INSET),
        )
    val placed = mutableListOf<MonitorRect>()
    val result = mutableListOf<Pair<K, MonitorRect>>()
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
