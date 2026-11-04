package com.opencapture.monitorui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** The selection bar's Close, which leaves selection mode. Swift twin: `MonitorMediaSelectionCopy`. */
object MonitorMediaSelectionCopy {
    const val EXIT = "Exit selection"
    const val EXIT_TAG = "monitor.media.selection.close"
}

/**
 * The media selection bar (Swift twin: the selection tray in `MonitorMediaCatalog`): Close and the
 * count at the leading edge; All, Share and Delete at the trailing edge, scrolling only when the bar
 * is too narrow. Same card surface, chips, type and spacing as iOS. Labels name what each action
 * acts on; [shareEnabled] and [deleteEnabled] are the adapter's capability gates.
 */
@Composable
fun MonitorSelectionTray(
    count: Int,
    onExit: () -> Unit,
    onAll: () -> Unit,
    onShare: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
    shareEnabled: Boolean = true,
    deleteEnabled: Boolean = true,
    shareLabel: String = "Share selected",
    deleteLabel: String = "Delete selected",
    onClickFeedback: () -> Unit = {},
) {
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(MonitorPalette.surface)
            .border(1.dp, MonitorPalette.border, RoundedCornerShape(12.dp))
            .padding(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        MonitorSelectionChip(MonitorIcon.X, MonitorMediaSelectionCopy.EXIT, tag = MonitorMediaSelectionCopy.EXIT_TAG,
            minimumTarget = 48f, onClickFeedback = onClickFeedback, onClick = onExit)
        // The count keeps its full width; on a narrow phone the actions scroll instead of cutting it.
        Text("$count selected", color = MonitorPalette.text,
            style = MonitorTypography.text(10.5f, FontWeight.SemiBold), maxLines = 1, softWrap = false)
        Box(Modifier.weight(1f).padding(start = 4.dp), contentAlignment = Alignment.CenterEnd) {
            Row(Modifier.horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                MonitorSelectionChip(MonitorIcon.CIRCLE_CHECK, "Select all", text = "All",
                    onClickFeedback = onClickFeedback, onClick = onAll)
                MonitorSelectionChip(MonitorIcon.SHARE, shareLabel, text = "Share", active = true,
                    enabled = shareEnabled, onClickFeedback = onClickFeedback, onClick = onShare)
                MonitorSelectionChip(MonitorIcon.TRASH, deleteLabel, danger = true,
                    enabled = deleteEnabled, onClickFeedback = onClickFeedback, onClick = onDelete)
            }
        }
    }
}

/**
 * One selection bar control (Swift twin: `MonitorMediaCatalogChip`): an icon and optional word on a
 * 44 dp rounded chip, announced by [label] alone and hit across at least [minimumTarget] dp.
 */
@Composable
private fun MonitorSelectionChip(
    icon: MonitorIcon,
    label: String,
    modifier: Modifier = Modifier,
    tag: String? = null,
    minimumTarget: Float = MONITOR_MIN_TAP_TARGET_DP,
    text: String? = null,
    active: Boolean = false,
    danger: Boolean = false,
    enabled: Boolean = true,
    onClickFeedback: () -> Unit,
    onClick: () -> Unit,
) {
    val tint = if (danger) MonitorPalette.recording else if (active) MonitorPalette.text else MonitorPalette.secondary
    Row(
        // The click precedes the clip, so a target larger than the chip is hit outside its drawn shape.
        modifier.heightIn(min = 44.dp).widthIn(min = 44.dp)
            .monitorChromeClickable(enabled, onClickFeedback = onClickFeedback, minimumTarget = minimumTarget,
                semantics = {
                    contentDescription = label
                    role = Role.Button
                    if (tag != null) testTag = tag
                }, onClick = onClick)
            .clip(RoundedCornerShape(9.dp))
            .background(if (active) MonitorPalette.accent.copy(alpha = .18f) else Color.White.copy(alpha = .04f))
            .padding(horizontal = if (text == null) 9.dp else 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterHorizontally),
    ) {
        MonitorIcon(icon, null, Modifier.size(13.dp), tint)
        if (text != null) Text(text, Modifier.clearAndSetSemantics {}, color = tint,
            style = MonitorTypography.text(10.5f, FontWeight.SemiBold), maxLines = 1, softWrap = false)
    }
}
