package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorAssistTool

/**
 * `AssistToolCell`: 19dp glyph over a 9sp mono label. On-state is
 * iOS `AssistToolChip`: accent-dim fill plus a 1pt accent stroke.
 */
@Composable
fun AssistToolCell(
    tool: MonitorAssistTool,
    isOn: Boolean,
    enabled: Boolean,
    onLongClick: (() -> Unit)?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tint = if (isOn) LiveDesign.accent else LiveDesign.muted
    Column(
        modifier =
            modifier
                .background(if (isOn) LiveDesign.accentDim else Color.Transparent, ChromeShape)
                .border(1.dp, if (isOn) LiveDesign.accent else Color.Transparent, ChromeShape)
                .chromeClickable(
                    enabled = enabled,
                    onLongClick = onLongClick,
                    onClick = onClick,
                )
                .clearAndSetSemantics {
                    // Same sentence the palette already speaks for these very
                    // tools (`MonitorAssistPalette`). The hold hint follows the
                    // zoom readout, which names the gesture it offers rather
                    // than leaving it to be discovered. Clearing is what stops
                    // the 9sp "WAVE" abbreviation being read after the name;
                    // plain `semantics` leaves it behind as a second stop, and
                    // the tap and hold actions survive the clear.
                    val options = if (onLongClick != null) ". Hold for options" else ""
                    contentDescription = "${tool.title}, ${if (isOn) "on" else "off"}$options"
                    if (!enabled) disabled()
                }
                .padding(vertical = 5.dp, horizontal = 8.dp)
                .widthIn(min = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.height(23.dp), contentAlignment = Alignment.Center) {
            AssistToolGlyph(tool, tint, Modifier.size(19.dp))
        }
        Text(
            tool.chipLabel,
            style = LiveType.mono(9f, FontWeight.Medium).copy(letterSpacing = 0.9.sp),
            color = tint,
            maxLines = 1,
        )
    }
}

/** The supplied design owns assist glyphs; EV uses its readable abbreviation. */
@Composable
fun AssistToolGlyph(tool: MonitorAssistTool, tint: Color, modifier: Modifier = Modifier,
    evFontSize: Float = 13.3f) =
    com.opencapture.monitorui.MonitorAssistToolGlyph(tool, tint, modifier, evFontSize)
