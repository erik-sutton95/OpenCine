package com.opencapture.monitorui

import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

/** A bounded script reader. Its owner supplies state; it never owns a camera or an import. */
@Composable
public fun TeleprompterReader(
    text: String, fontSize: Float, speed: Float, mirrored: Boolean, backgroundOpacity: Float,
    playing: Boolean, position: Double, onPosition: (Double) -> Unit, onPause: () -> Unit,
    onTogglePlayback: () -> Unit, onReset: () -> Unit,
    modifier: Modifier = Modifier, enabled: Boolean = true, onSettings: (() -> Unit)? = null,
) {
    val density = LocalDensity.current.density
    val scroll = rememberScrollState((position * density).roundToInt().coerceAtLeast(0))
    val dragged by scroll.interactionSource.collectIsDraggedAsState()
    val reportPosition by rememberUpdatedState(onPosition)
    val pause by rememberUpdatedState(onPause)
    LaunchedEffect(dragged) { if (dragged) pause() }
    LaunchedEffect(scroll, density) {
        snapshotFlow { scroll.value }.collect { reportPosition(it / density.toDouble()) }
    }
    LaunchedEffect(position == 0.0, text, fontSize, density) {
        if (position == 0.0) scroll.scrollTo(0)
    }
    LaunchedEffect(playing, speed, text, density) {
        if (!playing) return@LaunchedEffect
        val playback = TeleprompterPlayback().apply { seek(scroll.value / density.toDouble()); play() }
        var previous = withFrameNanos { it }
        while (playback.isPlaying) {
            val frame = withFrameNanos { it }
            playback.advance((frame - previous) / 1_000_000_000.0, speed.toDouble(), scroll.maxValue / density.toDouble())
            previous = frame
            scroll.scrollTo((playback.position * density).roundToInt())
            if (!playback.isPlaying) pause()
        }
    }
    Column(modifier.clip(RoundedCornerShape(14.dp)).background(Color.Black.copy(alpha = backgroundOpacity))
        .padding(horizontal = 12.dp).testTag("teleprompter.overlay")) {
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val trailingSpace = maxHeight * 0.6f
            Column(Modifier.fillMaxSize().verticalScroll(scroll, enabled = enabled).testTag("teleprompter.script")) {
                Text(text, color = Color.White, fontSize = fontSize.sp, lineHeight = (fontSize * 1.35f).sp,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)
                        .graphicsLayer { scaleX = if (mirrored) -1f else 1f })
                Spacer(Modifier.height(trailingSpace))
            }
        }
        Row(Modifier.fillMaxWidth().padding(bottom = 6.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End)) {
            IconButton(onClick = onTogglePlayback, enabled = enabled,
                modifier = Modifier.size(44.dp).testTag("teleprompter.play")) {
                MonitorIcon(if (playing) MonitorIcon.PAUSE else MonitorIcon.PLAY,
                    if (playing) "Pause script" else "Play script", Modifier.size(20.dp), Color.White)
            }
            IconButton(onClick = onReset, enabled = enabled,
                modifier = Modifier.size(44.dp).testTag("teleprompter.reset")) {
                MonitorIcon(MonitorIcon.ROTATE_CW, "Reset script", Modifier.size(20.dp), Color.White)
            }
            if (onSettings != null) IconButton(onClick = { onPause(); onSettings() }, enabled = enabled,
                modifier = Modifier.size(44.dp).testTag("teleprompter.settings")) {
                MonitorIcon(MonitorIcon.SETTINGS, "Teleprompter settings", Modifier.size(20.dp), Color.White)
            }
        }
    }
}
