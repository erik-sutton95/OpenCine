package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
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
internal fun Modifier.mediaGlass(shape: Shape): Modifier =
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
        subtitle = MediaLibraryCopy.galleryHint(fetchInProgress, isSelecting, isLive),
        compact = compact, sort = sortOrder.menuLabel,
        filterActive = filterOpen || activeFilterCount > 0,
        filterCount = activeFilterCount,
        onSort = onSort, onFilter = onFilter)
}

/** Selection actions name how many items they act on and where deletion happens (ZAB-440). */
internal fun selectionDeleteDescription(count: Int, enabled: Boolean): String =
    if (enabled) "Delete $count selected ${if (count == 1) "item" else "items"} from the camera card"
    else "Delete selected media"

internal fun selectionShareDescription(count: Int): String =
    "Share $count selected ${if (count == 1) "item" else "items"}"

@Composable
fun MediaSelectionTray(count: Int, cacheEnabled: Boolean, deleteEnabled: Boolean,
    onAll: () -> Unit, onClear: () -> Unit, onCache: () -> Unit, onStar: () -> Unit,
    onDelete: () -> Unit, onShare: () -> Unit, shareEnabled: Boolean = true) {
    com.opencapture.monitorui.MonitorSelectionTray(count) {
        TrayTextChip(MonitorIcon.CIRCLE_CHECK, "All", "Select all", LiveDesign.accent, onAll)
        TrayTextChip(MonitorIcon.X, "Clear", "Clear selection", LiveDesign.muted, onClear)
        MediaCircleIconButton(MonitorIcon.DOWNLOAD, "Cache selected clips", onCache, enabled = cacheEnabled, size = 34.dp)
        MediaCircleIconButton(MonitorIcon.STAR, "Favorite selected clips", onStar, enabled = count > 0, size = 34.dp)
        MediaCircleIconButton(MonitorIcon.TRASH, selectionDeleteDescription(count, deleteEnabled), onDelete,
            enabled = deleteEnabled, size = 34.dp)
        if (shareEnabled) MediaCircleIconButton(MonitorIcon.SHARE, selectionShareDescription(count), onShare,
            enabled = count > 0, size = 34.dp)
    }
}

/**
 * One button to TalkBack, announced by [contentDescription] alone (iOS: one "Clear selection" button):
 * the visible [label] and glyph are its drawing, not separate nodes read after it. The click stays the
 * clickable's own, so TalkBack's ACTION_CLICK runs the same handler as a tap.
 */
@Composable
private fun TrayTextChip(icon: MonitorIcon, label: String, contentDescription: String, tint: Color, onClick: () -> Unit) {
    Row(Modifier.height(34.dp).chromeClickable(onClick = onClick)
        .semantics(mergeDescendants = true) {
            this.contentDescription = contentDescription
            role = Role.Button
        }.padding(horizontal = 7.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        MonitorIcon(icon, null, Modifier.size(13.dp), tint)
        Text(label, Modifier.clearAndSetSemantics {}, color = tint, style = LiveType.ui(11f, FontWeight.SemiBold))
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
fun MediaEmptyState(listing: Boolean, subtitle: String, title: String? = null, retry: (() -> Unit)? = null) {
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
            title ?: if (listing) MediaLibraryCopy.LISTING_TITLE else MediaLibraryCopy.EMPTY_TITLE,
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
        if (retry != null) Text("Retry", color = LiveDesign.accent, style = LiveType.ui(13f, FontWeight.SemiBold),
            modifier = Modifier.chromeClickable(onClick = retry).padding(horizontal = 16.dp, vertical = 8.dp))
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
    dateEdit: ((Boolean) -> MediaDatePickerAction?)? = null,
    photoSizes: com.opencapture.monitorui.MonitorMediaPhotoSizeChoices? = null,
    dateWindows: com.opencapture.monitorui.MonitorMediaDateWindowChoices? = null,
    storage: com.opencapture.monitorui.MonitorMediaStorageChoices? = null,
    hasActiveFilters: Boolean = false,
    dialog: Boolean = false,
) {
    var pickingDate by remember { mutableStateOf<MediaDatePickerAction?>(null) }
    fun pick(start: Boolean) {
        pickingDate = if (dateEdit != null) dateEdit(start)
            else MediaDatePickerAction(start, if (start) onDateStart else onDateEnd)
    }
    @Composable fun form() {
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
                onPickStart = { pick(true) },
                onPickEnd = { pick(false) },
                onClear = onClear, photoSizes = photoSizes, dateWindows = dateWindows,
                storage = storage, hasActiveFilters = hasActiveFilters,
                chipLayout = if (dialog) com.opencapture.monitorui.MonitorMediaFilterChipLayout.HORIZONTAL_SCROLL
                    else com.opencapture.monitorui.MonitorMediaFilterChipLayout.PLATFORM_DEFAULT,
                showsInlineClear = !dialog,
            )
    }
    if (dialog) {
        androidx.compose.ui.window.Dialog(onDismissRequest = onClose,
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)).chromeClickable(onClick = onClose),
                contentAlignment = Alignment.TopCenter) {
                Column(Modifier.padding(top = 72.dp, start = 20.dp, end = 20.dp).widthIn(max = 400.dp).fillMaxWidth()
                    .mediaPanelGlass(MediaCornerShape).chromeClickable(onClick = {}).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Filters", style = LiveType.ui(16f, FontWeight.SemiBold), color = LiveDesign.text)
                    val scroll = rememberScrollState()
                    Column(Modifier.fillMaxWidth().weight(1f, fill = false).heightIn(max = 290.dp).verticalScroll(scroll)) { form() }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text("Clear all", style = LiveType.ui(13f, FontWeight.Medium),
                            color = if (hasActiveFilters) LiveDesign.accent else LiveDesign.faint,
                            modifier = Modifier.chromeClickable(enabled = hasActiveFilters, onClick = onClear))
                        Text("Done", style = LiveType.ui(13f, FontWeight.SemiBold), color = LiveDesign.accent,
                            modifier = Modifier.chromeClickable(onClick = onClose))
                    }
                }
            }
        }
        return
    }
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
            form()
        }
        pickingDate?.let { edit ->
            key(edit) {
                val isStart = edit.start
                val current = if (isStart) dateStartKey else dateEndKey
                val pickerState = rememberDatePickerState(
                    initialSelectedDateMillis = current?.let { MediaLibraryQuery.millisFromDateKey(it) },
                )
                DatePickerDialog(
                    onDismissRequest = { edit.cancel(); pickingDate = null },
                    confirmButton = {
                        TextButton(onClick = {
                            pickerState.selectedDateMillis?.let { millis ->
                                val key = MediaLibraryQuery.dateKeyFromMillis(millis)
                                edit.commit(key)
                            }
                            edit.cancel(); pickingDate = null
                        }) { Text("Done") }
                    },
                    dismissButton = {
                        TextButton(onClick = {
                            edit.commit(null); edit.cancel(); pickingDate = null
                        }) { Text("Clear") }
                    },
                ) {
                    DatePicker(pickerState)
                }
            }
        }
    }
}

/** The picker retains the action captured when the editor opens. */
class MediaDatePickerAction(val start: Boolean, val commit: (String?) -> Unit, val cancel: () -> Unit = {})

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
            .semantics { this.contentDescription = contentDescription; role = Role.Button },
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

/** What the library page shows, read from the app's library owner. */
class MediaLibraryPageState(
    /** Heading subtitle: the connected camera, or the app name. */
    val cameraName: String,
    val category: MediaLibraryTab,
    val layout: MediaBrowserLayout,
    val thumbnailSize: MediaThumbnailSize,
    val sortOrder: MediaLibrarySort,
    val headerCount: String,
    val fetchInProgress: Boolean,
    val isLive: Boolean,
    val isSelecting: Boolean,
    val filterOpen: Boolean,
    val activeFilterCount: Int,
    val selectedCount: Int,
    val cacheEnabled: Boolean,
    val deleteEnabled: Boolean,
    /** The clip being cached (file name, progress), read where the cache bar draws. */
    val caching: () -> Pair<String, Double>?,
    val shareEnabled: Boolean = true,
)

/** The filter popup's choices and selection. */
class MediaLibraryFilterState(
    val formatOptions: List<String>,
    val resolutionOptions: List<String>,
    val colorOptions: List<Pair<Int, String>>,
    val hasDates: Boolean,
    val formatFilters: Set<String>,
    val resolutionFilters: Set<String>,
    val colorFilters: Set<Int>,
    val dateStartKey: String?,
    val dateEndKey: String?,
    val photoSizes: com.opencapture.monitorui.MonitorMediaPhotoSizeChoices? = null,
    val dateWindows: com.opencapture.monitorui.MonitorMediaDateWindowChoices? = null,
    val storage: com.opencapture.monitorui.MonitorMediaStorageChoices? = null,
    val hasActiveFilters: Boolean = false,
    val dialog: Boolean = false,
)

/** The page's commands, routed to the app's library owner. */
interface MediaLibraryPageActions {
    fun selectCategory(tab: MediaLibraryTab)
    fun showList(list: Boolean)
    fun selectThumbnailSize(size: MediaThumbnailSize)
    fun cycleSort()
    fun toggleFilter()
    fun selectAll()
    fun clearSelection()
    fun cacheSelected()
    fun favoriteSelected()
    fun deleteSelected()
    fun shareSelected()
    fun toggleFormat(format: String)
    fun toggleResolution(resolution: String)
    fun toggleColor(color: Int)
    /** Both date bounds at once; the page keeps start on or before end. */
    fun filterDates(start: String?, end: String?)
    fun dateEdit(start: Boolean, currentStart: String?, currentEnd: String?): MediaDatePickerAction? =
        MediaDatePickerAction(start, commit = { next ->
            if (start) filterDates(next, if (next != null && currentEnd != null && next > currentEnd) next else currentEnd)
            else filterDates(if (next != null && currentStart != null && next < currentStart) next else currentStart, next)
        })
    fun resetFilters()
    fun closeFilter()
}

/**
 * The media library page: heading, category rail or strip, display controls, header, cache bar, the app's
 * [gallery], the selection tray and the filter popup; [overlays] (player, photo viewer, delivery, confirms)
 * draw above it. [close] is the page's own Close (`monitor.page.back`), placed like everything else on the
 * page inside the system bars and beside the display cutout (Swift twin: `MonitorPage`'s back button over
 * the resolved safe area); in landscape the content keeps a column free for it.
 */
@Composable
fun MediaLibraryPage(
    state: MediaLibraryPageState,
    filter: MediaLibraryFilterState,
    actions: MediaLibraryPageActions,
    gallery: @Composable () -> Unit,
    overlays: @Composable BoxScope.() -> Unit,
    storageCards: List<MonitorMediaGalleryStorage> = emptyList(),
    selectStorage: (String) -> Unit = {},
    close: (() -> Unit)? = null,
) {
    // The system bars on every side, and the cutout only where it takes a side (a landscape punch hole);
    // a portrait punch hole leaves the corners beside it usable, as before.
    val safe = WindowInsets.statusBars.union(WindowInsets.navigationBars)
        .union(WindowInsets.displayCutout.only(WindowInsetsSides.Horizontal))
    Box(
        Modifier
            .fillMaxSize()
            .background(LiveDesign.background)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = {},
            ),
    ) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val portrait = maxHeight > maxWidth
            com.opencapture.monitorui.MonitorPageScaffold(
                modifier = Modifier.windowInsetsPadding(safe).padding(horizontal = 12.dp, vertical = 10.dp)
                    .padding(end = if (close != null && !portrait) MEDIA_PAGE_CLOSE_SLOT else 0.dp),
                navigationWidth = 206f,
                heading = {
                    com.opencapture.monitorui.MonitorPageHeading("Media", state.cameraName)
                },
                navigation = { compact ->
                    Column(
                        if (compact) Modifier.fillMaxWidth() else Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        if (compact) {
                            MediaCategoryStrip(state.category) { actions.selectCategory(it) }
                            MonitorMediaGalleryStorageCards(storageCards, selectStorage, horizontal = true)
                        } else {
                            MonitorMediaGalleryNavigationRail(state.category, storageCards,
                                actions::selectCategory, selectStorage,
                                com.opencapture.monitorui.MonitorMediaLayout.valueOf(state.layout.name),
                                com.opencapture.monitorui.MonitorThumbnailSize.valueOf(state.thumbnailSize.name),
                                { actions.showList(it == com.opencapture.monitorui.MonitorMediaLayout.LIST) },
                                { actions.selectThumbnailSize(MediaThumbnailSize.valueOf(it.name)) },
                                modifier = Modifier.fillMaxSize())
                        }
                    }
                },
            ) {
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    MediaCatalogHeaderRow(
                        headerTitle = MediaLibraryCopy.headerTitle(state.category), headerCount = state.headerCount,
                        fetchInProgress = state.fetchInProgress, isLive = state.isLive,
                        isSelecting = state.isSelecting,
                        sortOrder = state.sortOrder, filterOpen = state.filterOpen, activeFilterCount = state.activeFilterCount,
                        compact = portrait,
                        onFilter = actions::toggleFilter, onSort = actions::cycleSort,
                    )
                    state.caching()?.let { (name, progress) -> MediaCacheBar(name, progress) }
                    Box(Modifier.weight(1f).fillMaxWidth()) { gallery() }
                    if (state.isSelecting) MediaSelectionTray(state.selectedCount,
                        cacheEnabled = state.cacheEnabled,
                        deleteEnabled = state.deleteEnabled,
                        onAll = actions::selectAll, onClear = actions::clearSelection,
                        onCache = actions::cacheSelected,
                        onStar = actions::favoriteSelected,
                        onDelete = actions::deleteSelected,
                        onShare = actions::shareSelected,
                        shareEnabled = state.shareEnabled,
                    )
                    if (portrait) {
                        MediaCatalogDisplayControls(
                            list = state.layout == MediaBrowserLayout.LIST,
                            thumbnailSize = state.thumbnailSize,
                            onList = actions::showList,
                            onThumbnailSize = actions::selectThumbnailSize,
                        )
                    }
                }
            }
        }

        if (state.filterOpen) {
            MediaFilterPopup(
                formatOptions = filter.formatOptions,
                resolutionOptions = filter.resolutionOptions,
                colorOptions = filter.colorOptions,
                hasDates = filter.hasDates,
                formatFilters = filter.formatFilters,
                resolutionFilters = filter.resolutionFilters,
                colorFilters = filter.colorFilters,
                dateStartKey = filter.dateStartKey,
                dateEndKey = filter.dateEndKey,
                onToggleFormat = actions::toggleFormat,
                onToggleResolution = actions::toggleResolution,
                onToggleColor = actions::toggleColor,
                onDateStart = { next ->
                    val end = filter.dateEndKey
                    actions.filterDates(next, if (next != null && end != null && next > end) next else end)
                },
                onDateEnd = { next ->
                    val start = filter.dateStartKey
                    actions.filterDates(if (next != null && start != null && next < start) next else start, next)
                },
                onClear = actions::resetFilters,
                onClose = actions::closeFilter,
                dateEdit = { actions.dateEdit(it, filter.dateStartKey, filter.dateEndKey) },
                photoSizes = filter.photoSizes, dateWindows = filter.dateWindows,
                storage = filter.storage, hasActiveFilters = filter.hasActiveFilters, dialog = filter.dialog,
            )
        }

        close?.let { onClose ->
            MediaCloseButton(onClose, Modifier.align(Alignment.TopEnd).windowInsetsPadding(safe).padding(8.dp)
                .testTag("monitor.page.back"))
        }
        overlays()
    }
}

/** The landscape column the page keeps free for its Close: the button and its 8 dp margin, past the 12 dp page margin. */
private val MEDIA_PAGE_CLOSE_SLOT = 37.dp + 8.dp
