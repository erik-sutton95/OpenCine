package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorImagePreview
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorInspectorPreviewClient
import com.opencapture.opencine.appkit.MonitorInspectorPreviewSession
import com.opencapture.opencine.appkit.MonitorInspectorScopeDemand
import com.opencapture.opencine.media.FeedEffectsRenderPlan

/** Assist panels retain their viewport key; a camera-tile editor retains its source key. */
enum class MonitorInspectorPreviewLayout { VIEWPORT, SOURCE }

object MonitorInspectorImagePreviewPolicy {
    fun supports(tool: MonitorAssistTool): Boolean = tool in listOf(MonitorAssistTool.LUT,
        MonitorAssistTool.PEAK, MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA, MonitorAssistTool.DESQ)
}

/** Complete selected-tool image preview over a bounded native picture port. */
@Composable
fun MonitorOperatorInspectorImagePreview(tool: MonitorAssistTool, state: MonitorAssistState?,
    client: MonitorInspectorPreviewClient<ImageBitmap>, plan: FeedEffectsRenderPlan,
    sourceIdentity: Any?, colorMode: Int?, playback: Boolean,
    modifier: Modifier = Modifier, description: String = "${tool.title} image preview",
    layout: MonitorInspectorPreviewLayout = MonitorInspectorPreviewLayout.VIEWPORT) {
    if (!MonitorInspectorImagePreviewPolicy.supports(tool)) return
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val viewport = if (layout == MonitorInspectorPreviewLayout.VIEWPORT)
        listOf(configuration.screenWidthDp, configuration.screenHeightDp, density.density, density.fontScale) else null
    val session = remember(client, tool, playback, sourceIdentity, colorMode, viewport) {
        MonitorInspectorPreviewSession(client)
    }
    val latestPlan by rememberUpdatedState(plan)
    val image by session.image.collectAsState()
    DisposableEffect(session, lifecycle) {
        var owner: Any? = null
        fun retire() {
            val captured = owner ?: return
            owner = null
            if (state != null && state.inspectorScopeDemand?.owner === captured) state.inspectorScopeDemand = null
            session.deactivate(captured)
        }
        fun update() {
            val resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            if (resumed && owner == null) {
                val captured = session.activate(playback, latestPlan)
                if (!session.isCurrent(captured)) return
                owner = captured
                if (state != null) state.inspectorScopeDemand = MonitorInspectorScopeDemand(captured, tool, playback)
                if (!session.isCurrent(captured)) retire()
            } else if (!resumed) retire()
        }
        val observer = LifecycleEventObserver { _, _ -> update() }
        lifecycle.addObserver(observer)
        update()
        onDispose {
            lifecycle.removeObserver(observer)
            retire()
        }
    }
    SideEffect { session.update(plan) }
    val sourceAspect = image?.let { it.width.toFloat() / it.height } ?: (16f / 9f)
    MonitorImagePreview(image, description, modifier,
        aspectRatio = if (tool == MonitorAssistTool.DESQ) state?.presentedAspect(sourceAspect, preview = true) else null)
}
