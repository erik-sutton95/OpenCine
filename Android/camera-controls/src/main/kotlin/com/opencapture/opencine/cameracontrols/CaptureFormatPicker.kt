package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.opencapture.opencine.vocabulary.VideoFormat

/** Image area and recording aspect are separate optional presentation facts. */
data class CaptureFormatGroup(val id: String, val title: String)

/** Indivisible supplied choice; the picker never synthesizes a camera command. */
data class CaptureFormatChoice<T>(
    val value: T,
    val title: String,
    val imageArea: CaptureFormatGroup? = null,
    val aspect: CaptureFormatGroup? = null,
    val resolution: CaptureFormatGroup? = null,
    val frameRate: CaptureFormatGroup? = null,
    val isEditable: Boolean = true,
) {
    val drumTitle: String get() = frameRate?.title ?: title
}

/** Local selection over exact tuples, without camera readback or write authority. */
data class CaptureFormatPickerState<T>(
    val imageArea: CaptureFormatGroup?,
    val aspect: CaptureFormatGroup?,
    val resolution: CaptureFormatGroup?,
    val value: T?,
) {
    fun visibleChoices(choices: List<CaptureFormatChoice<T>>) = choices.filter {
        it.imageArea == imageArea && it.aspect == aspect && it.resolution == resolution
    }

    fun aspects(choices: List<CaptureFormatChoice<T>>) = groups(choices.filter { it.imageArea == imageArea }.map { it.aspect })
    fun resolutions(choices: List<CaptureFormatChoice<T>>) = groups(choices.filter {
        it.imageArea == imageArea && it.aspect == aspect
    }.map { it.resolution })

    fun select(
        imageArea: CaptureFormatGroup?, aspect: CaptureFormatGroup?, resolution: CaptureFormatGroup?,
        choices: List<CaptureFormatChoice<T>>, enabled: Boolean,
    ): CaptureFormatChoice<T>? {
        if (!enabled) return null
        val previous = choices.firstOrNull { it.value == value }
        val inArea = choices.filter { it.imageArea == imageArea }
        if (inArea.isEmpty()) return null
        val aspects = groups(inArea.map { it.aspect })
        if (imageArea == this.imageArea && aspect != this.aspect && aspect !in aspects) return null
        val nextAspect = if (aspect in aspects) aspect else aspects.firstOrNull()
        val inAspect = inArea.filter { it.aspect == nextAspect }
        val sizes = groups(inAspect.map { it.resolution })
        if (imageArea == this.imageArea && aspect == this.aspect && resolution !in sizes) return null
        val nextResolution = if (resolution in sizes) resolution else
            sizes.firstOrNull { it?.title == resolution?.title } ?: sizes.firstOrNull()
        val candidates = inAspect.filter { it.resolution == nextResolution && it.isEditable }
        return (candidates.firstOrNull { it.frameRate == previous?.frameRate } ?: candidates.firstOrNull())
            ?.takeIf { it.value != value }
    }

    fun selectDrum(title: String, choices: List<CaptureFormatChoice<T>>, enabled: Boolean): CaptureFormatChoice<T>? {
        if (!enabled) return null
        val matches = visibleChoices(choices).filter { it.drumTitle == title }
        if (matches.map { it.value }.distinct().size != 1) return null
        return matches.firstOrNull { it.isEditable }?.takeIf { it.value != value }
    }

    companion object {
        fun groups(values: List<CaptureFormatGroup?>) = values.distinct()
        fun <T> seat(choices: List<CaptureFormatChoice<T>>, current: T?): CaptureFormatPickerState<T> {
            val reported = choices.firstOrNull { it.value == current }
            val seat = reported ?: choices.firstOrNull()
            return CaptureFormatPickerState(seat?.imageArea, seat?.aspect, seat?.resolution, reported?.value)
        }
        fun <T> selected(choice: CaptureFormatChoice<T>) =
            CaptureFormatPickerState(choice.imageArea, choice.aspect, choice.resolution, choice.value)
    }
}

/** Vocabulary projection uses the existing supplied fallback table and keeps current-only values inert. */
object CaptureVideoFormatChoices {
    fun make(available: List<VideoFormat>, current: VideoFormat?): List<CaptureFormatChoice<VideoFormat>> {
        val values = if (current != null && current !in available) listOf(current) + available else available
        return values.map { format ->
            CaptureFormatChoice(
                value = format, title = format.chipLabel,
                aspect = format.resolution.aspect?.let { CaptureFormatGroup(it.label, it.label) },
                resolution = CaptureFormatGroup(format.resolution.rawValue.toString(), format.resolution.tabTitle),
                frameRate = CaptureFormatGroup(format.frameRate.rawValue.toString(), format.frameRate.drumLabel),
                isEditable = format in available,
            )
        }
    }
}

/** Common format controls; callers retain admission, commands, refusal and readback. */
@Composable
fun <T> CaptureFormatPicker(
    choices: List<CaptureFormatChoice<T>>, current: T?, enabled: Boolean,
    sourceIdentity: Any?, followsReadback: Boolean = true, isCurrent: () -> Boolean,
    onSelect: (CaptureFormatChoice<T>) -> Unit,
) {
    val latestEnabled by rememberUpdatedState(enabled)
    val latestCurrent by rememberUpdatedState(isCurrent)
    val latestSelect by rememberUpdatedState(onSelect)
    key(sourceIdentity, choices) {
        var position by remember { mutableStateOf(CaptureFormatPickerState.seat(choices, current)) }
        LaunchedEffect(current, followsReadback) { if (followsReadback) position = CaptureFormatPickerState.seat(choices, current) }
        fun submit(next: CaptureFormatChoice<T>?) {
            if (next != null && latestEnabled && latestCurrent()) {
                position = CaptureFormatPickerState.selected(next)
                latestSelect(next)
            }
        }
        Column(Modifier.fillMaxWidth().testTag("monitor.capture.format.groups"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val visible = position.visibleChoices(choices)
            key(position.imageArea, position.aspect, position.resolution, enabled) {
                CaptureDrumWheel(
                options = visible.map { it.drumTitle },
                selection = visible.firstOrNull { it.value == position.value }?.drumTitle.orEmpty(),
                interactive = enabled && visible.any { it.isEditable },
                onSelect = { title -> submit(position.selectDrum(title, choices, latestEnabled && latestCurrent())) },
                )
            }
            val areas = CaptureFormatPickerState.groups(choices.map { it.imageArea })
            if (areas.any { it != null }) ModeBar(areas.map { it?.title ?: "Other" }, areas.indexOf(position.imageArea), enabled) { index ->
                submit(position.select(areas[index], position.aspect, position.resolution, choices, latestEnabled && latestCurrent()))
            }
            val aspects = position.aspects(choices)
            if (aspects.size > 1) ModeBar(aspects.map { it?.title ?: "Other" }, aspects.indexOf(position.aspect), enabled, uppercase = false) { index ->
                submit(position.select(position.imageArea, aspects[index], position.resolution, choices, latestEnabled && latestCurrent()))
            }
            val sizes = position.resolutions(choices)
            if (sizes.isNotEmpty()) ModeBar(sizes.map { it?.title ?: "Other" }, sizes.indexOf(position.resolution), enabled) { index ->
                submit(position.select(position.imageArea, position.aspect, sizes[index], choices, latestEnabled && latestCurrent()))
            }
        }
    }
}
