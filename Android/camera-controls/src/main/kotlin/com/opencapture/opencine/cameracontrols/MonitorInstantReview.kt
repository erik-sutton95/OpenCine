package com.opencapture.opencine.cameracontrols

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.LocalMonitorAssistVisible
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorInstantReviewLayout as Layout
import com.opencapture.monitorui.MonitorRect

/** Test and automation identifiers of the instant review (iOS `accessibilityIdentifier`s). */
object MonitorInstantReviewIds {
    const val REVIEW = "monitor.instantReview"
    const val CLOSE = "monitor.instantReview.close"
    const val FAVORITE = "monitor.instantReview.favorite"
    const val INFO = "monitor.instantReview.info"
}

/**
 * Hosts the monitor beneath an instant review. The assist palette floats in its own popup window,
 * and a popup window always draws above the activity's content: while [presented] the palette
 * renders inside the monitor's window instead, so the full-screen review covers it exactly as on
 * iOS. Wrap the live monitor (not the review) in this.
 */
@Composable
fun MonitorInstantReviewHost(presented: Boolean, content: @Composable () -> Unit) {
    val visible = LocalMonitorAssistVisible.current && Layout.assistPaletteMayFloat(presented)
    CompositionLocalProvider(LocalMonitorAssistVisible provides visible, content = content)
}

/**
 * The post-capture instant review, the one component every app shows after a still capture. The
 * captured still fills the whole monitor over black, above every piece of chrome; a tap anywhere
 * or the close button dismisses it (the host owns the timed dismissal). While the embedded
 * stand-in thumb shows, it is blurred behind a spinner and the blur clears as the sharp still
 * swaps in. The favorite star (absent when [favorited] is null: nothing on the card to rate)
 * stacks over the capture settings line at the bottom. [marks] draws over the fitted still (AF
 * boxes), given its frame in this container's points. Swift twin: `MonitorInstantReview`.
 */
@Composable
fun MonitorInstantReview(
    image: ImageBitmap,
    isFullResolution: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    /** The still's displayed width over height (de-squeezed); null uses the bitmap's own. */
    displayAspect: Float? = null,
    favorited: Boolean? = null,
    onToggleFavorite: (Boolean) -> Unit = {},
    infoLine: String? = null,
    marks: @Composable BoxScope.(fitted: MonitorRect) -> Unit = {},
) {
    val blur by animateDpAsState(if (isFullResolution) 0.dp else Layout.STAND_IN_BLUR.dp,
        tween(Layout.SHARPEN_MILLIS), label = "instantReviewSharpen")
    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(Color.Black)
            .clickable(remember { MutableInteractionSource() }, indication = null, onClick = onDismiss)
            .testTag(MonitorInstantReviewIds.REVIEW)
            .semantics { contentDescription = "Instant playback" },
    ) {
        val aspect = displayAspect?.takeIf { it.isFinite() && it > 0f }
        val fitted = Layout.imageFrame(aspect ?: image.width.toFloat(), if (aspect != null) 1f else image.height.toFloat(),
            maxWidth.value, maxHeight.value)
        Image(
            bitmap = image,
            contentDescription = null,
            // The fitted frame already carries the display aspect, so a squeezed still stretches into it.
            contentScale = ContentScale.FillBounds,
            modifier = Modifier.offset(fitted.x.dp, fitted.y.dp).size(fitted.width.dp, fitted.height.dp)
                .clipToBounds().blur(blur),
        )
        marks(fitted)
        if (!isFullResolution) {
            CircularProgressIndicator(
                color = LiveDesign.text.copy(alpha = 0.9f),
                strokeWidth = 3.dp,
                modifier = Modifier.align(Alignment.Center).size(Layout.SPINNER_SIZE.dp),
            )
        }
        Column(
            Modifier.align(Alignment.BottomCenter).padding(bottom = Layout.BOTTOM_INSET.dp),
            verticalArrangement = Arrangement.spacedBy(Layout.STACK_SPACING.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            favorited?.let { starred ->
                Box(
                    Modifier.size(Layout.FAVORITE_SIZE.dp)
                        .background(LiveDesign.surface, CircleShape)
                        .border(1.dp, LiveDesign.hairline, CircleShape)
                        .chromeClickable { onToggleFavorite(!starred) }
                        .testTag(MonitorInstantReviewIds.FAVORITE)
                        .semantics {
                            contentDescription = if (starred) "Remove favorite star" else "Favorite this shot"
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    MonitorIcon(MonitorIcon.STAR, null, Modifier.size(Layout.FAVORITE_GLYPH_SIZE.dp),
                        tint = if (starred) LiveDesign.accent else LiveDesign.text.copy(alpha = 0.85f), filled = starred)
                }
            }
            infoLine?.let { info ->
                Text(
                    info,
                    style = LiveType.mono(Layout.INFO_FONT_SIZE, FontWeight.SemiBold),
                    color = LiveDesign.text.copy(alpha = 0.85f),
                    maxLines = 1,
                    modifier = Modifier
                        .background(LiveDesign.surface, CircleShape)
                        .border(1.dp, LiveDesign.hairline, CircleShape)
                        .padding(horizontal = Layout.INFO_HORIZONTAL_PADDING.dp, vertical = Layout.INFO_VERTICAL_PADDING.dp)
                        .testTag(MonitorInstantReviewIds.INFO),
                )
            }
        }
        LivePopupCloseButton(
            onClick = onDismiss,
            size = Layout.CLOSE_SIZE.dp,
            modifier = Modifier.align(Alignment.TopEnd)
                .padding(top = Layout.CLOSE_INSET.dp, end = Layout.CLOSE_INSET.dp)
                .testTag(MonitorInstantReviewIds.CLOSE),
        )
    }
}
