package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorTab
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.monitorui.monitorScrollFade
import com.opencapture.monitorui.monitorTabStrip
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.opencine.vocabulary.MediaLibraryQuery
import com.opencapture.opencine.vocabulary.MediaLibrarySort
import com.opencapture.opencine.vocabulary.MediaLibraryTab
import kotlin.math.roundToInt

val MediaCapsuleShape: RoundedCornerShape = RoundedCornerShape(percent = 50)

val MediaCornerShape: RoundedCornerShape = ChromeShape

/**
 * True where the app draws media chrome over its live backdrop glass (it provides this beside its own
 * glass); the media buttons then use the compact material, and the panel plate otherwise.
 */
val LocalMediaBackdropGlass = compositionLocalOf { false }

@Composable
private fun Modifier.mediaGlass(shape: Shape): Modifier =
    if (LocalMediaBackdropGlass.current) monitorMaterial(MonitorMaterial.Compact, shape) else mediaPanelGlass(shape)

private fun Modifier.mediaPanelGlass(shape: Shape): Modifier =
    background(LiveDesign.surface, shape).border(1.dp, LiveDesign.hairline, shape)

@Composable
fun MediaCatalogDisplayControls(
    list: Boolean,
    thumbnailSize: MediaThumbnailSize,
    onList: (Boolean) -> Unit,
    onThumbnailSize: (MediaThumbnailSize) -> Unit,
) {
    com.opencapture.monitorui.MonitorCatalogDisplayControls(
        list = list,
        thumbnailSize = com.opencapture.monitorui.MonitorThumbnailSize.valueOf(thumbnailSize.name),
        onList = onList,
        onThumbnailSize = { onThumbnailSize(MediaThumbnailSize.valueOf(it.name)) },
    )
}

@Composable
fun MediaCategoryStrip(category: MediaLibraryTab, onSelect: (MediaLibraryTab) -> Unit) {
    val scroll = rememberScrollState()
    Row(Modifier.monitorScrollFade(scroll, vertical = false).horizontalScroll(scroll).monitorTabStrip()) {
        MediaLibraryTab.entries.forEach { tab ->
            MediaCategoryTab(tab, active = tab == category) { onSelect(tab) }
        }
    }
}

@Composable
fun MediaCategoryTab(tab: MediaLibraryTab, active: Boolean, fill: Boolean = false, onClick: () -> Unit) {
    val haptics = LocalOperatorHaptics.current
    val label =
        when (tab) {
            MediaLibraryTab.ALL -> "All"
            MediaLibraryTab.VIDEOS -> "Videos"
            MediaLibraryTab.PHOTOS -> "Photos"
            MediaLibraryTab.FAVORITES -> "Favorites"
        }
    MonitorTab(active, { haptics.selection(); onClick() }, Modifier.then(if (fill) Modifier.fillMaxWidth() else Modifier),
        vertical = fill, separator = tab != MediaLibraryTab.entries.first(),
        accessibilityLabel = "Show $label media") {
        Row(Modifier.then(if (fill) Modifier.fillMaxWidth() else Modifier),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            // iOS category tabs carry no glyph.
            Text(label, color = if (active) LiveDesign.accent else LiveDesign.muted,
                style = LiveType.ui(12f, if (active) FontWeight.SemiBold else FontWeight.Medium))
        }
    }
}

@Composable
fun MediaCatalogHeaderRow(
    headerTitle: String, headerCount: String, fetchInProgress: Boolean, isLive: Boolean,
    isSelecting: Boolean, sortOrder: MediaLibrarySort, filterOpen: Boolean, activeFilterCount: Int,
    onFilter: () -> Unit, onSort: () -> Unit, compact: Boolean,
) {
    com.opencapture.monitorui.MonitorCatalogHeader(
        title = "$headerTitle · $headerCount",
        subtitle = when {
            fetchInProgress -> "Reading camera media…"
            isSelecting -> "Swipe to scroll · Hold or drag sideways to select"
            isLive -> "Tap to open · Hold, then drag to select"
            else -> "Available offline"
        },
        compact = compact, sort = sortOrder.menuLabel,
        filterActive = filterOpen || activeFilterCount > 0,
        filterCount = activeFilterCount,
        onSort = onSort, onFilter = onFilter)
}

@Composable
fun MediaSelectionTray(count: Int, cacheEnabled: Boolean, deleteEnabled: Boolean,
    onAll: () -> Unit, onClear: () -> Unit, onCache: () -> Unit, onStar: () -> Unit,
    onDelete: () -> Unit, onShare: () -> Unit) {
    com.opencapture.monitorui.MonitorSelectionTray(count) {
        TrayTextChip(MonitorIcon.CIRCLE_CHECK, "All", LiveDesign.accent, onAll)
        TrayTextChip(MonitorIcon.X, "Clear", LiveDesign.muted, onClear)
        MediaCircleIconButton(MonitorIcon.DOWNLOAD, "Cache selected clips", onCache, enabled = cacheEnabled, size = 34.dp)
        MediaCircleIconButton(MonitorIcon.STAR, "Favorite selected clips", onStar, enabled = count > 0, size = 34.dp)
        MediaCircleIconButton(MonitorIcon.TRASH, "Delete selected clips", onDelete, enabled = deleteEnabled, size = 34.dp)
        MediaCircleIconButton(MonitorIcon.SHARE, "Share selected clips", onShare, enabled = count > 0, size = 34.dp)
    }
}

@Composable
private fun TrayTextChip(icon: MonitorIcon, label: String, tint: Color, onClick: () -> Unit) {
    Row(Modifier.height(34.dp).chromeClickable(onClick = onClick).padding(horizontal = 7.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        MonitorIcon(icon, null, Modifier.size(13.dp), tint)
        Text(label, color = tint, style = LiveType.ui(11f, FontWeight.SemiBold))
    }
}

@Composable
fun MediaCacheBar(filename: String, progress: Double) {
    Row(
        Modifier
            .padding(top = 8.dp)
            .fillMaxWidth()
            .clip(MediaCapsuleShape)
            .mediaPanelGlass(MediaCapsuleShape)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        com.opencapture.monitorui.MonitorMediaProgressTrack(progress.toFloat(), trackWidth = 120.dp)
        Text(
            "CACHING $filename ${(progress * 100).toInt()}%",
            color = LiveDesign.muted,
            fontSize = 10.sp,
            fontFamily = MonitorTypography.fontFamily,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
        )
    }
}

@Composable
fun MediaScrollablePlaceholder(content: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxWidth().heightIn(min = maxHeight).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) { content() }
    }
}

@Composable
fun MediaEmptyState(listing: Boolean, subtitle: String) {
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (listing) {
            CircularProgressIndicator(color = LiveDesign.accent)
        } else {
            MonitorIcon(
                icon = MonitorIcon.FILM,
                contentDescription = null,
                tint = LiveDesign.faint,
                modifier = Modifier.size(40.dp),
            )
        }
        Text(
            if (listing) "Listing clips" else "No clips yet",
            color = LiveDesign.muted,
            style = LiveType.ui(15f, FontWeight.Medium),
            modifier = Modifier.padding(top = 12.dp),
        )
        Text(
            subtitle,
            color = LiveDesign.faint,
            style = LiveType.ui(12f),
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 4.dp),
        )
    }
}

@Composable
fun MediaListingState(listed: Int) {
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator(color = LiveDesign.muted)
        Text("Listing clips on camera…", color = LiveDesign.muted, style = LiveType.ui(15f, FontWeight.Medium), modifier = Modifier.padding(top = 12.dp))
        Text(
            if (listed == 0) "Querying card storage…"
            else "$listed clip${if (listed == 1) "" else "s"} found so far",
            color = LiveDesign.faint,
            style = LiveType.ui(12f),
        )
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun MediaFilterPopup(
    formatOptions: List<String>,
    resolutionOptions: List<String>,
    colorOptions: List<Pair<Int, String>>,
    hasDates: Boolean,
    formatFilters: Set<String>,
    resolutionFilters: Set<String>,
    colorFilters: Set<Int>,
    dateStartKey: String?,
    dateEndKey: String?,
    onToggleFormat: (String) -> Unit,
    onToggleResolution: (String) -> Unit,
    onToggleColor: (Int) -> Unit,
    onDateStart: (String?) -> Unit,
    onDateEnd: (String?) -> Unit,
    onClear: () -> Unit,
    onClose: () -> Unit,
) {
    var pickingBound by remember { mutableStateOf<String?>(null) }
    val density = androidx.compose.ui.platform.LocalDensity.current
    val layoutDirection = androidx.compose.ui.platform.LocalLayoutDirection.current
    val insets = WindowInsets.safeDrawing
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val card = com.opencapture.monitorui.MonitorLayoutPolicy.mediaFilterPopup(
            maxWidth.value, maxHeight.value,
            insets.getTop(density) / density.density,
            insets.getLeft(density, layoutDirection) / density.density,
            insets.getBottom(density) / density.density,
            insets.getRight(density, layoutDirection) / density.density,
        )
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.18f))
                .clickable(onClick = onClose),
        )
        val filterScroll = rememberScrollState()
        Column(
            Modifier
                .absoluteOffset { IntOffset((card.x * density.density).roundToInt(), (card.y * density.density).roundToInt()) }
                .width(card.width.dp)
                .height(card.height.dp)
                .clip(MediaCornerShape)
                .mediaPanelGlass(MediaCornerShape)
                .padding(16.dp)
                .monitorScrollFade(filterScroll)
                .verticalScroll(filterScroll)
                .semantics { contentDescription = "Filter popup" },
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "FILTER",
                    color = LiveDesign.muted,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = MonitorTypography.fontFamily,
                    letterSpacing = 0.8.sp,
                )
                Spacer(Modifier.weight(1f))
                MediaCloseButton(onClick = onClose, size = 26.dp)
            }
            Spacer(Modifier.height(10.dp))
            com.opencapture.monitorui.MonitorMediaFilterForm(
                formats = formatOptions,
                resolutions = resolutionOptions,
                colors = colorOptions.map { com.opencapture.monitorui.MonitorMediaColorOption(it.first, it.second) },
                formatSelection = formatFilters,
                resolutionSelection = resolutionFilters,
                colorSelection = colorFilters,
                dateStartLabel = dateStartKey?.let { MediaClipPresentation.dateLabel(it) },
                dateEndLabel = dateEndKey?.let { MediaClipPresentation.dateLabel(it) },
                hasDates = hasDates,
                onToggleFormat = onToggleFormat,
                onToggleResolution = onToggleResolution,
                onToggleColor = onToggleColor,
                onPickStart = { pickingBound = "start" },
                onPickEnd = { pickingBound = "end" },
                onClear = onClear,
            )
        }
        pickingBound?.let { bound ->
            key(bound) {
                val isStart = bound == "start"
                val current = if (isStart) dateStartKey else dateEndKey
                val pickerState = rememberDatePickerState(
                    initialSelectedDateMillis = current?.let { MediaLibraryQuery.millisFromDateKey(it) },
                )
                DatePickerDialog(
                    onDismissRequest = { pickingBound = null },
                    confirmButton = {
                        TextButton(onClick = {
                            pickerState.selectedDateMillis?.let { millis ->
                                val key = MediaLibraryQuery.dateKeyFromMillis(millis)
                                if (isStart) onDateStart(key) else onDateEnd(key)
                            }
                            pickingBound = null
                        }) { Text("Done") }
                    },
                    dismissButton = {
                        TextButton(onClick = {
                            if (isStart) onDateStart(null) else onDateEnd(null)
                            pickingBound = null
                        }) { Text("Clear") }
                    },
                ) {
                    DatePicker(pickerState)
                }
            }
        }
    }
}

@Composable
fun MediaCloseButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 37.dp,
    enabled: Boolean = true,
) {
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .mediaGlass(CircleShape)
            .chromeClickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = "Close" },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(
            icon = MonitorIcon.X,
            contentDescription = null,
            tint = LiveDesign.text,
            modifier = Modifier.size(size * 0.30f),
        )
    }
}

@Composable
fun MediaCircleIconButton(
    icon: MonitorIcon,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 34.dp,
    iconSize: Dp = size * 0.47f,
    tint: androidx.compose.ui.graphics.Color = LiveDesign.text,
    enabled: Boolean = true,
    highlighted: Boolean = false,
    filled: Boolean = false,
) {
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .then(if (highlighted) Modifier.background(LiveDesign.accentDim, CircleShape) else Modifier)
            .mediaGlass(CircleShape)
            .chromeClickable(enabled = enabled, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(
            icon = icon,
            contentDescription = null,
            tint = if (!enabled) LiveDesign.faint else if (highlighted) LiveDesign.accent else tint,
            modifier = Modifier.size(iconSize),
            filled = filled,
        )
    }
}
