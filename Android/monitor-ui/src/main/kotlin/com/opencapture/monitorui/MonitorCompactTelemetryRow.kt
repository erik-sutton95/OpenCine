package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import kotlin.math.max
import kotlin.math.ceil

internal val LocalMonitorAdaptiveTelemetryPadding = compositionLocalOf { false }

/** Storage retains its original proposal; one native measure owns link and actual power targets. */
@Composable
fun MonitorCompactTelemetryRow(layout: MonitorFieldLayout, safeLeading: Float, safeTrailing: Float,
    metrics: MonitorTelemetryMetrics, modifier: Modifier = Modifier,
    storage: @Composable () -> Unit, link: @Composable () -> Unit, power: @Composable () -> Unit) {
    val minimumTarget = maxOf(48f, LocalViewConfiguration.current.minimumTouchTargetSize.width.value)
    val minimumHeight = maxOf(48f, LocalViewConfiguration.current.minimumTouchTargetSize.height.value)
    val rowTop = maxOf(layout.telemetry.y - 13f, layout.viewport.y - (48f - minimumHeight) / 2f)
    Layout(content = {
        Box { storage() }
        CompositionLocalProvider(LocalMonitorAdaptiveTelemetryPadding provides true) { Box { link() } }
        Box { power() }
    }, modifier = modifier.offset(y = rowTop.dp)
        .width(layout.viewport.width.dp).height(48.dp)) { children, constraints ->
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val powerView = children[2].measure(loose.copy(maxWidth = Constraints.Infinity))
        val preferredLink = children[1].maxIntrinsicWidth(Constraints.Infinity)
        // Match the old row's roundToPx at each term, including fractional native densities.
        val legacyRowWidth = max(0f, layout.telemetry.x - layout.status.x - 8f).dp.roundToPx()
        val legacyLinkWidth = if (preferredLink > 0) metrics.pillWidth.dp.roundToPx() else 0
        val legacyWidth = (legacyRowWidth - legacyLinkWidth - 8.dp.roundToPx()).coerceAtLeast(0)
        val storageView = children[0].measure(loose.copy(maxWidth = legacyWidth))
        val budget = MonitorCompactTelemetryBudget.pixels(constraints.maxWidth,
            layout.status.x.dp.roundToPx(), (layout.viewport.width - layout.status.maxX).dp.roundToPx(),
            ceil(safeLeading.dp.toPx()).toInt(), ceil(safeTrailing.dp.toPx()).toInt(),
            storageView.width, powerView.width, preferredLink, ceil(minimumTarget.dp.toPx()).toInt(),
            ceil(14.dp.toPx()).toInt(), ceil(8.dp.toPx()).toInt())
        val linkView = children[1].measure(loose.copy(maxWidth = budget.performanceWidth))
        layout(constraints.maxWidth, constraints.maxHeight) {
            if (storageView.width > 0) storageView.place(
                budget.leading + (budget.storageWidth - storageView.width) / 2,
                (constraints.maxHeight - storageView.height) / 2)
            linkView.place(budget.performanceX, (constraints.maxHeight - linkView.height) / 2)
            powerView.place(budget.powerX, (constraints.maxHeight - layout.telemetry.height.dp.roundToPx()) / 2)
        }
    }
}
