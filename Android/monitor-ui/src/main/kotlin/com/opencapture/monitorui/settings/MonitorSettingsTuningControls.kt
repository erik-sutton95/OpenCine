package com.opencapture.monitorui.settings

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import kotlin.math.roundToInt

private val TuningShape = RoundedCornerShape(12.dp)
private fun tuningTextStyle(size: Float, weight: FontWeight, mono: Boolean = false): TextStyle =
    if (mono) MonitorTypography.readout(size, weight) else MonitorTypography.text(size, weight)

/** A named presentation swatch; its color comes from the source's current theme. */
data class MonitorSettingsColorDot(val name: String, val color: Color)

@Composable
fun MonitorSettingsSegmented(
    options: List<String>,
    selected: String,
    compact: Boolean = true,
    fillWidth: Boolean = compact,
    accentSelection: Boolean = false,
    testTag: String? = null,
    onSelect: (String) -> Unit,
) = MonitorSettingsChoices(options, selected, compact, fillWidth, accentSelection, testTag, { it }, onSelect)

/** Typed choices keep presentation labels separate from the selected value. */
@Composable
fun <Value> MonitorSettingsChoices(
    options: List<Value>,
    selected: Value,
    compact: Boolean = true,
    fillWidth: Boolean = compact,
    accentSelection: Boolean = false,
    testTag: String? = null,
    title: (Value) -> String,
    onSelect: (Value) -> Unit,
) {
    BoxWithConstraints {
        val labelSize = if (compact && fillWidth && options.size >= 4 && maxWidth < 260.dp) 9.5f else if (compact) 11f else 11.5f
        Row(
            Modifier
                .then(if (testTag != null) Modifier.testTag(testTag) else Modifier)
                .then(if (fillWidth) Modifier.fillMaxWidth() else Modifier)
                .background(MonitorPalette.background.copy(alpha = 0.5f), TuningShape)
                .border(1.dp, MonitorPalette.border, TuningShape)
                .padding(3.dp)
                .selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            options.forEach { option ->
                val active = option == selected
                Box(
                    Modifier
                        .then(if (fillWidth) Modifier.weight(1f) else Modifier)
                        .defaultMinSize(minHeight = if (compact) 32.dp else 30.dp)
                        .background(
                            if (active) { if (accentSelection) MonitorPalette.accent else MonitorPalette.surface } else Color.Transparent,
                            TuningShape,
                        )
                        .selectable(
                            selected = active,
                            role = Role.RadioButton,
                            onClick = { if (!active) onSelect(option) },
                        )
                        .padding(horizontal = if (compact && fillWidth) 2.dp else if (compact) 8.dp else 11.dp, vertical = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        title(option),
                        style = tuningTextStyle(labelSize, if (active) FontWeight.SemiBold else FontWeight.Medium),
                        color = if (active) { if (accentSelection) Color(0xFF08191F) else MonitorPalette.text } else MonitorPalette.muted,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

@Composable
fun MonitorSettingsColorDots(
    dots: List<MonitorSettingsColorDot>,
    selectedName: String,
    compact: Boolean = true,
    enabled: Boolean = true,
    onSelect: (String) -> Unit,
) {
    val diameter = if (compact) 15.dp else 13.dp
    val hit = 44.dp
    Row(horizontalArrangement = Arrangement.spacedBy(if (compact) 4.dp else 6.dp)) {
        dots.forEach { dot ->
            val active = dot.name == selectedName
            Box(
                Modifier
                    .size(hit)
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.RadioButton) {
                        if (enabled && !active) onSelect(dot.name)
                    }
                    .semantics { contentDescription = dot.name; if (!enabled) disabled() },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier
                        .size(36.dp)
                        .background(MonitorPalette.background.copy(alpha = 0.5f), CircleShape)
                        .border(
                            width = if (active) 2.dp else 1.dp,
                            color = if (active) dot.color else MonitorPalette.border,
                            shape = CircleShape,
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(Modifier.size(diameter).background(dot.color, CircleShape))
                }
            }
        }
    }
}

@Composable
fun MonitorSettingsPercentSlider(
    value: Int,
    range: IntRange,
    onChange: (Int) -> Unit,
) {
    MonitorSettingsValueSlider(value = value, range = range, label = "$value%", onChange = onChange)
}

@Composable
fun MonitorSettingsValueSlider(
    value: Int,
    range: IntRange,
    label: String,
    onChange: (Int) -> Unit,
    modifier: Modifier = Modifier,
    labelWidth: Int = 40,
) {
    Row(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MonitorSettingsPillSlider(
            value = value,
            range = range,
            onChange = onChange,
            modifier = Modifier.weight(1f),
        )
        Text(
            label,
            style = tuningTextStyle(12f, FontWeight.Medium, mono = true),
            color = MonitorPalette.text,
            textAlign = TextAlign.End,
            modifier = Modifier.width(labelWidth.dp),
        )
    }
}

@Composable
fun MonitorSettingsPillSlider(value: Int, range: IntRange, onChange: (Int) -> Unit, modifier: Modifier = Modifier) {
    val currentOnChange by rememberUpdatedState(onChange)
    val start = range.first.toFloat()
    val endInclusive = range.last.toFloat().coerceAtLeast(start)
    val span = (endInclusive - start).coerceAtLeast(1f)
    var widthPx by remember { mutableFloatStateOf(1f) }
    val density = LocalDensity.current
    fun atX(x: Float): Int {
        val inset = with(density) { 10.dp.toPx() }
        val t = ((x - inset) / (widthPx - 2f * inset).coerceAtLeast(1f)).coerceIn(0f, 1f)
        return (start + t * span).roundToInt().coerceIn(range)
    }
    Canvas(
        modifier
            .fillMaxWidth()
            .height(44.dp)
            .onSizeChanged { widthPx = it.width.toFloat() }
            .semantics {
                progressBarRangeInfo = ProgressBarRangeInfo(value.toFloat(), start..endInclusive)
                setProgress {
                    val next = it.roundToInt().coerceIn(range)
                    if (next != value) onChange(next)
                    true
                }
            }
            .pointerInput(range) { detectTapGestures { currentOnChange(atX(it.x)) } }
            .pointerInput(range) {
                detectHorizontalDragGestures { change, _ ->
                    change.consume()
                    currentOnChange(atX(change.position.x))
                }
            },
    ) {
        val y = size.height / 2f
        val inset = 10.dp.toPx()
        val track = 2.dp.toPx()
        val t = ((value.toFloat() - start) / span).coerceIn(0f, 1f)
        val thumbX = inset + t * (size.width - 2f * inset)
        drawLine(
            Color.White.copy(alpha = 0.10f),
            Offset(inset, y),
            Offset(size.width - inset, y),
            track,
            StrokeCap.Round,
        )
        drawLine(MonitorPalette.accent, Offset(inset, y), Offset(thumbX, y), track, StrokeCap.Round)
        drawCircle(Color.White, 10.dp.toPx(), Offset(thumbX, y))
    }
}

@Composable
fun MonitorSettingsCrushClipSegmented(
    options: List<Pair<String, String>>,
    selectedLabel: String,
    accentSelection: Boolean = false,
    onSelect: (String) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(MonitorPalette.background.copy(alpha = 0.5f), TuningShape)
            .border(1.dp, MonitorPalette.border, TuningShape)
            .padding(4.dp)
            .selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        options.forEach { (label, compact) ->
            val active = label == selectedLabel
            Box(
                Modifier
                    .weight(1f)
                    .defaultMinSize(minHeight = 34.dp)
                    .background(
                        if (active) { if (accentSelection) MonitorPalette.accent else MonitorPalette.surface } else Color.Transparent,
                        TuningShape,
                    )
                    .selectable(
                        selected = active,
                        role = Role.RadioButton,
                        onClick = { if (!active) onSelect(label) },
                    )
                    // The segment shows a fraction glyph; the full stop value is what a screen
                    // reader has to say, so it announces the label rather than "¼".
                    .semantics { contentDescription = label },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    compact,
                    style = tuningTextStyle(12f, if (active) FontWeight.SemiBold else FontWeight.Medium),
                    color = if (active) { if (accentSelection) Color(0xFF08191F) else MonitorPalette.text } else MonitorPalette.muted,
                    maxLines = 1,
                )
            }
        }
    }
}
