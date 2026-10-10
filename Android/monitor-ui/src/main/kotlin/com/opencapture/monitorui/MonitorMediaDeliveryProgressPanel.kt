package com.opencapture.monitorui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** Expanded chrome; the host retains expansion lifetime, placement and the delivery task. */
@Composable
fun MonitorMediaDeliveryProgressPanel(
    value: MonitorMediaDeliveryProgressValue,
    details: MonitorMediaDeliveryProgressDetailsValue = MonitorMediaDeliveryProgressDetailsValue(),
    onCancel: (() -> Unit)? = null,
    onCollapse: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    destinationIcon: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(12.dp)
    Column(
        modifier.fillMaxWidth().clip(shape).monitorMaterial(MonitorMaterial.Delivery, shape)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        MonitorMediaDeliveryProgressContent(
            value, onCancel, onExpand = null, showsInlineProgress = false,
            destinationIcon = destinationIcon,
        )
        if (value.showsProgress) {
            val barShape = RoundedCornerShape(50)
            Box(Modifier.fillMaxWidth().height(4.dp).clip(barShape)
                .background(MonitorPalette.border.copy(alpha = .55f))
                .testTag("monitor.share.progress.bar")) {
                Box(Modifier.fillMaxWidth(value.fraction.toFloat().coerceIn(0f, 1f))
                    .height(4.dp).background(MonitorPalette.accent))
            }
        }
        details.filename?.let { filename ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.testTag("monitor.share.progress.filename")) {
                Text("File", style = MonitorTypography.text(10f, FontWeight.SemiBold), color = MonitorPalette.muted)
                Text(filename, Modifier.weight(1f), style = MonitorTypography.readout(11f),
                    color = MonitorPalette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        details.destination?.let { destination ->
            Text("Destination: $destination", style = MonitorTypography.text(11f), color = MonitorPalette.muted,
                modifier = Modifier.testTag("monitor.share.progress.destination"))
        }
        onCollapse?.let { collapse ->
            Text("Collapse", style = MonitorTypography.text(12f, FontWeight.SemiBold), color = MonitorPalette.accent,
                modifier = Modifier.align(Alignment.End).monitorChromeClickable(onClick = collapse)
                    .testTag("monitor.share.progress.collapse"))
        }
    }
}

/** Shared compact content; a null expansion action retains the existing content path. */
@Composable
internal fun MonitorMediaDeliveryProgressContent(
    value: MonitorMediaDeliveryProgressValue,
    onCancel: (() -> Unit)?,
    onExpand: (() -> Unit)?,
    showsInlineProgress: Boolean = true,
    destinationIcon: @Composable () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (onExpand == null) {
            ProgressStatus(value, showsInlineProgress, Modifier.weight(1f), destinationIcon)
        } else {
            ProgressStatus(value, showsInlineProgress,
                Modifier.weight(1f).monitorChromeClickable(onClick = onExpand)
                    .semantics { onClick(label = "Expand delivery progress") { onExpand(); true } }
                    .testTag("monitor.share.progress.expand"), destinationIcon)
        }
        onCancel?.let {
            Text("Cancel", style = MonitorTypography.text(11f, FontWeight.SemiBold), color = MonitorPalette.muted,
                modifier = Modifier.monitorChromeClickable(onClick = it))
        }
    }
}

@Composable
private fun ProgressStatus(
    value: MonitorMediaDeliveryProgressValue,
    showsInlineProgress: Boolean,
    modifier: Modifier,
    destinationIcon: @Composable () -> Unit,
) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (value.preparing) {
            CircularProgressIndicator(Modifier.size(16.dp), color = MonitorPalette.accent, strokeWidth = 2.dp)
        } else Box(Modifier.size(13.dp)) { destinationIcon() }
        Column(Modifier.weight(1f)) {
            Text(value.status, style = MonitorTypography.text(12f, FontWeight.SemiBold), color = MonitorPalette.text,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            value.batch?.let {
                Text(it, style = MonitorTypography.readout(10f, FontWeight.Medium), color = MonitorPalette.muted, maxLines = 1)
            }
        }
        if (showsInlineProgress && value.showsProgress) {
            val shape = RoundedCornerShape(50)
            Box(Modifier.size(width = 44.dp, height = 4.dp).clip(shape).background(MonitorPalette.border.copy(alpha = .55f))) {
                Box(Modifier.fillMaxWidth(value.fraction.toFloat().coerceIn(0f, 1f)).height(4.dp)
                    .background(MonitorPalette.accent))
            }
        }
    }
}
