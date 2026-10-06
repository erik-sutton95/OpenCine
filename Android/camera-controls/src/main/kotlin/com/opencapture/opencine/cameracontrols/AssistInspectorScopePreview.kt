package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorInspectorScopeDemand
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/** Reuses one existing latest-frame scope tap; previews never enable a monitor tool. */
@Composable
fun AssistInspectorScopePreview(tool: MonitorAssistTool, state: MonitorAssistState, transfer: MonitorTransfer, playback: Boolean = false) {
    if (tool !in listOf(MonitorAssistTool.WAVE, MonitorAssistTool.PARADE, MonitorAssistTool.HISTO,
            MonitorAssistTool.VECTOR, MonitorAssistTool.LIGHTS)) return
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val owner = remember { Any() }
    var resumed by remember { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(tool, lifecycle, playback) {
        fun update() {
            resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            if (resumed) state.inspectorScopeDemand = MonitorInspectorScopeDemand(owner, tool, playback)
            else if (state.inspectorScopeDemand?.owner === owner) state.inspectorScopeDemand = null
        }
        val observer = LifecycleEventObserver { _, _ -> update() }
        lifecycle.addObserver(observer)
        update()
        onDispose {
            lifecycle.removeObserver(observer)
            if (state.inspectorScopeDemand?.owner === owner) state.inspectorScopeDemand = null
        }
    }
    var bundle by remember(tool) { mutableStateOf(ScopeAssistBundle.EMPTY) }
    LaunchedEffect(tool, resumed) {
        if (!resumed) { bundle = ScopeAssistBundle.EMPTY; return@LaunchedEffect }
        while (isActive) {
            bundle = state.scopeBundle
            delay(200)
        }
    }
    Box(Modifier.fillMaxWidth().height(if (tool == MonitorAssistTool.LIGHTS) 72.dp else 132.dp)
        .clip(RoundedCornerShape(10.dp)).background(LiveDesign.background)) {
        when (tool) {
            MonitorAssistTool.WAVE -> WaveformPanel(state, transfer, Modifier.fillMaxSize(), bundle)
            MonitorAssistTool.PARADE -> ParadePanel(state, transfer, Modifier.fillMaxSize(), bundle)
            MonitorAssistTool.HISTO -> HistogramPanel(state, Modifier.fillMaxSize(), bundle)
            MonitorAssistTool.VECTOR -> VectorscopePanel(state, Modifier.fillMaxSize(), bundle)
            MonitorAssistTool.LIGHTS -> TrafficLightsPanel(state, Modifier.fillMaxSize(), bundle)
            else -> Unit
        }
    }
}
