package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorTab
import com.opencapture.monitorui.monitorTabStrip
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoice
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoices
import com.opencapture.opencine.vocabulary.CaptureCodecColorSection

/**
 * The one codec and colour popup body. It lays out only the sections the camera offers
 * ([CaptureCodecColorChoices.sections]): the codec control, then the colour control for the
 * selected codec. A host that already owns a richer codec control passes it as [codec]; otherwise
 * the codec choices draw as tabs. The colour control is the host's drum, so each camera keeps its
 * existing colour behaviour. SwiftUI twin: `CaptureCodecColorPanel`.
 */
@Composable
fun CaptureCodecColorPanel(
    choices: CaptureCodecColorChoices,
    enabled: Boolean,
    onSelectCodec: (String) -> Unit,
    codec: (@Composable () -> Unit)? = null,
    color: @Composable () -> Unit,
) {
    val labelled = choices.sections.size > 1
    Column(Modifier.fillMaxWidth().testTag("monitor.capture.codecColor"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        choices.sections.forEach { section ->
            CaptureCodecColorSectionView(section, labelled) {
                when (section) {
                    CaptureCodecColorSection.CODEC ->
                        codec?.invoke() ?: CaptureCodecColorTabs(choices.codecs, choices.selectedCodec, enabled, onSelectCodec)
                    CaptureCodecColorSection.COLOR -> color()
                }
            }
        }
    }
}

/**
 * One section of the codec and colour popup: its caption (when the popup shows more than one) and
 * its control. A host that draws the codec control itself (a ladder) appends the colour section
 * with this so both popups read the same. SwiftUI twin: `CaptureCodecColorSectionView`.
 */
@Composable
fun CaptureCodecColorSectionView(
    section: CaptureCodecColorSection,
    labelled: Boolean = true,
    content: @Composable () -> Unit,
) {
    val tag = if (section == CaptureCodecColorSection.CODEC) "codec" else "color"
    Column(Modifier.fillMaxWidth().testTag("monitor.capture.codecColor.$tag"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (labelled) {
            Text(
                tag.uppercase(),
                style = LiveType.ui(11f, FontWeight.SemiBold).copy(letterSpacing = .44.sp),
                color = LiveDesign.muted,
                modifier = Modifier.semantics { heading() },
            )
        }
        content()
    }
}

/**
 * Choices as tabs, stacked past three entries so long camera names stay legible. A non-editable
 * choice is shown dimmed and never sent.
 */
@Composable
fun CaptureCodecColorTabs(
    choices: List<CaptureCodecColorChoice>,
    selected: String?,
    enabled: Boolean,
    onSelect: (String) -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    val vertical = choices.size > 3
    val tab = @Composable { index: Int, choice: CaptureCodecColorChoice, modifier: Modifier ->
        val active = choice.id == selected
        MonitorTab(
            active,
            {
                if (enabled && !active && choice.isEditable) {
                    haptics.selection()
                    onSelect(choice.id)
                }
            },
            modifier.then(if (choice.isEditable) Modifier else Modifier.alpha(0.35f))
                .testTag("monitor.capture.codecColor.choice.${choice.id}"),
            enabled = enabled && choice.isEditable,
            vertical = vertical,
            separator = index > 0,
            accessibilityLabel = choice.label,
            horizontalPadding = 0.dp,
        ) {
            Text(
                choice.label.uppercase(),
                style = LiveType.ui(11f, FontWeight.SemiBold).copy(letterSpacing = .44.sp),
                color = if (active) LiveDesign.accent else LiveDesign.muted, maxLines = 1,
                textAlign = TextAlign.Center,
            )
        }
    }
    if (vertical) {
        Column(Modifier.fillMaxWidth().monitorTabStrip(vertical = true)) {
            choices.forEachIndexed { index, choice -> tab(index, choice, Modifier.fillMaxWidth()) }
        }
    } else {
        Row(Modifier.fillMaxWidth().monitorTabStrip()) {
            choices.forEachIndexed { index, choice -> tab(index, choice, Modifier.weight(1f)) }
        }
    }
}
