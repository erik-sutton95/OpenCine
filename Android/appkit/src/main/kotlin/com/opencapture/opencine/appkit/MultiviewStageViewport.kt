package com.opencapture.opencine.appkit

import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import com.opencapture.monitorui.MultiviewArrangement
import com.opencapture.monitorui.MultiviewPresentationLayout
import com.opencapture.monitorui.MultiviewSafeArea

/** Native window facts resolved once for the stage, its backdrop and its popups. */
public class MultiviewStageViewport(
    public val width: Float,
    public val height: Float,
    public val safeArea: MultiviewSafeArea,
    arrangement: MultiviewArrangement,
    selected: Int,
    topControlInset: Float = 0f,
) {
    public val layout: MultiviewPresentationLayout = MultiviewPresentationLayout.compute(
        width, height, safeArea, arrangement, selected, topControlInset,
    )
}

/** Android supplies asymmetric physical insets, including window caption controls, directly. */
@Composable
public fun MultiviewStageSurface(
    arrangement: MultiviewArrangement,
    selected: Int,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.(MultiviewStageViewport) -> Unit,
) {
    val density = LocalDensity.current
    val direction = LocalLayoutDirection.current
    val insets = WindowInsets.safeDrawing
    val safeArea = with(density) {
        MultiviewSafeArea(
            insets.getTop(this).toDp().value, insets.getLeft(this, direction).toDp().value,
            insets.getBottom(this).toDp().value, insets.getRight(this, direction).toDp().value,
        )
    }
    BoxWithConstraints(modifier.fillMaxSize()) {
        content(MultiviewStageViewport(maxWidth.value, maxHeight.value, safeArea, arrangement, selected))
    }
}
