package com.opencapture.monitorui.wrist

import com.opencapture.opencine.media.BatteryReading
import com.opencapture.opencine.media.BatteryFraction
import com.opencapture.opencine.media.BatterySteps
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import android.os.Build
import android.view.HapticFeedbackConstants
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

import androidx.compose.material3.Text

/** Complete wrist geometry, tally, command feedback and input over truthful source facts. */
@Composable
public fun MonitorWristScreen(
    presentation: MonitorWristPresentation,
    copy: MonitorWristCopy = MonitorWristCopy(),
    onToggleRecord: (MonitorWristActionToken) -> Unit,
    picture: @Composable (Modifier) -> Unit,
): Unit {
    val view = LocalView.current
    val feedback = remember { MonitorWristFeedback() }
    LaunchedEffect(presentation.sourceRevision, presentation.recording, presentation.commandMessage) {
        feedback.update(presentation)?.let { event ->
            val kind = if (Build.VERSION.SDK_INT >= 30) {
                if (event == MonitorWristFeedbackEvent.RECORD_STARTED) HapticFeedbackConstants.CONFIRM
                else HapticFeedbackConstants.REJECT
            } else HapticFeedbackConstants.LONG_PRESS
            view.performHapticFeedback(kind)
        }
    }
    val monitorDescription = copy.monitorDescription
    BoxWithConstraints(
        modifier =
            Modifier.fillMaxSize()
                .background(Color.Black)
                .semantics { contentDescription = monitorDescription },
    ) {
        val layout = monitorWristLayout(LocalConfiguration.current.isScreenRound, maxWidth.value)
        val sideSlotWidth =
            ((maxWidth.value - layout.bottomHorizontalPaddingDp * 2f - 50f) / 2f)
                .coerceAtLeast(1f)
        val storage = presentation.storageLabel(copy)
        val batteryReading = presentation.measuredBatteryReading
        Column(
            modifier =
                Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = presentation.timecodeLabel(copy),
                modifier =
                    Modifier.fillMaxWidth()
                        .padding(horizontal = layout.timecodeHorizontalPaddingDp.dp),
                color = if (presentation.isRecording) Color(0xFFE24040) else Color.White,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                fontSize = layout.timecodeFontSizeSp.sp,
                textAlign = TextAlign.Center,
                maxLines = 1,
            )
            MonitorWristFeed(
                presentation = presentation, copy = copy, picture = picture,
                modifier = Modifier.fillMaxWidth().weight(1f, fill = false),
            )
            Row(
                modifier =
                    Modifier.fillMaxWidth()
                        .padding(horizontal = layout.bottomHorizontalPaddingDp.dp)
                        .padding(bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = storage,
                    modifier = Modifier.weight(1f),
                    color = Color(0xFFC3C5C8),
                    fontSize = monitorWristSingleLineFontSize(storage, sideSlotWidth).sp,
                    maxLines = 1,
                    softWrap = false,
                )
                MonitorWristRecordButton(
                    isRecording = presentation.isRecording,
                    enabled = presentation.canRecord,
                    description = if (presentation.isRecording) copy.stopRecording else copy.startRecording,
                    onClick = { presentation.recordToken?.let(onToggleRecord) },
                )
                Spacer(Modifier.width(6.dp))
                MonitorWristBatteryReadout(
                    reading = batteryReading, exhausted = presentation.batteryExhausted, copy = copy,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun MonitorWristFeed(presentation: MonitorWristPresentation, copy: MonitorWristCopy,
    picture: @Composable (Modifier) -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier =
            modifier
                .aspectRatio(16f / 9f)
                .background(Color(0xFF101114))
                .clipToBounds()
                .then(
                    if (presentation.isRecording) {
                        Modifier.border(3.dp, Color(0xFFE24040))
                    } else {
                        Modifier
                    },
                ),
        contentAlignment = Alignment.Center,
    ) {
        if (presentation.hasPicture) picture(Modifier.fillMaxSize())
        val placeholder = presentation.placeholder(copy)
        if (placeholder != null) {
            Text(
                text = placeholder,
                color = Color.White,
                fontSize = 11.sp,
                textAlign = TextAlign.Center,
                modifier =
                    Modifier.padding(6.dp)
                        .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(6.dp))
                        .padding(6.dp),
                maxLines = 2,
            )
        }
        presentation.commandMessage?.let { message ->
            Text(
                text = message,
                modifier =
                    Modifier.align(Alignment.BottomCenter)
                        .padding(horizontal = 8.dp, vertical = 3.dp)
                        .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(4.dp))
                        .padding(horizontal = 4.dp, vertical = 2.dp),
                color = Color(0xFFE5B567),
                fontSize = 8.sp,
                textAlign = TextAlign.Center,
                maxLines = 2,
            )
        }
    }
}

/** iOS-parity record glyph: circle + rounded red start/stop tally, not a text control. */
@Composable
private fun MonitorWristRecordButton(
    isRecording: Boolean,
    enabled: Boolean,
    description: String,
    onClick: () -> Unit,
) {
    val hapticFeedback = LocalHapticFeedback.current
    val controlColor by
        animateColorAsState(
            if (isRecording) Color(0xFFE24040) else Color.White.copy(alpha = 0.6f),
            label = "record ring",
        )
    val innerSize by
        animateDpAsState(if (isRecording) 14.dp else 22.dp, label = "record glyph size")
    val innerCorner by
        animateDpAsState(if (isRecording) 3.dp else 11.dp, label = "record glyph corner")
    Box(
        modifier =
            Modifier.size(44.dp)
                .alpha(if (enabled) 1f else 0.4f)
                .semantics {
                    contentDescription = description
                    role = Role.Button
                }
                .clickable(enabled = enabled) {
                    hapticFeedback.performHapticFeedback(HapticFeedbackType.LongPress)
                    onClick()
                },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier =
                Modifier.size(34.dp)
                    .border(3.dp, controlColor, CircleShape),
        )
        Box(
            modifier =
                Modifier.size(innerSize)
                    .background(Color(0xFFE24040), RoundedCornerShape(innerCorner)),
        )
    }
}

/** Compact battery glyph and honest camera charge readout. */
@Composable
private fun MonitorWristBatteryReadout(reading: BatteryReading?, exhausted: Boolean?,
    copy: MonitorWristCopy, modifier: Modifier = Modifier) {
    val opacity = if (exhausted == true && reading != null) {
        val transition = rememberInfiniteTransition(label = "reportedBatteryExhaustion")
        val alpha by transition.animateFloat(initialValue = 1f, targetValue = 0.35f,
            animationSpec = infiniteRepeatable(tween(500, easing = LinearEasing), RepeatMode.Reverse),
            label = "reportedBatteryExhaustionAlpha")
        alpha
    } else 1f
    Row(modifier = modifier.alpha(opacity), horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically) {
        when (reading) {
            is BatteryFraction -> {
                val percent = Math.round(reading.value * 100).toInt()
                MonitorWristBatteryGlyph(percent)
                Spacer(Modifier.width(3.dp))
                Text(copy.batteryLabel(percent), color = Color(0xFFC3C5C8), fontSize = 11.sp,
                    maxLines = 1, textAlign = TextAlign.End)
            }
            is BatterySteps -> {
                val tint = when {
                    reading.filled.toDouble() / reading.of <= 0.2 -> Color(0xFFE24040)
                    reading.filled.toDouble() / reading.of <= 0.4 -> Color(0xFFFFB347)
                    else -> Color(0xFFC3C5C8)
                }
                if (reading.of > 10) {
                    Text("${reading.filled}/${reading.of}", color = tint, fontSize = 11.sp,
                        maxLines = 1, textAlign = TextAlign.End, modifier = Modifier.semantics {
                            contentDescription = "Camera battery ${reading.filled} of ${reading.of} bars"
                        })
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(1.dp), modifier = Modifier.semantics {
                        contentDescription = "Camera battery ${reading.filled} of ${reading.of} bars"
                    }) {
                        repeat(reading.of) { index ->
                            Box(Modifier.size(width = 2.5.dp, height = 7.dp).background(
                                if (index < reading.filled) tint else Color.White.copy(alpha = 0.22f),
                                RoundedCornerShape(0.8.dp)))
                        }
                    }
                }
            }
            null -> Unit
        }
    }
}

@Composable
private fun MonitorWristBatteryGlyph(percent: Int) {
    Canvas(Modifier.size(width = 16.dp, height = 10.dp)) {
        val stroke = 1.dp.toPx()
        val bodyWidth = size.width - 3.dp.toPx()
        val bodyHeight = size.height
        val color = Color(0xFFC3C5C8)
        drawRoundRect(
            color = color,
            size = Size(bodyWidth, bodyHeight),
            cornerRadius = CornerRadius(2.dp.toPx()),
            style = Stroke(stroke),
        )
        drawRect(
            color = color,
            topLeft = Offset(bodyWidth, bodyHeight * 0.3f),
            size = Size(3.dp.toPx(), bodyHeight * 0.4f),
        )
        val fillWidth = (bodyWidth - stroke * 2).coerceAtLeast(0f) * (percent / 100f)
        drawRoundRect(
            color = color,
            topLeft = Offset(stroke, stroke),
            size = Size(fillWidth, (bodyHeight - stroke * 2).coerceAtLeast(0f)),
            cornerRadius = CornerRadius(1.dp.toPx()),
        )
    }
}
