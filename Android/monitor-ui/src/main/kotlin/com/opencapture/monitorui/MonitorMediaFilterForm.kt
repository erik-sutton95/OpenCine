package com.opencapture.monitorui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.clickable
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.offset
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Immutable
data class MonitorMediaColorOption(val id: Int, val label: String)

/** The source owns identity; labels never determine the value sent to its action. */
@Immutable
data class MonitorMediaFilterChoice(val id: String, val label: String)

/** Multiple supplied photo-size choices; the host owns selection and filtering. */
@Immutable
data class MonitorMediaPhotoSizeChoices(
    val options: List<MonitorMediaFilterChoice>,
    val selectedIds: Set<String>,
    val onToggle: (String) -> Unit,
)

/** Exclusive supplied relative windows; the host computes their date boundaries. */
@Immutable
data class MonitorMediaDateWindowChoices(
    val options: List<MonitorMediaFilterChoice>,
    val selectedId: String?,
    val onToggle: (String) -> Unit,
)

/** Observed volumes with source identities; an absent input omits storage filtering. */
@Immutable
data class MonitorMediaStorageChoices(
    val options: List<MonitorMediaFilterChoice>,
    val selectedId: String?,
    val onToggle: (String) -> Unit,
)

/** The default retains each platform's existing arrangement. */
enum class MonitorMediaFilterChipLayout { PLATFORM_DEFAULT, HORIZONTAL_SCROLL }

@Composable
fun MonitorMediaFilterForm(
    formats: List<String>,
    resolutions: List<String>,
    colors: List<MonitorMediaColorOption>,
    formatSelection: Set<String>,
    resolutionSelection: Set<String>,
    colorSelection: Set<Int>,
    dateStartLabel: String?,
    dateEndLabel: String?,
    hasDates: Boolean,
    onToggleFormat: (String) -> Unit,
    onToggleResolution: (String) -> Unit,
    onToggleColor: (Int) -> Unit,
    onPickStart: () -> Unit,
    onPickEnd: () -> Unit,
    onClear: () -> Unit,
    photoSizes: MonitorMediaPhotoSizeChoices? = null,
    dateWindows: MonitorMediaDateWindowChoices? = null,
    storage: MonitorMediaStorageChoices? = null,
    chipLayout: MonitorMediaFilterChipLayout = MonitorMediaFilterChipLayout.PLATFORM_DEFAULT,
    showsInlineClear: Boolean = true,
    // A source can retain an active filter while its available choices are hidden.
    hasActiveFilters: Boolean? = null,
) {
    val empty = formats.isEmpty() && resolutions.isEmpty() && !hasDates && colors.isEmpty() &&
        photoSizes?.options.isNullOrEmpty() && dateWindows?.options.isNullOrEmpty() && storage?.options.isNullOrEmpty()
    val active = hasActiveFilters ?: (formatSelection.isNotEmpty() || resolutionSelection.isNotEmpty() ||
        colorSelection.isNotEmpty() || dateStartLabel != null || dateEndLabel != null ||
        !photoSizes?.selectedIds.isNullOrEmpty() || dateWindows?.selectedId != null || storage?.selectedId != null)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (formats.isNotEmpty()) FilterChips("FORMAT", formats, formatSelection, chipLayout, onToggleFormat)
        if (resolutions.isNotEmpty()) FilterChips("RESOLUTION", resolutions, resolutionSelection, chipLayout, onToggleResolution)
        photoSizes?.takeIf { it.options.isNotEmpty() }?.let {
            FilterChoices("SIZE", it.options, it.selectedIds, chipLayout, it.onToggle)
        }
        dateWindows?.takeIf { it.options.isNotEmpty() }?.let {
            FilterChoices("DATE", it.options, setOfNotNull(it.selectedId), chipLayout, it.onToggle)
        }
        if (hasDates) {
            FilterHeading("DATE")
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                FilterDateChip("Start", dateStartLabel, Modifier.weight(1f), onPickStart)
                Text("–", color = MonitorPalette.muted, style = MonitorTypography.text(10.5f, FontWeight.SemiBold))
                FilterDateChip("End", dateEndLabel, Modifier.weight(1f), onPickEnd)
            }
        }
        if (colors.isNotEmpty()) {
            FilterChips("COLOUR", colors.map { it.label }, colors.filter { it.id in colorSelection }.map { it.label }.toSet(), chipLayout) { title ->
                colors.firstOrNull { it.label == title }?.let { onToggleColor(it.id) }
            }
        }
        storage?.takeIf { it.options.isNotEmpty() }?.let {
            FilterChoices("STORAGE", it.options, setOfNotNull(it.selectedId), chipLayout, it.onToggle)
        }
        if (empty) {
            Text("Nothing in this tab to filter by.", color = MonitorPalette.faint, style = MonitorTypography.text(11f))
        }
        if (showsInlineClear && active) {
            Text(
                "Clear all filters",
                color = MonitorPalette.accent,
                style = MonitorTypography.text(11f, FontWeight.SemiBold),
                modifier = Modifier.padding(top = 2.dp).clickable(onClick = onClear).testTag("monitor.media.filter.clear"),
            )
        }
    }
}

@Composable
private fun FilterHeading(title: String) {
    Text(title, color = MonitorPalette.muted, style = MonitorTypography.text(9f, FontWeight.Bold),
        modifier = Modifier.padding(bottom = 5.dp))
}

@Composable
private fun FilterChips(title: String, titles: List<String>, active: Set<String>, layout: MonitorMediaFilterChipLayout, onToggle: (String) -> Unit) {
    FilterChoices(title, titles.map { MonitorMediaFilterChoice(it, it) }, active, layout, onToggle)
}

@Composable
private fun FilterChoices(title: String, choices: List<MonitorMediaFilterChoice>, active: Set<String>, layout: MonitorMediaFilterChipLayout, onToggle: (String) -> Unit) {
    Column(Modifier.padding(bottom = 2.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        FilterHeading(title)
        if (layout == MonitorMediaFilterChipLayout.HORIZONTAL_SCROLL) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 44.dp).horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                choices.forEach { choice -> FilterChoice(title, choice, choice.id in active, true, onToggle) }
            }
        } else {
            choices.forEach { choice -> FilterChoice(title, choice, choice.id in active, false, onToggle) }
        }
    }
}

@Composable
private fun FilterChoice(group: String, choice: MonitorMediaFilterChoice, active: Boolean, horizontal: Boolean, onToggle: (String) -> Unit) {
    Text(
        choice.label,
        color = if (active) MonitorPalette.accent else MonitorPalette.muted,
        style = MonitorTypography.text(10f, FontWeight.SemiBold),
        modifier = (if (horizontal) Modifier.filterChoiceClickable { onToggle(choice.id) } else Modifier.fillMaxWidth())
            .clip(RoundedCornerShape(999.dp))
            .background(if (active) MonitorPalette.accent.copy(alpha = .14f) else Color.White.copy(alpha = .04f))
            .then(if (horizontal) Modifier else Modifier.clickable { onToggle(choice.id) })
            .semantics {
                selected = active
                if (horizontal) {
                    contentDescription = "${choice.label} filter"
                    role = Role.Checkbox
                }
            }
            .testTag("monitor.media.filter.${group.lowercase()}.${choice.id}")
            .padding(horizontal = if (horizontal) 12.dp else 8.dp, vertical = 8.dp),
    )
}

@Composable
private fun FilterDateChip(title: String, label: String?, modifier: Modifier, onClick: () -> Unit) {
    Text(
        label ?: title,
        color = if (label == null) MonitorPalette.muted else MonitorPalette.text,
        style = MonitorTypography.text(10.5f, FontWeight.SemiBold),
        modifier = modifier
            .clip(RoundedCornerShape(9.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .clickable(onClick = onClick)
            .semantics { contentDescription = title }
            .heightIn(min = 34.dp)
            .padding(horizontal = 11.dp, vertical = 8.dp),
    )
}

/** Keep the drawn capsule compact while reporting its full 44dp native target to the scroll viewport. */
@Composable
private fun Modifier.filterChoiceClickable(onClick: () -> Unit): Modifier {
    val minimum = with(LocalDensity.current) { 44.dp.roundToPx() }
    var drawn by remember { mutableStateOf(IntSize.Zero) }
    val x = if (drawn.width <= 0) 0 else ((minimum - drawn.width + 1) / 2).coerceAtLeast(0)
    val y = if (drawn.height <= 0) 0 else ((minimum - drawn.height + 1) / 2).coerceAtLeast(0)
    val expands = x > 0 || y > 0
    return this
        .monitorChromeClickable(onClick = onClick)
        .then(if (expands) Modifier.filterChoiceExpand(x, y) else Modifier)
        .onSizeChanged { size ->
            val next = if (size.width < minimum || size.height < minimum) size else IntSize.Zero
            if (next != drawn) drawn = next
        }
}

private fun Modifier.filterChoiceExpand(x: Int, y: Int): Modifier = layout { measurable, constraints ->
    val child = measurable.measure(constraints.offset(-2 * x, -2 * y))
    layout(child.width + 2 * x, child.height + 2 * y) { child.place(x, y) }
}
