package com.opencapture.monitorui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import androidx.lifecycle.findViewTreeLifecycleOwner
import kotlin.math.max

internal val LocalMonitorPlaybackSelectionFeedback = compositionLocalOf<() -> Unit> { {} }

/** One native pointer owns one typed edit, including native ACTION_CANCEL and context retirement. */
@Composable
fun MonitorPlaybackScrubber(progressSeconds: Float, durationSeconds: Float,
    item: MonitorPlaybackItemToken?,
    begin: (MonitorPlaybackItemToken) -> com.opencapture.opencine.media.MonitorPlaybackScrubToken?,
    update: (com.opencapture.opencine.media.MonitorPlaybackScrubToken, Double) -> Unit,
    commit: (com.opencapture.opencine.media.MonitorPlaybackScrubToken, Double) -> Unit,
    cancel: (com.opencapture.opencine.media.MonitorPlaybackScrubToken, MonitorEditingCancellation) -> Unit,
    modifier: Modifier = Modifier, bufferedFraction: Float = 0f) {
    val duration = max(0.1f, durationSeconds)
    val window = LocalWindowInfo.current.containerSize
    val latestItem by rememberUpdatedState(item)
    val latestDuration by rememberUpdatedState(durationSeconds)
    val latestWindow by rememberUpdatedState(window)
    val latestBegin by rememberUpdatedState(begin)
    val latestUpdate by rememberUpdatedState(update)
    val latestCommit by rememberUpdatedState(commit)
    val latestCancel by rememberUpdatedState(cancel)
    val editing = remember(item, durationSeconds, window) { MonitorPlaybackEditing() }
    val widthPx = remember { mutableFloatStateOf(1f) }
    val dragProgress = remember { mutableFloatStateOf(-1f) }
    val density = LocalDensity.current
    val trackHeight = with(density) { 4.dp.toPx() }
    val thumbSize = with(density) { 13.dp.toPx() }
    val hairline = MonitorPalette.border
    val accent = MonitorPalette.accent
    val display = if (dragProgress.floatValue >= 0f) dragProgress.floatValue else progressSeconds
    val fraction = (display / duration).coerceIn(0f, 1f)
    fun reason(): MonitorEditingCancellation =
        if (item != latestItem || durationSeconds != latestDuration) MonitorEditingCancellation.CONTEXT_CHANGED
        else MonitorEditingCancellation.INTERRUPTED
    fun abort(expected: com.opencapture.opencine.media.MonitorPlaybackScrubToken? = editing.token,
        why: MonitorEditingCancellation = reason()) {
        val admitted = expected?.let(editing::take) ?: return
        dragProgress.floatValue = -1f
        latestCancel(admitted, why)
    }
    DisposableEffect(editing) {
        onDispose { abort(why = if (window == latestWindow && item == latestItem) MonitorEditingCancellation.DISAPPEARED else reason()) }
    }
    val view = androidx.compose.ui.platform.LocalView.current
    DisposableEffect(view, editing) {
        val lifecycle = view.findViewTreeLifecycleOwner()?.lifecycle
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_PAUSE) abort(why = MonitorEditingCancellation.CONTEXT_CHANGED)
        }
        lifecycle?.addObserver(observer)
        onDispose { lifecycle?.removeObserver(observer) }
    }
    fun progressAt(x: Float): Float = (x / max(1f, widthPx.floatValue)).coerceIn(0f, 1f) * duration
    fun admit(): com.opencapture.opencine.media.MonitorPlaybackScrubToken? {
        val source = item ?: return null
        if (source != latestItem || editing.token != null) return null
        val edit = latestBegin(source)
        return if (editing.admit(edit, source)) edit else null
    }
    fun seek(target: Float) {
        val edit = admit() ?: return
        if (editing.take(edit) != null) latestCommit(edit, target.toDouble())
        dragProgress.floatValue = -1f
    }
    Canvas(modifier.fillMaxWidth().height(22.dp)
        .semantics {
            contentDescription = MonitorPlaybackCopy.POSITION
            stateDescription = MonitorPlaybackCopy.positionValue(display.toDouble())
            progressBarRangeInfo = ProgressBarRangeInfo(display.coerceIn(0f, duration), 0f..duration)
            setProgress { requested -> seek(requested.coerceIn(0f, duration)); true }
        }
        .pointerInput(editing) { detectTapGestures { seek(progressAt(it.x)) } }
        .pointerInput(editing) {
            var gestureEdit: com.opencapture.opencine.media.MonitorPlaybackScrubToken? = null
            try {
                detectHorizontalDragGestures(
                    onDragStart = { offset ->
                        gestureEdit = admit()
                        gestureEdit?.let { edit ->
                            val target = progressAt(offset.x); dragProgress.floatValue = target
                            latestUpdate(edit, target.toDouble())
                        }
                    },
                    onDragEnd = {
                        val edit = gestureEdit; gestureEdit = null
                        val owned = edit?.let(editing::take)
                        if (owned != null) {
                            val target = dragProgress.floatValue.takeIf { it >= 0f } ?: progressSeconds
                            latestCommit(owned, target.coerceIn(0f, duration).toDouble())
                        }
                        dragProgress.floatValue = -1f
                    },
                    onDragCancel = { val edit = gestureEdit; gestureEdit = null; if (edit != null) abort(edit) },
                    onHorizontalDrag = { change, _ ->
                        val edit = gestureEdit ?: return@detectHorizontalDragGestures
                        if (editing.token != edit) return@detectHorizontalDragGestures
                        change.consume()
                        val target = progressAt(change.position.x); dragProgress.floatValue = target
                        latestUpdate(edit, target.toDouble())
                    })
            } finally { gestureEdit?.let { abort(it) } }
        }) {
        widthPx.floatValue = size.width
        val cy = size.height / 2f
        val trackTop = cy - trackHeight / 2f
        drawRoundRect(hairline, Offset(0f, trackTop), Size(size.width, trackHeight), CornerRadius(trackHeight / 2f))
        if (bufferedFraction.isFinite() && bufferedFraction > 0f) {
            drawRoundRect(accent.copy(alpha = 0.32f), Offset(0f, trackTop),
                Size(size.width * bufferedFraction.coerceIn(0f, 1f), trackHeight), CornerRadius(trackHeight / 2f))
        }
        drawRoundRect(accent, Offset(0f, trackTop), Size(max(trackHeight, size.width * fraction), trackHeight), CornerRadius(trackHeight / 2f))
        drawCircle(Color.White, thumbSize / 2f, Offset((size.width * fraction).coerceIn(0f, size.width), cy))
    }
}

@Composable
fun MonitorPlaybackActionChip(
    icon: MonitorIcon,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    title: String? = null,
    active: Boolean = false,
    destructive: Boolean = false,
    filled: Boolean = false,
    enabled: Boolean = true,
    /** What a toggle chip announces after its label (`On`/`Off`), the twin of an iOS accessibility value. */
    state: String? = null,
    onClickFeedback: () -> Unit = LocalMonitorPlaybackSelectionFeedback.current,
    tint: Color = if (!enabled) MonitorPalette.faint else if (destructive) MonitorPalette.recording else if (active) MonitorPalette.accent else MonitorPalette.text.copy(alpha = 0.86f),
) {
    val shape = RoundedCornerShape(14f.dp)
    Row(
        modifier
            .height(44f.dp)
            .then(if (title == null) Modifier.width(44f.dp) else Modifier)
            .clip(shape)
            .then(
                when {
                    destructive -> Modifier.background(MonitorPalette.recording.copy(alpha = 0.12f), shape)
                    active -> Modifier.background(MonitorPalette.accent.copy(alpha = 0.22f), shape)
                    else -> Modifier
                },
            )
            .monitorMaterial(MonitorMaterial.Compact, shape)
            .then(
                when {
                    destructive -> Modifier.border(1.dp, MonitorPalette.recording.copy(alpha = 0.4f), shape)
                    active -> Modifier.border(1.dp, MonitorPalette.accent.copy(alpha = 0.5f), shape)
                    else -> Modifier
                },
            )
            .monitorChromeClickable(enabled = enabled, onClickFeedback = onClickFeedback, onClick = onClick)
            .semantics {
                this.contentDescription = contentDescription
                state?.let { this.stateDescription = it }
            }
            .padding(horizontal = if (title == null) 13.dp else 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        MonitorIcon(
            icon = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(18f.dp),
            filled = filled,
        )
        if (title != null) {
            Text(
                title,
                color = tint,
                style = MonitorTypography.text(12f, FontWeight.SemiBold),
            )
        }
    }
}


/** Actual cache/loading progress track, shared with the media library's remaining callers. */
@Composable
fun MonitorMediaProgressTrack(fraction: Float, modifier: Modifier = Modifier,
    trackWidth: Dp? = null, trackHeight: Dp = 4.dp) {
    val shape = RoundedCornerShape(percent = 50)
    Box(modifier
        .then(if (trackWidth != null) Modifier.width(trackWidth) else Modifier.fillMaxWidth())
        .height(trackHeight).clip(shape).background(MonitorPalette.border.copy(alpha = 0.55f), shape)) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0.05f, 1f)).fillMaxHeight().clip(shape)
            .background(MonitorPalette.accent, shape))
    }
}
