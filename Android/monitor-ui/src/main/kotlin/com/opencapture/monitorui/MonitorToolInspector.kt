package com.opencapture.monitorui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** Source-supplied tool navigation facts; no mode, brand or camera-name policy. */
data class MonitorInspectorTool<Value>(val value: Value, val title: String, val label: String)

/** Owns both-orientation tool navigation/help and one bounded selected-tool option area. */
@Composable
fun <Value> MonitorToolInspector(selection: MonitorInspectorTool<Value>, tools: List<MonitorInspectorTool<Value>>,
    viewportWidth: Float, viewportHeight: Float, safeLeading: Float = 0f, safeTop: Float = 0f,
    safeBottom: Float = 0f, safeTrailing: Float = 0f, trailing: Boolean = false,
    scrollContents: Boolean = false, onSelect: (Value) -> Unit, onDismiss: () -> Unit,
    glyph: @Composable (Value, Color, Modifier) -> Unit,
    content: @Composable (availableHeight: Float) -> Unit) {
    var helpVisible by remember { mutableStateOf(false) }
    MonitorInspector(title = selection.title, helpVisible = helpVisible,
        onToggleHelp = { helpVisible = !helpVisible }, viewportWidth = viewportWidth,
        viewportHeight = viewportHeight, safeLeading = safeLeading, safeTop = safeTop,
        safeBottom = safeBottom, safeTrailing = safeTrailing, trailing = trailing,
        onDismiss = onDismiss,
        navigation = { portrait ->
            val scroll = rememberScrollState()
            @Composable fun tabs() {
                tools.forEachIndexed { index, tool ->
                    val active = tool.value == selection.value
                    val tint = if (active) MonitorPalette.accent else MonitorPalette.muted
                    MonitorTab(active, { onSelect(tool.value) },
                        Modifier.then(if (portrait) Modifier.width(94.dp) else Modifier.fillMaxWidth()).height(44.dp),
                        vertical = !portrait, separator = index > 0, accessibilityLabel = tool.title) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            glyph(tool.value, tint, Modifier.size(15.dp))
                            Text(tool.label, color = tint, style = MonitorTypography.text(9f, FontWeight.SemiBold), maxLines = 1)
                        }
                    }
                }
            }
            if (portrait) {
                Row(Modifier.fillMaxWidth().monitorScrollFade(scroll, vertical = false)
                    .horizontalScroll(scroll).monitorTabStrip()) { tabs() }
            } else {
                Column(Modifier.fillMaxHeight().monitorScrollFade(scroll)
                    .verticalScroll(scroll).monitorTabStrip()) { tabs() }
            }
        }) {
        key(selection.value) {
            BoxWithConstraints(Modifier.fillMaxWidth().fillMaxHeight()) {
                val availableHeight = maxHeight.value
                CompositionLocalProvider(LocalMonitorInspectorHelp provides helpVisible) {
                    val scroll = rememberScrollState()
                    Column(Modifier.fillMaxWidth().then(if (scrollContents)
                        Modifier.monitorScrollFade(scroll).verticalScroll(scroll) else Modifier),
                        verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        content(availableHeight)
                    }
                }
            }
        }
    }
}
