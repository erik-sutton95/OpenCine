package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.monitorChromeClickable
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.opencine.appkit.LocalOperatorHaptics

/** The live chrome colors these views use, from the shared monitor palette (the apps' theme objects carry the same values). */
internal object LiveDesign {
    val background get() = MonitorPalette.background
    val surface get() = MonitorPalette.surface
    val text get() = MonitorPalette.text
    val secondary get() = MonitorPalette.secondary
    val muted get() = MonitorPalette.muted
    val faint get() = MonitorPalette.faint
    val hairline get() = MonitorPalette.border
    val accent get() = MonitorPalette.accent
    val accentDim get() = accent.copy(alpha = 0.16f)
    val glassBright = Color(94 / 255f, 98 / 255f, 98 / 255f, 0.18f)
    val aeLock = Color(0xFFF5D052)
    /** Clear and delete actions (the apps' `StartupColors.destructive`). */
    val destructive = Color(0.930f, 0.267f, 0.267f)

    const val CORNER_RADIUS_DP = 12f
}

/** One optical family for every surface (the apps' `LiveType`). */
internal object LiveType {
    fun ui(size: Float, weight: FontWeight = FontWeight.Normal) = MonitorTypography.text(size, weight)

    fun text(size: Float, weight: FontWeight = FontWeight.Normal) = MonitorTypography.text(size, weight)

    fun mono(size: Float, weight: FontWeight = FontWeight.Medium) =
        MonitorTypography.text(size, weight).copy(fontFeatureSettings = "tnum")
}

internal val ChromeShape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)

@Composable
internal fun Modifier.monitorGlass(shape: Shape = ChromeShape): Modifier = monitorMaterial(MonitorMaterial.Compact, shape)

@Composable
internal fun Modifier.pickerPanelGlass(shape: Shape = ChromeShape): Modifier = monitorMaterial(MonitorMaterial.Expanded, shape)

/** Live chrome press: the shared press look with the operator's selection and long-press haptics. */
@Composable
fun Modifier.chromeClickable(enabled: Boolean = true, onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit): Modifier {
    val haptics = LocalOperatorHaptics.current
    return this.monitorChromeClickable(
        enabled, onLongClick, { haptics.selection() }, { haptics.longPress() }, onClick)
}

/** iOS `CloseButton` on live picker / assist cards: 34dp glass circle. */
@Composable
fun LivePopupCloseButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 34.dp,
) {
    Box(
        modifier
            .size(size)
            .monitorGlass(CircleShape)
            .chromeClickable(onClick = onClick)
            .semantics { contentDescription = "Close" },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(
            icon = MonitorIcon.X,
            contentDescription = null,
            tint = LiveDesign.text,
            modifier = Modifier.size(size * 0.38f),
        )
    }
}
