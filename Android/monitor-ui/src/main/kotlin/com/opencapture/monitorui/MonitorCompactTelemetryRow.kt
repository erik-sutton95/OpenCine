package com.opencapture.monitorui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import kotlin.math.ceil

internal val LocalMonitorAdaptiveTelemetryPadding = compositionLocalOf { false }

/** Storage retains its original proposal; one native measure owns link and actual power targets. */
@Composable
fun MonitorCompactTelemetryRow(layout: MonitorFieldLayout, safeLeading: Float, safeTrailing: Float,
    metrics: MonitorTelemetryMetrics, modifier: Modifier = Modifier,
    topCutout: MonitorRect? = null,
    storage: @Composable () -> Unit, link: @Composable () -> Unit, power: @Composable () -> Unit) {
    MonitorCompactTelemetryRow(layout, safeLeading, safeTrailing, metrics, {}, modifier, topCutout, storage, link, power)
}

/**
 * The measured status boundary is optional composition; original content calls retain their shape.
 * [topCutout] is the camera housing in viewport dp ([rememberMonitorTopCutout]); storage then yields
 * before the link pill would reach it.
 */
@Composable
fun MonitorCompactTelemetryRow(layout: MonitorFieldLayout, safeLeading: Float, safeTrailing: Float,
    metrics: MonitorTelemetryMetrics, minimumStatusTop: (Float) -> Unit, modifier: Modifier = Modifier,
    topCutout: MonitorRect? = null,
    storage: @Composable () -> Unit, link: @Composable () -> Unit, power: @Composable () -> Unit) {
    val density = LocalDensity.current
    val minimumTarget = maxOf(48f, LocalViewConfiguration.current.minimumTouchTargetSize.width.value)
    val minimumHeight = maxOf(48f, LocalViewConfiguration.current.minimumTouchTargetSize.height.value)
    val rowTop = maxOf(layout.telemetry.y - 13f, layout.viewport.y - (48f - minimumHeight) / 2f)
    Layout(content = {
        Box { storage() }
        CompositionLocalProvider(LocalMonitorAdaptiveTelemetryPadding provides true) { Box { link() } }
        CompositionLocalProvider(LocalMonitorAdaptiveTelemetryPadding provides true) { Box { power() } }
    }, modifier = modifier.offset(y = rowTop.dp)
        .width(layout.viewport.width.dp).onGloballyPositioned {
            with(density) {
                val extra = (it.size.height - 48.dp.roundToPx()).coerceAtLeast(0)
                val floor = rowTop.dp.roundToPx() + (48.dp.roundToPx() - layout.telemetry.height.dp.roundToPx()) / 2 +
                    metrics.pillHeight.dp.roundToPx() + extra + ceil(8.dp.toPx()).toInt()
                minimumStatusTop(if (extra > 0) floor.toDp().value else 0f)
            }
        }) { children, constraints ->
        val bandHeight = 48.dp.roundToPx()
        val loose = constraints.copy(minWidth = 0, minHeight = 0, maxHeight = Constraints.Infinity)
        val powerWidth = constraints.maxWidth - ceil(maxOf(14f, safeLeading).dp.toPx()).toInt() - ceil(maxOf(14f, safeTrailing).dp.toPx()).toInt()
        val powerView = children[2].measure(loose.copy(maxWidth = powerWidth.coerceAtLeast(0)))
        val preferredLink = children[1].maxIntrinsicWidth(Constraints.Infinity)
        val minimumLink = children[1].minIntrinsicWidth(Constraints.Infinity)
        // The adaptive pill's measured width, not its nominal width, is the real reservation.
        val legacyWidth = with(density) {
            legacyStorageWidthPixels(layout, topCutout, preferredLink, minimumTarget, minimumLink)
        }
        val cutoutBound = preferredLink > 0 && MonitorCompactTelemetryBudget.storageWidthBeforeCutout(
            layout, topCutout, with(density) { minimumLink.toDp().value }, minimumTarget) != null
        val storageView = children[0].measure(loose.copy(maxWidth = legacyWidth))
        val budget = MonitorCompactTelemetryBudget.pixels(constraints.maxWidth,
            layout.status.x.dp.roundToPx(), (layout.viewport.width - layout.status.maxX).dp.roundToPx(),
            ceil(safeLeading.dp.toPx()).toInt(), ceil(safeTrailing.dp.toPx()).toInt(),
            storageView.width, powerView.width, preferredLink, ceil(minimumTarget.dp.toPx()).toInt(),
            ceil(14.dp.toPx()).toInt(), ceil(8.dp.toPx()).toInt(), minimumLink)
        // Before a cutout the link pill ends at its clearance, dropping padding rather than reaching it.
        val beforeCutout = if (!cutoutBound) null else with(density) {
            MonitorCompactTelemetryBudget.linkWidthBeforeCutout(layout, topCutout, budget.performanceX.toDp().value)
                ?.let { it.dp.toPx().toInt() }
        }
        val linkView = children[1].measure(loose.copy(
            maxWidth = beforeCutout?.let { minOf(budget.performanceWidth, it) } ?: budget.performanceWidth))
        val powerOffset = if (budget.wrapsPower) bandHeight + ceil(8.dp.toPx()).toInt() else 0
        val additionalHeight = powerOffset + (powerView.height - metrics.pillHeight.dp.roundToPx()).coerceAtLeast(0)
        layout(constraints.maxWidth, bandHeight + additionalHeight) {
            if (storageView.width > 0) storageView.place(
                budget.leading + (budget.storageWidth - storageView.width) / 2,
                (bandHeight - storageView.height) / 2)
            linkView.place(budget.performanceX, (bandHeight - linkView.height) / 2)
            powerView.place(budget.powerX, (bandHeight - layout.telemetry.height.dp.roundToPx()) / 2 + powerOffset)
        }
    }
}

/**
 * The top display cutout crossing this window, in window dp; null without one. The row is laid out
 * from the window origin in portrait, where navigation never takes the top or leading edge.
 * Swift twin: `MonitorTopCutout.estimated`, since iOS reports no cutout shape.
 */
@Composable
fun rememberMonitorTopCutout(): MonitorRect? {
    val view = LocalView.current
    val density = LocalDensity.current
    // Reading the inset subscribes to cutout changes (rotation, folding); the shape comes from the view.
    val top = WindowInsets.displayCutout.getTop(density)
    return remember(view, density, top) {
        val rect = view.rootWindowInsets?.displayCutout?.boundingRectTop
        if (top <= 0 || rect == null || rect.isEmpty) null else with(density) {
            MonitorRect(rect.left.toDp().value, rect.top.toDp().value, rect.width().toDp().value, rect.height().toDp().value)
        }
    }
}
