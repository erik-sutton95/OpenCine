package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorQuickPreview
import com.opencapture.monitorui.MonitorTab
import com.opencapture.monitorui.monitorTabStrip
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.opencine.cameracontrols.CaptureFocusChoices
import com.opencapture.opencine.cameracontrols.chromeClickable
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.LadderSheetPresentation
import com.opencapture.opencine.vocabulary.LadderTab

val LocalCapturePreview = staticCompositionLocalOf<MonitorQuickPreview?> { null }

val LocalViewportPortrait = staticCompositionLocalOf { true }

@Composable
fun viewportIsPortrait(): Boolean = LocalViewportPortrait.current

fun capturePanelShape(fromTop: Boolean, portrait: Boolean): RoundedCornerShape {
    val top = com.opencapture.monitorui.MonitorLayoutPolicy.capturePanelTopCorner(fromTop, portrait).dp
    val bottom = com.opencapture.monitorui.MonitorLayoutPolicy.capturePanelBottomCorner(fromTop, portrait).dp
    return RoundedCornerShape(topStart = top, topEnd = top, bottomStart = bottom, bottomEnd = bottom)
}

@Composable
fun SheetHeader(title: String, subtitle: String, onClose: () -> Unit,
    showsClose: Boolean = true) {
    com.opencapture.opencine.appkit.MonitorOperatorCaptureHeader(title, subtitle, onClose,
        showsClose, enabled = LocalCapturePreview.current == null)
}

@Composable
fun ModeBar(
    tabs: List<String>,
    selected: Int,
    enabled: Boolean,
    uppercase: Boolean = true,
    /** A second line under a tab's title (a base ISO's range); null for none. */
    details: List<String?> = emptyList(),
    /** Tabs the camera refuses now: dimmed and inert. */
    disabled: Set<Int> = emptySet(),
    onSelect: (Int) -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    Row(Modifier.fillMaxWidth().monitorTabStrip()) {
        tabs.forEachIndexed { index, title ->
            val active = index == selected
            val off = index in disabled
            MonitorTab(active, { haptics.selection(); onSelect(index) },
                Modifier.weight(1f).then(if (off) Modifier.alpha(0.35f) else Modifier), enabled = enabled && !off,
                separator = index > 0, accessibilityLabel = title, horizontalPadding = 0.dp) {
                val label = @Composable {
                    Text(if (uppercase) title.uppercase() else title,
                        style = LiveType.ui(11f, FontWeight.SemiBold).copy(letterSpacing = .44.sp),
                        color = if (active) LiveDesign.accent else LiveDesign.muted, maxLines = 1,
                        textAlign = TextAlign.Center)
                }
                val detail = details.getOrNull(index)
                if (detail == null) label() else Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    label()
                    Text(detail, style = LiveType.mono(9.5f), color = if (active) LiveDesign.accent else LiveDesign.faint,
                        maxLines = 1)
                }
            }
        }
    }
}

@Composable
fun CheckedRows(
    options: List<String>,
    selected: String?,
    enabled: Boolean,
    onSelect: (String) -> Unit,
) {
    var shown by remember(options) { mutableStateOf(selected.orEmpty()) }
    LaunchedEffect(selected) {
        if (!selected.isNullOrEmpty() && selected != shown) shown = selected
    }
    CaptureDrumWheel(options, shown, interactive = enabled, onSelect = { value ->
        if (value != shown) {
            shown = value
            onSelect(value)
        }
    })
}

@Composable
fun PrefToggle(
    title: String,
    help: String,
    checked: Boolean,
    enabled: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val preview = LocalCapturePreview.current
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp)
        .chromeClickable(enabled = enabled && preview == null) { if (enabled && preview == null) onCheckedChange(!checked) }
        .semantics { role = Role.Switch; toggleableState = ToggleableState(checked) }
        .alpha(if (enabled || preview != null) 1f else .45f),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = LiveType.ui(11.5f, FontWeight.SemiBold))
            Text(help, style = LiveType.ui(9.5f).copy(lineHeight = 13.3.sp), color = LiveDesign.faint)
        }
        CaptureSwitchGraphic(checked)
    }
}

@Composable
fun CaptureSwitchGraphic(isOn: Boolean) {
    Box(
        Modifier
            .width(38.dp)
            .height(22.dp)
            .clip(RoundedCornerShape(50))
            .background(if (isOn) LiveDesign.accentDim else LiveDesign.surface)
            .border(1.dp, if (isOn) LiveDesign.accentDim else LiveDesign.hairline, RoundedCornerShape(50)),
    ) {
        Box(
            Modifier
                .align(if (isOn) Alignment.CenterEnd else Alignment.CenterStart)
                .padding(2.dp)
                .size(18.dp)
                .clip(CircleShape)
                .background(LiveDesign.text),
        )
    }
}

/** Camera mapping stays above this shared, presentation-only horizontal drum. */
@Composable
fun CaptureDrumWheel(
    options: List<String>, selection: String, markedValues: Set<String> = emptySet(),
    interactive: Boolean = true,
    onSelect: (String) -> Unit,
) {
    val preview = LocalCapturePreview.current
    val shown = preview?.selection ?: selection
    LadderSheet(
        presentation = LadderSheetPresentation("", "", listOf(
            LadderTab("", 0, CaptureLadder(shown.takeIf { it.isNotEmpty() },
                preview?.control?.options ?: options, preview?.control?.marked ?: markedValues),
                applyOnActivate = false))),
        enabled = interactive, onWrite = { write ->
            if (interactive && preview == null) onSelect(write.value)
        }, onClose = {}, chromeless = true,
        host = LadderSheetHost(0, shown, LadderSheetDrum.Labels,
            previewPosition = preview?.position, onSelectTab = {}))
}

@Composable
fun FocusBody(status: CameraStatus, labels: List<String> = CaptureFocusChoices.labels, enabled: Boolean, onSelect: (String) -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CaptureDrumWheel(labels, CaptureFocusChoices.selection(status, labels), interactive = enabled, onSelect = onSelect)
        Text("AF-S focuses once. AF-C follows focus continuously; the other modes use the camera's supported tracking modes.",
            style = LiveType.ui(9.5f).copy(lineHeight = 13.3.sp), color = LiveDesign.faint)
    }
}
