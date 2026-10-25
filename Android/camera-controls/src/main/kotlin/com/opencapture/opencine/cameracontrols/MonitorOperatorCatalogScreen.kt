package com.opencapture.opencine.cameracontrols

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.*
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.MediaAssetID
import com.opencapture.opencine.vocabulary.MediaLibrarySort
import com.opencapture.opencine.vocabulary.MediaLibraryTab

/** Source metadata and native readback; catalog policy never parses a payload. */
public data class MonitorMediaGalleryFileFacts(
    public val detail: String,
    public val duration: String? = null,
    public val progress: Double? = null,
)

/** A bounded native thumbnail leaf, with the source/window authority captured by the catalog. */
public class MonitorMediaGalleryThumbnail<P> internal constructor(
    public val record: MonitorMediaRecord<P>,
    public val entry: MonitorMediaCacheEntry?,
    public val list: Boolean,
    public val admission: MonitorMediaLibraryActionToken,
    private val current: () -> Boolean,
    private val publishDuration: (String) -> Unit,
) {
    public val isCurrent: Boolean get() = current()
    public fun duration(label: String): Unit { if (isCurrent) publishDuration(label) }
}

/** Complete exercised catalog composition over the existing source/cache owner. */
@Composable
public fun <P> MonitorOperatorCatalogScreen(
    library: MonitorMediaLibraryModel<P>,
    brand: String,
    sourceAvailable: Boolean,
    operations: MonitorMediaGalleryOperations<P>,
    presentation: MonitorMediaGalleryPresentation? = null,
    navigation: ((MonitorMediaGalleryNavigation) -> Unit)? = null,
    sourceFilter: ((MonitorMediaGalleryFilterAction) -> Unit)? = null,
    cell: ((MonitorMediaRecord<P>, MonitorMediaGalleryCellContext) -> MonitorClipValue)? = null,
    deletionDetail: ((MonitorMediaDeletionProgress) -> String?)? = null,
    selectionConfiguration: MonitorMediaSelectionConfiguration = MonitorMediaSelectionConfiguration.Standard,
    selectionChanged: (() -> Unit)? = null,
    colorChoices: List<Pair<String, String>> = emptyList(),
    facts: (MonitorMediaRecord<P>) -> MonitorMediaGalleryFileFacts,
    begin: () -> Unit = library::begin,
    refresh: () -> Unit = library::refresh,
    close: () -> Unit,
    open: (MonitorMediaGalleryOpen<P>) -> Unit,
    share: ((List<MonitorMediaRecord<P>>, MonitorMediaLibraryActionToken) -> Unit)? = null,
    handlesBack: Boolean = true,
    thumbnail: @Composable BoxScope.(MonitorMediaGalleryThumbnail<P>) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val gallery = remember(library, scope) { MonitorMediaGalleryModel(library, scope) }
    // The catalog content without transfer ticks: a streaming download does not recompose the
    // whole gallery. The header bar and each visible card read the ticks themselves.
    val value by library.content.collectAsState()
    val ticks by library.transferProgress.collectAsState()
    val state by gallery.state.collectAsState()
    val haptics = LocalOperatorHaptics.current
    DisposableEffect(gallery) { gallery.activate(); begin(); onDispose { gallery.retire() } }
    LaunchedEffect(value.lifetimeToken) { gallery.sourceChanged() }
    val snapshot = gallery.snapshot(presentation?.projection)
    // Action handlers installed in one recomposition can outlive it (the compiler keeps a
    // memoized callback while the gallery lifetime rotates underneath), so every admitted
    // action reads the presented window at call time instead of trusting this closure's
    // capture. The retirement guard itself is unchanged.
    val presented by rememberUpdatedState(snapshot)
    LaunchedEffect(presentation?.projection?.displayIDs) {
        if (presentation?.retainsVisibleSelection == true) gallery.retainSelection(snapshot)
    }
    fun admitted(action: () -> Unit) { if (gallery.isCurrent(presented)) action() }
    fun select(ids: Set<MediaAssetID>, selecting: Boolean = true) {
        if (gallery.select(ids, presented, selecting)) haptics.longPress()
        if (selecting && gallery.isCurrent(presented)) gallery.filterPopup(false)
    }
    if (handlesBack) BackHandler {
        when {
            state.confirmationPresented -> gallery.cancelDelete()
            state.filterPopupPresented -> gallery.filterPopup(false)
            value.selecting -> library.clearSelection()
            else -> { gallery.leave(); close() }
        }
    }
    val records = snapshot.records
    val selected = gallery.selected(snapshot, expanded = false)
    val category = presentation?.category ?: MediaLibraryTab.valueOf(value.category.name)
    val sort = presentation?.sort ?: MediaLibrarySort.valueOf(value.sort.name)
    val categoryRecords = library.records(value.category)
    val colors = colorChoices.filter { choice -> categoryRecords.any { it.facts.color == choice.first } }
    val page = MediaLibraryPageState(
        cameraName = brand, category = category,
        layout = MediaBrowserLayout.valueOf((presentation?.layout ?: value.layout).name),
        thumbnailSize = MediaThumbnailSize.valueOf((presentation?.thumbnailSize ?: value.thumbnailSize).name), sortOrder = sort,
        headerCount = when {
            value.fetching && value.fetchedCount == 0 -> "Scanning…"
            value.fetching -> "Listing… ${value.fetchedCount} found"
            else -> (presentation?.projection?.displayIDs?.size ?: records.size).let { "$it item${if (it == 1) "" else "s"}" }
        }, fetchInProgress = value.fetching, isLive = sourceAvailable, isSelecting = value.selecting,
        filterOpen = state.filterPopupPresented, activeFilterCount = presentation?.activeFilterCount ?: value.activeFilterCount,
        selectedCount = selected.size, cacheEnabled = selected.any { gallery.canDownload(it, operations) },
        deleteEnabled = selected.any { gallery.canDelete(it, operations) },
        caching = { cachingProgress(library, ticks, records, facts) },
        shareEnabled = share != null && selected.isNotEmpty() && selected.all { gallery.canShare(it, operations) },
    )
    val filterID = state.filterRequestID
    fun filter(action: MonitorMediaGalleryFilterAction, popup: Boolean = true) = admitted {
        if (popup && !gallery.admitsFilter(presented, filterID)) return@admitted
        haptics.selection()
        sourceFilter?.invoke(action)
        if (presentation?.filterClearsSelection == true && gallery.isCurrent(presented)) library.clearSelection()
    }
    fun navigate(action: MonitorMediaGalleryNavigation, fallback: () -> Unit) = admitted {
        if (navigation != null) navigation(action) else fallback()
        if (presentation?.navigationClearsSelection == true && gallery.isCurrent(presented)) library.clearSelection()
    }
    val sourceFilters = presentation?.filters
    val filters = if (sourceFilters != null) MediaLibraryFilterState(
        sourceFilters.formats, sourceFilters.resolutions, emptyList(), false,
        sourceFilters.formatSelection, sourceFilters.resolutionSelection, emptySet(), null, null,
        photoSizes = sourceFilters.photoSizes.takeIf { it.isNotEmpty() }?.let { choices ->
            MonitorMediaPhotoSizeChoices(choices, sourceFilters.photoSizeSelection,
                onToggle = { filter(MonitorMediaGalleryFilterAction.PhotoSize(it)) }) },
        dateWindows = sourceFilters.dateWindows.takeIf { it.isNotEmpty() }?.let { choices ->
            MonitorMediaDateWindowChoices(choices, sourceFilters.dateWindow,
                onToggle = { filter(MonitorMediaGalleryFilterAction.DateWindow(it)) }) },
        storage = sourceFilters.storage.takeIf { it.isNotEmpty() }?.let { choices ->
            MonitorMediaStorageChoices(choices, sourceFilters.storageID,
                onToggle = { filter(MonitorMediaGalleryFilterAction.Storage(it)) }) },
        hasActiveFilters = page.activeFilterCount > 0, dialog = sourceFilters.dialog,
    ) else MediaLibraryFilterState(
        categoryRecords.mapNotNull { it.facts.format }.filter(String::isNotEmpty).distinct().sorted(),
        categoryRecords.mapNotNull { it.facts.resolution }.filter(String::isNotEmpty).distinct().sorted(),
        colors.mapIndexed { index, choice -> index to choice.second }, categoryRecords.any { !it.facts.dateKey.isNullOrEmpty() },
        value.formats, value.resolutions,
        colors.mapIndexedNotNull { index, choice -> index.takeIf { choice.first in value.colors } }.toSet(),
        value.dateStart, value.dateEnd,
    )
    val actions = object : MediaLibraryPageActions {
        override fun selectCategory(tab: MediaLibraryTab) = navigate(MonitorMediaGalleryNavigation.Category(tab)) {
            library.filter(category = MonitorMediaCategoryFilter.valueOf(tab.name)) }
        override fun showList(list: Boolean) = navigate(MonitorMediaGalleryNavigation.Layout(if (list) MonitorMediaLayout.LIST else MonitorMediaLayout.GRID)) {
            library.display(layout = if (list) MonitorMediaLayout.LIST else MonitorMediaLayout.GRID) }
        override fun selectThumbnailSize(size: MediaThumbnailSize) = navigate(MonitorMediaGalleryNavigation.ThumbnailSize(MonitorThumbnailSize.valueOf(size.name))) {
            library.display(thumbnailSize = MonitorThumbnailSize.valueOf(size.name)) }
        override fun cycleSort() = navigate(MonitorMediaGalleryNavigation.CycleSort) { library.display(sort = MonitorMediaSort.valueOf(sort.next.name)) }
        override fun toggleFilter() = admitted { gallery.filterPopup(!state.filterPopupPresented) }
        override fun selectAll() = admitted { gallery.selectAll(presented) }
        override fun clearSelection() = admitted { library.clearSelection(); gallery.cancelDelete() }
        override fun cacheSelected() = gallery.cacheSelection(presented, operations)
        override fun favoriteSelected() = gallery.favoriteSelection(presented, operations, toggleUniform = true)
        override fun deleteSelected() = gallery.requestDelete(presented, operations, supportedSubset = true)
        override fun shareSelected() { gallery.shareSelection(presented, operations)?.let { share?.invoke(it, presented.token) } }
        override fun toggleFormat(format: String) {
            if (sourceFilters != null) filter(MonitorMediaGalleryFilterAction.Format(format))
            else admitted { if (gallery.admitsFilter(presented, filterID)) library.filter(formats = value.formats.toggled(format)) }
        }
        override fun toggleResolution(resolution: String) {
            if (sourceFilters != null) filter(MonitorMediaGalleryFilterAction.Resolution(resolution))
            else admitted { if (gallery.admitsFilter(presented, filterID)) library.filter(resolutions = value.resolutions.toggled(resolution)) }
        }
        override fun toggleColor(color: Int) = admitted { if (gallery.admitsFilter(presented, filterID)) colors.getOrNull(color)?.let { library.filter(colors = value.colors.toggled(it.first)) } }
        override fun filterDates(start: String?, end: String?) = admitted { if (gallery.admitsFilter(presented, filterID)) library.filter(dateStart = start, dateEnd = end) }
        override fun dateEdit(start: Boolean, currentStart: String?, currentEnd: String?): MediaDatePickerAction? {
            if (!gallery.admitsFilter(presented, filterID)) return null
            gallery.pickDate(if (start) MonitorMediaDateBound.START else MonitorMediaDateBound.END, presented)
            val request = gallery.state.value.pickingDate ?: return null
            return MediaDatePickerAction(start, commit = { gallery.date(it, request) }, cancel = {
                if (gallery.state.value.pickingDate?.id == request.id) gallery.cancelDate()
            })
        }
        override fun resetFilters() {
            if (sourceFilters != null) filter(MonitorMediaGalleryFilterAction.Reset) else admitted { if (gallery.admitsFilter(presented, filterID)) library.resetFilters() }
        }
        override fun closeFilter() { gallery.dismissFilter(filterID) }
    }
    key(value.lifetimeToken) {
        MediaLibraryPage(page, filters, actions, gallery = {
            MonitorOperatorCatalogGallery(gallery, snapshot, state.presentationRevision, facts, operations, sourceAvailable, refresh,
                open = open, select = ::select, thumbnail = thumbnail, presentation = presentation,
                cell = cell, selectionConfiguration = selectionConfiguration, selectionChanged = selectionChanged)
        }, overlays = {
            library.deletionProgress?.let { progress -> MonitorMediaDeletionOverlay(progress, deletionDetail?.invoke(progress)) }
            state.notice?.let { Text(it, Modifier.align(Alignment.BottomCenter).padding(24.dp), color = LiveDesign.text) }
        }, storageCards = presentation?.storage.orEmpty(),
            selectStorage = { filter(MonitorMediaGalleryFilterAction.Storage(it), popup = false) },
            close = { gallery.leave(); close() })
    }
    if (state.confirmationPresented) {
        val confirmation = state.deleteRequestID
        MonitorConfirmPopup(
            title = state.deletionMessage ?: "Delete ${state.deleteCount} item${if (state.deleteCount == 1) "" else "s"} from the camera?",
            confirmTitle = "Delete", onClickFeedback = haptics::selection,
            cancelDescription = MonitorPlaybackCopy.DELETE_CANCEL_DESCRIPTION,
            confirmDescription = MonitorPlaybackCopy.DELETE_CONFIRM_DESCRIPTION,
            onDismiss = { gallery.cancelDelete(confirmation) }, onConfirm = { gallery.confirmDelete(confirmation) },
        )
    }
    state.failure?.let { message ->
        AlertDialog(onDismissRequest = gallery::dismissFailure, title = { Text(message) },
            confirmButton = { TextButton(onClick = gallery::dismissFailure) { Text("OK") } })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <P> MonitorOperatorCatalogGallery(
    owner: MonitorMediaGalleryModel<P>, snapshot: MonitorMediaGallerySnapshot<P>, presentationRevision: Long,
    facts: (MonitorMediaRecord<P>) -> MonitorMediaGalleryFileFacts,
    operations: MonitorMediaGalleryOperations<P>, connected: Boolean, refresh: () -> Unit,
    open: (MonitorMediaGalleryOpen<P>) -> Unit, select: (Set<MediaAssetID>, Boolean) -> Unit,
    thumbnail: @Composable BoxScope.(MonitorMediaGalleryThumbnail<P>) -> Unit,
    presentation: MonitorMediaGalleryPresentation?,
    cell: ((MonitorMediaRecord<P>, MonitorMediaGalleryCellContext) -> MonitorClipValue)?,
    selectionConfiguration: MonitorMediaSelectionConfiguration,
    selectionChanged: (() -> Unit)?,
) {
    val library = owner.library
    val value by library.content.collectAsState()
    val ticks by library.transferProgress.collectAsState()
    val state by owner.state.collectAsState()
    val listState = rememberLazyListState()
    val gridState = rememberLazyGridState()
    val list = (presentation?.layout ?: value.layout) == MonitorMediaLayout.LIST
    val records = snapshot.records
    val empty = presentation?.empty
    val configuration = LocalConfiguration.current
    val anchor = remember { MonitorCatalogHeadAnchor() }
    // Keyed lazy items hold the previous first clip in place, so a rescan that prepends newer
    // clips would push them off above. Only a scroll by the operator releases the top.
    LaunchedEffect(list) {
        snapshotFlow {
            if (list) listState.isScrollInProgress to (listState.firstVisibleItemIndex == 0 &&
                listState.firstVisibleItemScrollOffset == 0)
            else gridState.isScrollInProgress to (gridState.firstVisibleItemIndex == 0 &&
                gridState.firstVisibleItemScrollOffset == 0)
        }.collect { (scrolling, atTop) -> anchor.scrolled(scrolling, atTop) }
    }
    val head = records.firstOrNull()?.asset?.id
    LaunchedEffect(head) {
        if (anchor.headChanged(head)) {
            if (list) listState.scrollToItem(0) else gridState.scrollToItem(0)
        }
    }
    val selectionIDs = remember(records) { records.map { it.asset.id.rawValue } }
    val draw: @Composable () -> Unit = {
        MonitorMediaSelectionHost(selectionIDs, value.selecting,
            value.selectedIDs.map { it.rawValue }.toSet(), if (list) listState else gridState,
            onOpen = { id -> owner.open(MediaAssetID(id), snapshot, operations, sourceAvailable = connected)?.let(open) },
            onSelectionChange = { selecting, ids -> select(ids.map { MediaAssetID(it) }.toSet(), selecting) },
            sessionKey = "${presentation?.category ?: value.category}/${presentation?.layout ?: value.layout}/${presentation?.thumbnailSize ?: value.thumbnailSize}/${presentation?.sort ?: value.sort}",
            configuration = selectionConfiguration,
            onFeedback = { if (it == MonitorMediaSelectionFeedback.CHANGED && owner.isCurrent(snapshot)) selectionChanged?.invoke() }) { registry ->
            @Composable fun card(record: MonitorMediaRecord<P>) {
                val id = record.asset.id
                val entry = value.entries[id]
                val metadata = facts(record)
                val context = MonitorMediaGalleryThumbnail(record, entry, list, snapshot.token,
                    current = { owner.isCurrent(snapshot) && snapshot.record(id) != null },
                    publishDuration = { owner.duration(it, id, snapshot) })
                MonitorMediaHitTarget(registry, id.rawValue) {
                    val cellValue = cell?.invoke(record, MonitorMediaGalleryCellContext(list, value.selecting,
                        id in value.selectedIDs, state.resolvedDurations[id]))
                    MonitorClipCard(monitorCatalogClip(record, entry, metadata, state.resolvedDurations[id], ticks.progress[id], cellValue),
                        list, value.selecting, id in value.selectedIDs,
                        modifier = Modifier.testTag("monitor.media.clip.${id.rawValue}"),
                        onOpen = { owner.open(id, snapshot, operations, sourceAvailable = connected)?.let(open) },
                        onSelect = { select(if (value.selecting) value.selectedIDs.toggled(id) else setOf(id), true) },
                        onFavorite = { owner.favorite(id, snapshot, operations) }, clicks = false) {
                        // A cover can retire this presentation while the library admission stays
                        // unchanged. Its new thumbnails must retry reads refused by the old context.
                        key(presentationRevision) { thumbnail(context) }
                    }
                }
            }
            Box(Modifier.fillMaxSize()) {
                when {
                    records.isEmpty() && empty != null -> MediaScrollablePlaceholder {
                        MediaEmptyState(empty.loading, empty.detail, empty.title,
                            retry = if (empty.retry) ({ if (owner.isCurrent(snapshot)) refresh() }) else null)
                    }
                    records.isEmpty() && value.fetching -> MediaScrollablePlaceholder { MediaListingState(value.fetchedCount) }
                    records.isEmpty() -> MediaScrollablePlaceholder {
                        val filtered = presentation?.activeFilterCount ?: value.activeFilterCount
                        MediaEmptyState(value.fetching, value.note ?: MediaLibraryCopy.emptySubtitle(connected,
                            value.records.isNotEmpty(), filtered, MediaLibraryTab.valueOf(value.category.name)),
                            title = MediaLibraryCopy.emptyTitle(value.fetching, connected, value.records.isNotEmpty(), filtered))
                    }
                    list -> LazyColumn(Modifier.fillMaxSize().testTag(GALLERY_TAG).monitorScrollFade(listState), state = listState,
                        verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 24.dp)) {
                        items(records, key = { it.asset.id.rawValue }) { card(it) }
                    }
                    else -> MonitorCatalogGrid(records,
                        monitorCatalogColumns(presentation?.thumbnailSize ?: value.thumbnailSize, minOf(configuration.screenWidthDp, configuration.screenHeightDp) >= 600),
                        key = { it.asset.id.rawValue }, modifier = Modifier.fillMaxSize().testTag(GALLERY_TAG), state = gridState) { card(it) }
                }
            }
        }
    }
    if (connected) PullToRefreshBox(value.fetching,
        onRefresh = { if (!value.fetching && owner.isCurrent(snapshot)) refresh() }, modifier = Modifier.fillMaxSize()) { draw() }
    else draw()
}

/**
 * The caching bar's one transfer, read where the bar composes. Idle (no ticks) costs nothing: the
 * host facts are scanned only while a host-owned transfer reports progress, and a library
 * transfer is found by its own id instead of by asking every record.
 */
internal fun <P> cachingProgress(library: MonitorMediaLibraryModel<P>, ticks: MonitorMediaLibraryTransferProgress,
    records: List<MonitorMediaRecord<P>>, facts: (MonitorMediaRecord<P>) -> MonitorMediaGalleryFileFacts): Pair<String, Double>? {
    if (ticks.progress.isEmpty() && ticks.hostProgress.isEmpty()) return null
    ticks.progress.entries.firstNotNullOfOrNull { (id, progress) -> library.record(id)?.asset?.filename?.let { it to progress } }
        ?.let { return it }
    if (ticks.hostProgress.isEmpty()) return null
    return records.firstNotNullOfOrNull { record -> facts(record).progress?.let { record.asset.filename to it } }
}

/** The newest clip stays first while the operator rests at the top of the catalog. */
internal class MonitorCatalogHeadAnchor {
    private var pinned = true
    private var scrolling = false
    private var head: MediaAssetID? = null

    /** A scroll records where the operator leaves the catalog; layout anchoring does not. */
    fun scrolled(scrolling: Boolean, atTop: Boolean) {
        if (scrolling || this.scrolling) pinned = atTop
        this.scrolling = scrolling
    }

    /** True when a new first record arrives while the catalog rests at its top. */
    fun headChanged(newHead: MediaAssetID?): Boolean {
        val changed = newHead != head
        head = newHead
        return changed && pinned && !scrolling
    }
}

/** The catalog owns cache state and progress for every cell; a source cell supplies its own facts only. */
internal fun <P> monitorCatalogClip(
    record: MonitorMediaRecord<P>, entry: MonitorMediaCacheEntry?, facts: MonitorMediaGalleryFileFacts,
    resolvedDuration: String?, libraryProgress: Double?, cell: MonitorClipValue?,
): MonitorClipValue {
    val source = if (entry?.original != null) "CACHED" else if (entry?.proxy != null) "PROXY" else "ON CAMERA"
    val progress = (facts.progress ?: libraryProgress)?.toFloat()
    return cell?.copy(id = record.asset.id.rawValue, favorite = record.favorite, source = source, progress = progress)
        ?: MonitorClipValue(record.asset.id.rawValue, record.asset.filename, facts.detail,
            resolvedDuration ?: facts.duration, source, record.favorite, progress)
}

private fun <T> Set<T>.toggled(value: T): Set<T> = if (value in this) this - value else this + value

/** The scrolling gallery, named as the SwiftUI catalog names it. */
private const val GALLERY_TAG = "monitor.media.gallery"
