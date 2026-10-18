package com.opencapture.opencine.appkit

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorRecordingBorder
import com.opencapture.monitorui.MonitorRect

/** Operator presentation state, separate from camera telemetry and native picture lifetime. */
public data class MonitorScreenPresentation(
    public val visible: Boolean = true, public val interactive: Boolean = true, public val dimmed: Boolean = false,
    /** Hides control accessibility and blocks input; retained chrome may remain dimmed underneath a transient panel. */
    public val transientControlsHidden: Boolean = false, public val pictureWaiting: Boolean = false,
    public val statusMounted: Boolean = true, public val powerMounted: Boolean = true, public val captureMounted: Boolean = true,
    public val captureHidden: Boolean = false, public val captureInteractive: Boolean = true, public val locked: Boolean = false,
    public val popupInteractive: Boolean = false, public val capturePresented: Boolean = false,
    public val panelsRaised: Boolean = false, public val recovering: Boolean = false,
    /** Keeps status telemetry mounted while excluding an occluded status slot from input and accessibility. */
    public val statusInteractive: Boolean = true,
)

/** Fixed picture/assist hosts and common chrome placement survive rotation and coverage. */
@Composable
public fun MonitorScreen(control: MonitorControlModel, layout: MonitorFieldLayout, presentation: MonitorScreenPresentation,
    modifier: Modifier = Modifier,
    picture: @Composable BoxScope.() -> Unit,
    assists: @Composable BoxScope.() -> Unit = {}, signal: @Composable BoxScope.() -> Unit = {},
    status: @Composable BoxScope.(Boolean) -> Unit = {}, power: @Composable BoxScope.(Boolean) -> Unit = {},
    capture: @Composable BoxScope.(Boolean) -> Unit = {}, system: @Composable BoxScope.(Boolean) -> Unit = {},
    tools: @Composable BoxScope.(Boolean) -> Unit = {}, panels: @Composable BoxScope.(Boolean) -> Unit = {},
    cover: @Composable BoxScope.() -> Unit = {}, recovery: @Composable BoxScope.() -> Unit = {}) {
    val commonVisible = presentation.visible
    val commonInteractive = commonVisible && presentation.interactive && !presentation.transientControlsHidden
    val commonAccessibility = if (presentation.transientControlsHidden) Modifier.clearAndSetSemantics {} else Modifier
    val dim = if (presentation.dimmed) .16f else 1f
    fun Modifier.visible(shown: Boolean, opacity: Float = 1f): Modifier =
        alpha(if (shown) opacity else 0f).layout { measurable, constraints ->
            val child = measurable.measure(constraints)
            layout(child.width, child.height) { if (shown) child.place(0, 0) }
        }.then(if (!shown) Modifier.clearAndSetSemantics { } else Modifier)
    fun Modifier.frame(rect: MonitorRect): Modifier = offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)
    Box(modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize(), content = picture)
        Box(Modifier.fillMaxSize(), content = assists)
        Box(Modifier.frame(layout.picture).visible(presentation.visible && presentation.pictureWaiting), content = signal)
        if (layout.portrait) Box(Modifier.frame(layout.system).background(Color.Black))
        Box(Modifier.fillMaxSize().visible(commonVisible, dim).then(commonAccessibility)) { tools(commonInteractive) }
        if (presentation.statusMounted) {
            val statusFrame = if (layout.portrait) Modifier.offset(layout.status.x.dp, layout.status.y.dp).width(layout.status.width.dp)
                else Modifier.frame(layout.status)
            val statusAccessibility = if (presentation.statusInteractive) commonAccessibility else Modifier.clearAndSetSemantics {}
            Box(statusFrame.visible(commonVisible, dim).then(statusAccessibility)) {
                status(commonInteractive && presentation.statusInteractive)
            }
        }
        if (presentation.powerMounted) Box(Modifier.frame(layout.telemetry).visible(commonVisible, dim).then(commonAccessibility),
            contentAlignment = if (layout.portrait && !layout.tablet) Alignment.TopEnd else Alignment.TopStart) { power(commonInteractive) }
        if (presentation.captureMounted) Box(Modifier.frame(layout.values)
            .wrapContentHeight(align = Alignment.Bottom, unbounded = true)
            .visible(commonVisible && !presentation.captureHidden, dim * if (presentation.locked) .4f else 1f).then(commonAccessibility),
            contentAlignment = Alignment.BottomCenter) { capture(commonInteractive && !presentation.locked && presentation.captureInteractive && !presentation.captureHidden) }
        Box(Modifier.fillMaxSize().visible(commonVisible, dim).then(commonAccessibility)
            .zIndex(if (presentation.capturePresented) 11f else 0f)) { system(commonInteractive) }
        MonitorCameraRecordingBorder(control, presentation.visible)
        Box(Modifier.fillMaxSize().visible(presentation.visible).zIndex(if (presentation.panelsRaised) 16f else 10f)) { panels(presentation.visible && presentation.popupInteractive) }
        Box(Modifier.fillMaxSize().zIndex(20f), content = cover)
        Box(Modifier.fillMaxSize().zIndex(30f), content = recovery)
    }
}

/** Record telemetry is observed outside native picture geometry and host ownership. */
@Composable
private fun MonitorCameraRecordingBorder(control: MonitorControlModel, visible: Boolean) {
    val state by control.state.collectAsState()
    val recording = state.snapshot?.recording?.value == com.opencapture.opencine.core.RecordingState.RECORDING
    if (visible) MonitorRecordingBorder(recording)
}
