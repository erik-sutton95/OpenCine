package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorMediaLayout
import com.opencapture.monitorui.MonitorThumbnailSize
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.UUID

/** Source/codec display facts. No URI, handle or vendor identity is parsed by the library. */
public data class MonitorMediaFilterFacts(
    public val format: String? = null, public val resolution: String? = null,
    public val dateKey: String? = null, public val orderKey: String? = null, public val color: String? = null,
    /** Explicit host category policy; never rewrites source asset.kind. */
    public val presentationKind: MediaAssetKind? = null,
    /** Observed source opening support; null preserves the caller's existing policy. */
    public val playbackEligible: Boolean? = null,
)
public enum class MonitorMediaCategoryFilter { ALL, VIDEOS, PHOTOS, FAVORITES }
public data class MonitorMediaLibraryActionToken internal constructor(
    public val lifetime: UUID, public val binding: MediaBrowseBinding?,
)
public data class MonitorMediaLibraryCopy(
    public val openFailed: String = "Could not open the camera library.",
    public val listFailed: String = "Could not list camera clips.",
    public val favoriteSaveFailed: String = "Could not save local clip favorites.",
    public val downloadFailed: String = "Could not download that clip.",
    public val listing: String? = null, public val empty: String? = null,
    /** Shown when the camera holds its own gallery, so it lists nothing here. */
    public val sourceHeld: String? = null,
)
/**
 * When a listing checkpoints the whole catalog. [STANDARD] (the default) persists after every
 * [MonitorMediaCatalogPersistence.STANDARD_PAGES] accepted pages, at completion and after a
 * non-cancel failure, so a large card is not re-encoded on the main thread once per page while a
 * cancelled pass still keeps most of what it listed. [EACH_DELTA] keeps one checkpoint per page.
 */
public enum class MonitorMediaCatalogPersistence {
    EACH_DELTA, LISTING_COMPLETE_OR_NON_CANCEL_FAILURE, STANDARD;
    public companion object { public const val STANDARD_PAGES: Int = 8 }
}
/** A fresh refresh base is unpublished until an actual source page is admitted. */
public enum class MonitorMediaCatalogBase { RETAIN_OBSERVED, FRESH_LISTING }
public enum class MonitorMediaCacheScanning { IMMEDIATE, BACKGROUND }
public enum class MonitorMediaLibraryVisibility { SOURCE_AVAILABILITY, ALL_RECORDS, CACHED_ONLY }
public enum class MonitorMediaSort { NEWEST, OLDEST, NAME, RATING }
public interface MonitorMediaFavoritesStore {
    public fun favorites(): Set<String>
    public fun saveFavorites(keys: Set<String>)
}

/** Per-transfer progress ticks, published apart from the catalog so a tick never re-emits it. */
public data class MonitorMediaLibraryTransferProgress(
    public val progress: Map<MediaAssetID, Double> = emptyMap(),
    public val hostProgress: Map<MonitorMediaLibraryIOKey, Double> = emptyMap(),
)

public data class MonitorMediaLibraryState<P>(
    public val records: List<MonitorMediaRecord<P>> = emptyList(),
    public val catalog: MediaCatalog = MediaCatalog(),
    public val browsing: Boolean = false, public val fetching: Boolean = false,
    public val fetchedCount: Int = 0, public val note: String? = null, public val cacheRevision: Long = 0,
    public val entries: Map<MediaAssetID, MonitorMediaCacheEntry> = emptyMap(),
    public val progress: Map<MediaAssetID, Double> = emptyMap(), public val transferring: Set<MediaAssetID> = emptySet(),
    public val category: MonitorMediaCategoryFilter = MonitorMediaCategoryFilter.ALL,
    public val sort: MonitorMediaSort = MonitorMediaSort.NEWEST,
    public val layout: MonitorMediaLayout = MonitorMediaLayout.GRID,
    public val thumbnailSize: MonitorThumbnailSize = MonitorThumbnailSize.MEDIUM,
    public val formats: Set<String> = emptySet(), public val resolutions: Set<String> = emptySet(),
    public val colors: Set<String> = emptySet(), public val dateStart: String? = null, public val dateEnd: String? = null,
    public val selecting: Boolean = false, public val selectedIDs: Set<MediaAssetID> = emptySet(),
    public val lifetimeToken: UUID = UUID.randomUUID(),
    public val visibility: MonitorMediaLibraryVisibility = MonitorMediaLibraryVisibility.SOURCE_AVAILABILITY,
    /** Accepted source deltas in this listing; local/cache changes never count. */
    public val catalogPageCount: Int = 0,
    public val acquiringSource: Boolean = false,
    public val hostProgress: Map<MonitorMediaLibraryIOKey, Double> = emptyMap(),
    public val deletionProgress: MonitorMediaDeletionProgress? = null,
) {
    public val activeFilterCount: Int get() = formats.size + resolutions.size + colors.size +
        if (dateStart == null && dateEnd == null) 0 else 1
}

/** One gallery lifetime on the supplied owner dispatcher. Covers and rotation borrow this model;
 * close/bind retires its operations before source cleanup suspends. A handled optional-operation
 * refusal never cancels the supplied native owner. */
public class MonitorMediaLibraryModel<P>(
    public val cache: MonitorMediaCache<P>, private val favoritesStore: MonitorMediaFavoritesStore,
    private var service: CameraMediaService? = null, scope: CoroutineScope,
    private val cacheScanning: MonitorMediaCacheScanning,
    private val catalogPersistence: MonitorMediaCatalogPersistence = MonitorMediaCatalogPersistence.STANDARD,
    private val initialCatalog: MediaCatalog? = null,
    initialRecords: List<MonitorMediaRecord<P>>? = null,
    private val copy: MonitorMediaLibraryCopy = MonitorMediaLibraryCopy(),
    private val readSnapshot: suspend (MonitorMediaCacheReadPlan) -> MonitorMediaCacheSnapshot = { it.read() },
    private val sleep: suspend (Long) -> Unit = { delay(it) },
    private val catalogBase: MonitorMediaCatalogBase = MonitorMediaCatalogBase.RETAIN_OBSERVED,
    /** Restores and keeps the operator's gallery view options; preferences with a view prefix supply it. */
    private val viewOptions: MonitorMediaViewOptionsStore? = favoritesStore as? MonitorMediaViewOptionsStore,
) {
    /** Original constructor, including positional and trailing sleep lambda compatibility. */
    public constructor(cache: MonitorMediaCache<P>, favoritesStore: MonitorMediaFavoritesStore,
        service: CameraMediaService? = null, scope: CoroutineScope, sleep: suspend (Long) -> Unit = { delay(it) }) :
        this(cache, favoritesStore, service, scope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, sleep = sleep)
    private val owner = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    /** Work that belongs to this library's lifetime rather than to one page (a playback download). */
    public val lifetimeScope: CoroutineScope get() = owner
    private var favorites = favoritesStore.favorites()
    private val mutable = MutableStateFlow((viewOptions?.viewOptions() ?: MonitorMediaViewOptions()).let { view ->
        MonitorMediaLibraryState(records = (initialRecords ?: cache.load()).map { projected(it, favorites) },
            category = view.category, sort = view.sort, layout = view.layout, thumbnailSize = view.thumbnailSize)
    })
    public val state: StateFlow<MonitorMediaLibraryState<P>> = mutable.asStateFlow()
    /**
     * The same state without transfer progress ticks ([MonitorMediaLibraryState.progress] and
     * [MonitorMediaLibraryState.hostProgress] stay empty here). A catalog view collects this, and
     * reads ticks per cell from [transferProgress], so a streaming transfer never recomposes it.
     */
    public val content: StateFlow<MonitorMediaLibraryState<P>> get() = contentMutable
    private val contentMutable = MutableStateFlow(mutable.value.withoutTicks())
    private val progressMutable = MutableStateFlow(MonitorMediaLibraryTransferProgress())
    public val transferProgress: StateFlow<MonitorMediaLibraryTransferProgress> = progressMutable.asStateFlow()
    private val retirementTasks = mutableSetOf<Job>()
    private var disposed = false
    private var browse: CameraMediaBrowse? = null
    private var cursor: MediaCatalogCursor? = null
    private val lifetime: UUID get() = state.value.lifetimeToken
    private var listing = UUID.randomUUID()
    private var openTask: Job? = null
    private var acquisitionTask: Job? = null
    private var acquisition = UUID.randomUUID()
    private var listTask: Job? = null
    private var reconciliationTask: Deferred<Unit>? = null
    private var entryTask: Job? = null
    private var entryRequest = UUID.randomUUID()
    private data class Transfer(val id: UUID, val representation: MediaRepresentationID,
        val writer: MonitorMediaCacheWrite, val task: Deferred<File>,
        /** The cached file, or null when the operation ended without one; a second request joins it. */
        val completion: CompletableDeferred<File?>)
    private val transfers = mutableMapOf<MediaAssetID, Transfer>()
    private val hostOwner = UUID.randomUUID()
    private data class HostClaim(val key: MonitorMediaLibraryIOKey, val purpose: MonitorMediaLibraryIOPurpose)
    private class HostOperation(val authority: MonitorMediaLibraryIOAuthority,
        val purpose: MonitorMediaLibraryIOPurpose, var writer: MonitorMediaCacheWrite?) {
        var task: Deferred<MediaTransferReceipt>? = null
        var attempt: UUID = UUID.randomUUID()
        var deletion: MonitorMediaLibraryDeletionAuthority? = null
        /** A download's file, or null when it ended without one; a second download joins it. */
        val completion = CompletableDeferred<File?>()
    }
    private val hostOperations = mutableMapOf<UUID, HostOperation>()
    private val hostClaims = mutableMapOf<HostClaim, UUID>()
    private val hostProgressOwners = mutableMapOf<MonitorMediaLibraryIOKey, MonitorMediaLibraryIOAuthority>()
    private val hostProgressDelays = mutableMapOf<MonitorMediaLibraryIOKey, Job>()
    private var deletionProgressOwner: UUID? = null
    private class DeletionFinish(val claim: UUID, var lifetime: UUID, val sourceCurrent: () -> Boolean) {
        var admission: MonitorMediaLibraryActionToken? = null
        var relisted = false
        var valid = true
    }
    private val finishingDeletions = mutableMapOf<UUID, DeletionFinish>()
    public val acquiringSource: Boolean get() = state.value.acquiringSource
    public val hostProgress: Map<MonitorMediaLibraryIOKey, Double> get() = state.value.hostProgress
    public val deletionProgress: MonitorMediaDeletionProgress? get() {
        val value = state.value.deletionProgress
        val id = deletionProgressOwner ?: return null
        val operation = hostOperations.values.firstOrNull { it.deletion?.id == id } ?: return null
        if (operation.deletion?.isCurrent != true || deletionProgressOwner != id || hostOperations[operation.authority.id] !== operation) return null
        return value
    }
    private val thumbnails = mutableMapOf<MediaAssetID, UUID>()
    private val thumbnailTasks = mutableMapOf<MediaAssetID, Job>()
    private val thumbnailWriters = mutableMapOf<MediaAssetID, MonitorMediaCacheWrite>()
    /** Latest targeted request per record; an older scan never overwrites a newer one. */
    private val targetedRequests = mutableMapOf<MediaAssetID, UUID>()
    private val targetedTasks = mutableMapOf<UUID, Job>()
    /** Records committed while a full scan is in flight; rescanned after it lands. */
    private val dirtyDuringFull = mutableSetOf<MediaAssetID>()
    private var libraryMemo: Derived<P>? = null
    private val categoryMemo = mutableMapOf<MonitorMediaCategoryFilter, Derived<P>>()
    private var displayedMemo: Derived<P>? = null
    private var indexMemo: Pair<List<MonitorMediaRecord<P>>, Map<MediaAssetID, MonitorMediaRecord<P>>>? = null
    init { mutate { it.copy(catalog = initialCatalog ?: MediaCatalog(assets = it.records.map { record -> record.asset })) }; reloadEntries() }
    private fun mutate(change: (MonitorMediaLibraryState<P>) -> MonitorMediaLibraryState<P>) {
        val next = change(mutable.value)
        mutable.value = next
        // StateFlow equality: unchanged fields keep their identity, so a tick compares in O(1).
        contentMutable.value = next.withoutTicks()
        progressMutable.value = MonitorMediaLibraryTransferProgress(next.progress, next.hostProgress)
    }
    private fun MonitorMediaLibraryState<P>.withoutTicks(): MonitorMediaLibraryState<P> =
        if (progress.isEmpty() && hostProgress.isEmpty()) this else copy(progress = emptyMap(), hostProgress = emptyMap())
    public val canRefresh: Boolean get() = service != null
    public val binding: MediaBrowseBinding? get() = browse?.binding
    public val canTransfer: Boolean get() = browse?.transfers != null
    public val canDelete: Boolean get() = browse?.deletion != null
    /**
     * Derivations are memoized against the identity of their inputs (one immutable state value
     * holds them), so a view that reads them on every frame or progress tick filters and sorts
     * once per actual change instead of once per read.
     */
    private class Derived<P>(val state: MonitorMediaLibraryState<P>, val offline: Boolean, val value: List<MonitorMediaRecord<P>>)
    private fun usesEntries(state: MonitorMediaLibraryState<P>): Boolean = when (state.visibility) {
        MonitorMediaLibraryVisibility.ALL_RECORDS -> false
        MonitorMediaLibraryVisibility.CACHED_ONLY -> true
        MonitorMediaLibraryVisibility.SOURCE_AVAILABILITY -> service == null
    }
    private fun Derived<P>.reusable(state: MonitorMediaLibraryState<P>, offline: Boolean, sameView: (MonitorMediaLibraryState<P>) -> Boolean): Boolean =
        this.offline == offline && this.state.records === state.records &&
            this.state.visibility == state.visibility && (!offline || this.state.entries === state.entries) && sameView(this.state)
    public val libraryRecords: List<MonitorMediaRecord<P>> get() {
        val state = state.value; val offline = usesEntries(state)
        libraryMemo?.let { if (it.reusable(state, offline) { true }) return it.value }
        val records = if (offline) state.records.filter { state.entries[it.asset.id]?.isPlayableOffline == true } else state.records
        libraryMemo = Derived(state, offline, records)
        return records
    }
    public fun records(category: MonitorMediaCategoryFilter): List<MonitorMediaRecord<P>> {
        val state = state.value; val offline = usesEntries(state)
        categoryMemo[category]?.let { if (it.reusable(state, offline) { true }) return it.value }
        val records = libraryRecords.filter {
            when (category) {
                MonitorMediaCategoryFilter.ALL -> true
                MonitorMediaCategoryFilter.VIDEOS -> (it.facts.presentationKind ?: it.asset.kind) == MediaAssetKind.VIDEO
                MonitorMediaCategoryFilter.PHOTOS -> (it.facts.presentationKind ?: it.asset.kind) == MediaAssetKind.PHOTO
                MonitorMediaCategoryFilter.FAVORITES -> it.favorite
            }
        }
        categoryMemo[category] = Derived(state, offline, records)
        return records
    }
    public val displayedRecords: List<MonitorMediaRecord<P>> get() {
        val state = state.value; val offline = usesEntries(state)
        displayedMemo?.let { memo ->
            if (memo.reusable(state, offline) { old -> old.category == state.category && old.sort == state.sort &&
                    old.formats == state.formats && old.resolutions == state.resolutions && old.colors == state.colors &&
                    old.dateStart == state.dateStart && old.dateEnd == state.dateEnd }) return memo.value
        }
        val value = deriveDisplayed(state)
        displayedMemo = Derived(state, offline, value)
        return value
    }
    private fun deriveDisplayed(state: MonitorMediaLibraryState<P>): List<MonitorMediaRecord<P>> {
        val filtered = records(state.category).filter { record ->
            val facts = record.facts
            (state.formats.isEmpty() || facts.format in state.formats) &&
                (state.resolutions.isEmpty() || facts.resolution in state.resolutions) &&
                (state.colors.isEmpty() || facts.color in state.colors) &&
                ((state.dateStart == null && state.dateEnd == null) || facts.dateKey?.let { date ->
                    (state.dateStart == null || date >= state.dateStart) && (state.dateEnd == null || date <= state.dateEnd)
                } == true)
        }
        return when (state.sort) {
            MonitorMediaSort.NEWEST -> filtered.sortedByDescending { it.facts.orderKey ?: "" }
            MonitorMediaSort.OLDEST -> filtered.sortedBy { it.facts.orderKey ?: "" }
            MonitorMediaSort.NAME -> filtered.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.asset.filename })
            MonitorMediaSort.RATING -> filtered.sortedWith(compareByDescending<MonitorMediaRecord<P>> { it.favorite }
                .thenByDescending { it.facts.orderKey ?: "" })
        }
    }
    public val selectedRecords: List<MonitorMediaRecord<P>> get() = displayedRecords.filter { it.asset.id in state.value.selectedIDs }
    /** O(1), from an index rebuilt only when the records list itself changes; the first row wins. */
    public fun record(id: MediaAssetID): MonitorMediaRecord<P>? {
        val records = state.value.records
        val memo = indexMemo
        if (memo != null && memo.first === records) return memo.second[id]
        val index = HashMap<MediaAssetID, MonitorMediaRecord<P>>(records.size * 2)
        records.forEach { index.putIfAbsent(it.asset.id, it) }
        indexMemo = records to index
        return index[id]
    }
    public fun filter(category: MonitorMediaCategoryFilter = state.value.category, formats: Set<String> = state.value.formats,
        resolutions: Set<String> = state.value.resolutions, colors: Set<String> = state.value.colors,
        dateStart: String? = state.value.dateStart, dateEnd: String? = state.value.dateEnd) {
        mutate { it.copy(category = category, formats = formats.toSet(), resolutions = resolutions.toSet(),
            colors = colors.toSet(), dateStart = dateStart, dateEnd = dateEnd) }
        saveViewOptions()
    }
    public fun display(sort: MonitorMediaSort = state.value.sort, layout: MonitorMediaLayout = state.value.layout,
        thumbnailSize: MonitorThumbnailSize = state.value.thumbnailSize) {
        mutate { it.copy(sort = sort, layout = layout, thumbnailSize = thumbnailSize) }
        saveViewOptions()
    }
    private fun saveViewOptions() {
        val value = state.value
        viewOptions?.saveViewOptions(MonitorMediaViewOptions(value.category, value.sort, value.layout, value.thumbnailSize))
    }
    public fun resetFilters() { filter(formats = emptySet(), resolutions = emptySet(), colors = emptySet(), dateStart = null, dateEnd = null) }
    public fun select(ids: Set<MediaAssetID>, selecting: Boolean = true) { mutate { it.copy(selecting = selecting, selectedIDs = ids.toSet()) } }
    public fun selectAll() { select(displayedRecords.map { it.asset.id }.toSet()) }
    public fun clearSelection() { select(emptySet(), selecting = false) }
    public fun visibility(value: MonitorMediaLibraryVisibility) { mutate { it.copy(visibility = value) } }
    public fun isLocallyFavorite(id: MediaAssetID): Boolean = record(id)?.let { it.address.favoriteKey in favorites } ?: false
    private fun projected(record: MonitorMediaRecord<P>, favorites: Set<String>): MonitorMediaRecord<P> =
        record.copy(favorite = when (record.favoriteAuthority) {
            MonitorMediaFavoriteAuthority.LEGACY_COMBINED -> record.favorite || record.address.favoriteKey in favorites
            MonitorMediaFavoriteAuthority.SOURCE -> record.sourceFavorite ?: record.favorite
            MonitorMediaFavoriteAuthority.LOCAL_OVERLAY -> record.sourceFavorite == true || record.address.favoriteKey in favorites
        })
    public fun toggleFavorite(id: MediaAssetID) {
        val record = record(id) ?: return
        val generation = lifetime
        val on = if (record.favoriteAuthority == MonitorMediaFavoriteAuthority.LOCAL_OVERLAY)
            record.address.favoriteKey !in favorites else !record.favorite
        favorites = if (on) favorites + record.address.favoriteKey else favorites - record.address.favoriteKey
        val changed = record.copy(favorite = if (record.favoriteAuthority == MonitorMediaFavoriteAuthority.LOCAL_OVERLAY)
            record.sourceFavorite == true || on else on)
        mutate { it.copy(records = it.records.map { old -> if (old.asset.id == id) changed else old }) }
        if (lifetime != generation) return
        favoritesStore.saveFavorites(favorites)
        if (lifetime != generation) return
        try { cache.save(state.value.records) { lifetime == generation } }
        catch (_: Exception) { if (lifetime == generation) mutate { it.copy(note = copy.favoriteSaveFailed) } }
    }
    public fun bind(service: CameraMediaService?) {
        val wasBrowsing = state.value.browsing
        this.service = service
        val retired = retire()
        if (wasBrowsing && lifetime == retired.token && !state.value.browsing) begin()
    }
    public fun begin() {
        if (disposed || state.value.browsing) return
        begin(UUID.randomUUID(), completingClaim = null)
    }
    private fun begin(generation: UUID, completingClaim: UUID?) {
        if (disposed || state.value.browsing) return
        invalidateFinishingDeletions(completingClaim)
        val retired = extractRetiredOperations(completingClaim = completingClaim)
        mutate { it.copy(lifetimeToken = generation, browsing = true, note = null, catalogPageCount = 0,
            hostProgress = it.hostProgress - retired.hostKeys) }
        retired.dispose()
        if (!current(generation)) return
        if (cacheScanning == MonitorMediaCacheScanning.BACKGROUND) reloadEntries()
        if (!current(generation)) return
        open()
    }
    /** One consumed deletion may reopen its own source once, during finish. The existing open
     * task supplies the actual binding before a return action token is sealed. */
    public suspend fun relist(after: MonitorMediaLibraryDeletionAuthority): Boolean {
        if (after.owner != hostOwner || after.directory !== cache.directory) return false
        val finish = finishingDeletions[after.id] ?: return false
        if (finish.relisted || !after.isCompleting || finishingDeletions[after.id] !== finish) return false
        finish.relisted = true
        if (state.value.browsing) refresh() else {
            val replacement = UUID.randomUUID()
            finish.lifetime = replacement
            begin(replacement, completingClaim = after.id)
        }
        if (!after.isCompleting || finishingDeletions[after.id] !== finish) return false
        val opened = openTask
        opened?.join()
        return currentCoroutineContext().isActive && after.isCompleting && finishingDeletions[after.id] === finish
    }
    private fun invalidateFinishingDeletions(retained: UUID? = null) {
        finishingDeletions.forEach { (id, finish) -> if (id != retained) finish.valid = false }
    }
    private fun finishingCurrent(finish: DeletionFinish): Boolean {
        if (!finish.valid || disposed || lifetime != finish.lifetime || finish.admission?.let(::isCurrent) == false) return false
        val available = finish.sourceCurrent()
        return available && finish.valid && !disposed && lifetime == finish.lifetime && finish.admission?.let(::isCurrent) != false
    }
    /** Offline rows open immediately; only the same gallery may adopt the captured SDK result. */
    public fun begin(acquiring: suspend () -> CameraMediaService?, unavailableNote: String? = null) {
        if (disposed || state.value.browsing) return
        bind(null)
        if (disposed || state.value.browsing) return
        begin()
        if (disposed || !state.value.browsing) return
        val generation = lifetime; val request = UUID.randomUUID(); acquisition = request
        val task = owner.launch(start = CoroutineStart.LAZY) {
            if (!current(generation) || acquisition != request) return@launch
            val producer = try { acquiring() } catch (error: Exception) {
                if (current(generation) && acquisition == request && isActive) {
                    acquisitionTask = null
                    mutate { it.copy(acquiringSource = false, note = unavailableNote ?: copy.openFailed) }
                }
                return@launch
            }
            if (!current(generation) || acquisition != request || !isActive) return@launch
            acquisitionTask = null
            mutate { it.copy(acquiringSource = false) }
            if (!current(generation) || acquisition != request || !isActive) return@launch
            if (producer == null) { mutate { it.copy(note = unavailableNote ?: copy.openFailed) }; return@launch }
            bind(producer)
        }
        acquisitionTask = task
        mutate { it.copy(acquiringSource = true) }
        if (!current(generation) || acquisition != request) task.cancel() else task.start()
    }
    private fun open() {
        val service = service ?: return
        val generation = lifetime
        val task = owner.launch(start = CoroutineStart.LAZY) {
            if (!current(generation)) return@launch
            try {
                val opened = service.openBrowse()
                if (!current(generation) || !isActive) { withContext(NonCancellable) { opened.close() }; return@launch }
                browse = opened; openTask = null; refresh()
            } catch (error: Exception) {
                if (current(generation)) { openTask = null; mutate { it.copy(note = copy.openFailed) } }
            }
        }
        openTask = task; task.start()
    }
    private data class Retirement(val token: UUID, val browse: CameraMediaBrowse?)
    private fun retire(token: UUID = UUID.randomUUID(), retainingHost: UUID? = null): Retirement {
        invalidateFinishingDeletions()
        listing = UUID.randomUUID(); entryRequest = UUID.randomUUID()
        val oldOpen = openTask; val oldList = listTask; val oldReconciliation = reconciliationTask; val oldCursor = cursor; val oldEntries = entryTask; val closed = browse
        val oldAcquisition = acquisitionTask; acquisitionTask = null; acquisition = UUID.randomUUID()
        openTask = null; listTask = null; reconciliationTask = null; cursor = null; entryTask = null; browse = null
        val retired = extractRetiredOperations(retainingHost = retainingHost)
        if (retainingHost == null) deletionProgressOwner = null
        val cleanup = closed?.let(::prepareRetirement)
        mutate { it.copy(lifetimeToken = token, browsing = false, fetching = false, acquiringSource = false, catalogPageCount = 0,
            transferring = it.transferring - retired.ids, progress = it.progress - retired.ids,
            hostProgress = it.hostProgress - retired.hostKeys,
            deletionProgress = if (retainingHost == null) null else it.deletionProgress) }
        oldOpen?.cancel(); oldList?.cancel(); oldReconciliation?.cancel(); oldCursor?.close(); oldEntries?.cancel(); cancelTargetedScans(); retired.dispose()
        oldAcquisition?.cancel()
        cleanup?.start()
        return Retirement(token, closed)
    }
    // Register before publication: a synchronous dispose observer must see the old lease.
    private fun prepareRetirement(closed: CameraMediaBrowse): Job {
        val task = owner.launch(NonCancellable, start = CoroutineStart.LAZY) { closed.close() }
        retirementTasks.add(task)
        task.invokeOnCompletion { retirementTasks.remove(task) }
        return task
    }
    /** A host operation's outcome (a refused delete, a failed download) for the gallery's note line. */
    public fun showNote(value: String?) { mutate { it.copy(note = value) } }
    public fun close() { retire() }
    public suspend fun dispose() {
        disposed = true
        retire()
        try {
            withContext(NonCancellable) {
                while (retirementTasks.isNotEmpty()) {
                    val pending = retirementTasks.toList()
                    pending.forEach { it.start() }
                    pending.joinAll()
                }
            }
        } finally { owner.cancel() }
    }

    private fun current(generation: UUID): Boolean = !disposed && state.value.browsing && lifetime == generation
    private fun admitted(generation: UUID, request: UUID, binding: MediaBrowseBinding): Boolean =
        current(generation) && listing == request && browse?.binding == binding
    public fun refresh() {
        if (!state.value.browsing) return
        val browse = browse ?: run { if (openTask == null) open(); return }
        val request = UUID.randomUUID(); listing = request; val generation = lifetime
        val oldTask = listTask; val oldReconciliation = reconciliationTask; val oldCursor = cursor; listTask = null; reconciliationTask = null; cursor = null
        oldTask?.cancel(); oldReconciliation?.cancel(); oldCursor?.close()
        if (!admitted(generation, request, browse.binding)) return
        mutate { it.copy(fetching = true, fetchedCount = 0, note = copy.listing, catalogPageCount = 0) }
        if (!admitted(generation, request, browse.binding)) return
        val task = owner.launch(start = CoroutineStart.LAZY) {
            if (!admitted(generation, request, browse.binding) || !isActive) return@launch
            try {
                val opened = browse.catalog()
                if (!admitted(generation, request, browse.binding) || !isActive) { opened.close(); return@launch }
                cursor = opened
                try {
                    consumeCursor(opened, browse.binding, generation, request, catalogBase == MonitorMediaCatalogBase.FRESH_LISTING)
                } finally { opened.close() }
                if (admitted(generation, request, browse.binding)) {
                    val held = if (browse.heldBySource == true) copy.sourceHeld else null
                    cursor = null; listTask = null; mutate { it.copy(fetching = false, note = held ?: if (it.records.isEmpty()) copy.empty else null) }
                }
            } catch (error: Exception) {
                if (admitted(generation, request, browse.binding)) {
                    cursor = null; listTask = null
                    mutate { it.copy(fetching = false, note = if (error is CancellationException) it.note else copy.listFailed) }
                }
            }
        }
        listTask = task; task.start()
    }
    private suspend fun consumeCursor(cursor: MediaCatalogCursor, binding: MediaBrowseBinding,
        generation: UUID, request: UUID, freshBase: Boolean = false) {
        var listingCatalog = MediaCatalog()
        val authority = cache.catalogAuthority
        var appliedPage = false; var checkpointAttempted = false; var pendingPages = 0
        val context = currentCoroutineContext()
        fun checkpoint() {
            context.ensureActive()
            if (!(cache.isCurrent(authority) && admitted(generation, request, binding))) throw MediaServiceException(MediaServiceFailure.RETIRED)
            checkpointAttempted = true; pendingPages = 0
            cache.save(state.value.records) { context.isActive && (cache.isCurrent(authority) && admitted(generation, request, binding)) }
        }
        try {
            while (true) {
                val delta = cursor.next() ?: break
                currentCoroutineContext().ensureActive()
                if (!(cache.isCurrent(authority) && admitted(generation, request, binding))) throw MediaServiceException(MediaServiceFailure.RETIRED)
                val previous = state.value.records.toList()
                val captured = cache.codec.captureCatalog(delta, binding, previous)
                if (!cache.isCurrent(authority) || !admitted(generation, request, binding)) throw MediaServiceException(MediaServiceFailure.RETIRED)
                val capture = cache.codec.prepareCatalog(captured, binding, previous)
                currentCoroutineContext().ensureActive()
                if (!cache.isCurrent(authority) || !admitted(generation, request, binding)) throw MediaServiceException(MediaServiceFailure.RETIRED)
                val nextCatalog = (if (freshBase) listingCatalog else state.value.catalog).applying(delta)
                if (!apply(nextCatalog, capture, generation, request, binding, authority)) throw MediaServiceException(MediaServiceFailure.RETIRED)
                listingCatalog = nextCatalog
                appliedPage = true; pendingPages += 1
                when (catalogPersistence) {
                    MonitorMediaCatalogPersistence.EACH_DELTA -> checkpoint()
                    MonitorMediaCatalogPersistence.STANDARD ->
                        if (pendingPages >= MonitorMediaCatalogPersistence.STANDARD_PAGES) checkpoint()
                    MonitorMediaCatalogPersistence.LISTING_COMPLETE_OR_NON_CANCEL_FAILURE -> Unit
                }
            }
            currentCoroutineContext().ensureActive()
            if (catalogPersistence != MonitorMediaCatalogPersistence.EACH_DELTA && pendingPages > 0) checkpoint()
        } catch (error: Exception) {
            val pending = if (catalogPersistence == MonitorMediaCatalogPersistence.STANDARD) pendingPages > 0
                else catalogPersistence == MonitorMediaCatalogPersistence.LISTING_COMPLETE_OR_NON_CANCEL_FAILURE && !checkpointAttempted
            if (catalogPersistence != MonitorMediaCatalogPersistence.EACH_DELTA &&
                appliedPage && pending && error !is CancellationException &&
                (error as? MediaServiceException)?.failure != MediaServiceFailure.RETIRED &&
                currentCoroutineContext().isActive && (cache.isCurrent(authority) && admitted(generation, request, binding))) checkpoint()
            throw error
        }
    }
    private fun apply(catalog: MediaCatalog, capture: MonitorMediaCatalogCapture<P>,
        generation: UUID, request: UUID, binding: MediaBrowseBinding, authority: MonitorMediaCatalogAuthority): Boolean {
        return applyCapture(capture, catalog) { cache.isCurrent(authority) && admitted(generation, request, binding) }
    }
    /** Actual captured host index transaction; raw camera observations stay unchanged. */
    public fun applyLocalRecords(capture: MonitorMediaCatalogCapture<P>,
        token: MonitorMediaLibraryActionToken, persist: Boolean = false) {
        if (!applyCapture(capture, null) { isCurrent(token) }) throw MediaServiceException(MediaServiceFailure.RETIRED)
        if (persist) cache.save(state.value.records) { isCurrent(token) }
        if (!isCurrent(token)) throw MediaServiceException(MediaServiceFailure.RETIRED)
    }
    private fun applyCapture(capture: MonitorMediaCatalogCapture<P>, catalog: MediaCatalog?,
        ifCurrent: () -> Boolean): Boolean {
        if (!ifCurrent()) return false
        val capturedFavorites = capture.sourceFavoriteKeys ?: favorites
        val old = state.value
        val values = linkedMapOf<MediaAssetID, MonitorMediaRecord<P>>()
        if (!capture.resetLibrary) old.records.forEach { values[it.asset.id] = it }
        capture.removed.forEach { values.remove(it) }
        capture.upserts.forEach { values[it.asset.id] = projected(it, capturedFavorites) }
        // An amendment requires a surviving row; it cannot resurrect an absent tombstone.
        capture.amendments.forEach { if (it.asset.id in values) values[it.asset.id] = projected(it, capturedFavorites) }
        val order = (capture.order.orEmpty() + values.keys).distinct().filter { it in values }
        val records = order.mapNotNull { values[it] }.map { projected(it, capturedFavorites) }
        val retained = records.map { it.asset.id }.toSet()
        val retired = extractRetiredOperations(retained)
        capture.sourceFavoriteKeys?.let { favorites = it.toSet() }
        mutate { it.copy(catalog = catalog ?: old.catalog, records = records,
            catalogPageCount = it.catalogPageCount + if (catalog != null) 1 else 0,
            fetchedCount = records.size, selectedIDs = it.selectedIDs.intersect(retained),
            entries = it.entries.filterKeys { id -> id in retained },
            transferring = it.transferring - retired.ids, progress = it.progress - retired.ids,
            hostProgress = it.hostProgress - retired.hostKeys) }
        retired.dispose()
        if (!ifCurrent()) return false
        if (capture.sourceFavoriteKeys != null) favoritesStore.saveFavorites(favorites)
        if (!ifCurrent()) return false
        // Only rows this capture added or amended can have new cache facts; others keep theirs.
        reloadEntries((capture.upserts.asSequence() + capture.amendments.asSequence()).map { it.asset.id }.filter { it in retained }.toSet())
        return ifCurrent()
    }
    private fun cancelTargetedScans() {
        val tasks = targetedTasks.values.toList()
        targetedTasks.clear(); targetedRequests.clear(); dirtyDuringFull.clear()
        tasks.forEach { it.cancel() }
    }
    /** A full scan: init, begin, clear, removal and an app-owned commit through this root. */
    private fun reloadEntries() {
        val request = UUID.randomUUID(); val generation = lifetime; entryRequest = request
        val previous = entryTask; entryTask = null; previous?.cancel()
        cancelTargetedScans()
        if (entryRequest != request || lifetime != generation) return
        when (cacheScanning) {
            MonitorMediaCacheScanning.IMMEDIATE -> {
                val entries = state.value.records.associate { it.asset.id to cache.entry(it) }
                if (entryRequest == request && lifetime == generation) mutate { it.copy(entries = entries, cacheRevision = it.cacheRevision + 1) }
            }
            MonitorMediaCacheScanning.BACKGROUND -> {
                val plan = cache.readPlan(state.value.records)
                val task = owner.launch(start = CoroutineStart.LAZY) {
                    try {
                        val snapshot = readSnapshot(plan)
                        if (!isActive || entryRequest != request || lifetime != generation ||
                            snapshot.planID != plan.id || snapshot.generation != cache.directory.generation) return@launch
                        entryTask = null
                        // A page that removed records during the scan no longer restarts it: keep only
                        // entries of records that still exist.
                        mutate { state ->
                            val current = state.records.mapTo(HashSet()) { it.asset.id }
                            state.copy(entries = snapshot.entries.filterKeys { it in current }, cacheRevision = state.cacheRevision + 1)
                        }
                    } catch (error: Exception) { if (entryRequest == request && lifetime == generation) entryTask = null }
                    if (entryRequest == request && lifetime == generation && entryTask == null && dirtyDuringFull.isNotEmpty()) {
                        val dirty = dirtyDuringFull.toSet(); dirtyDuringFull.clear(); reloadEntries(dirty)
                    }
                }
                entryTask = task; task.start()
            }
        }
    }
    /** A targeted scan of the records one commit or capture touched; null rescans everything. */
    private fun reloadEntries(ids: Set<MediaAssetID>?) {
        if (ids == null) { reloadEntries(); return }
        if (ids.isEmpty()) return
        val generation = lifetime
        when (cacheScanning) {
            MonitorMediaCacheScanning.IMMEDIATE -> {
                val scanned = ids.mapNotNull { id -> record(id)?.let { id to cache.entry(it) } }.toMap()
                if (lifetime != generation) return
                mutate { state -> state.copy(entries = state.entries + scanned - (ids - scanned.keys), cacheRevision = state.cacheRevision + 1) }
            }
            MonitorMediaCacheScanning.BACKGROUND -> {
                if (entryTask != null) { dirtyDuringFull += ids; return }
                val records = ids.mapNotNull(::record)
                val request = UUID.randomUUID(); val epoch = entryRequest
                ids.forEach { targetedRequests[it] = request }
                val plan = cache.readPlan(records)
                val task = owner.launch(start = CoroutineStart.LAZY) {
                    try {
                        val snapshot = readSnapshot(plan)
                        if (!isActive || entryRequest != epoch || lifetime != generation ||
                            snapshot.planID != plan.id || snapshot.generation != cache.directory.generation) return@launch
                        val owned = ids.filter { targetedRequests[it] == request }
                        if (owned.isEmpty()) return@launch
                        owned.forEach { targetedRequests.remove(it) }
                        val present = owned.filter { record(it) != null }
                        mutate { state ->
                            val entries = state.entries.toMutableMap()
                            owned.forEach { id -> if (id !in present) entries.remove(id) }
                            present.forEach { id -> snapshot.entries[id]?.let { entries[id] = it } ?: entries.remove(id) }
                            state.copy(entries = entries, cacheRevision = state.cacheRevision + 1)
                        }
                    } catch (_: Exception) {
                        // A failed targeted scan keeps the previous facts; the next commit rescans.
                    } finally {
                        targetedTasks.remove(request)
                        ids.forEach { if (targetedRequests[it] == request) targetedRequests.remove(it) }
                    }
                }
                targetedTasks[request] = task; task.start()
            }
        }
    }

    public val actionToken: MonitorMediaLibraryActionToken get() = MonitorMediaLibraryActionToken(lifetime, browse?.binding)
    public fun isCurrent(token: MonitorMediaLibraryActionToken): Boolean = lifetime == token.lifetime && browse?.binding == token.binding
    /** Accepted local action; camera observations stay unchanged until a source delta. */
    public fun applyLocalRemoval(ids: Set<MediaAssetID>, token: MonitorMediaLibraryActionToken, removeLocalFavorites: Boolean = true) {
        if (!isCurrent(token)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        val old = state.value; val removed = old.records.filter { it.asset.id in ids }
        val records = old.records.filterNot { it.asset.id in ids }
        if (removeLocalFavorites) favorites = favorites - removed.map { it.address.favoriteKey }.toSet()
        val retired = extractRetiredOperations(records.map { it.asset.id }.toSet())
        mutate { it.copy(records = records, selectedIDs = it.selectedIDs - ids,
            entries = it.entries.filterKeys { id -> id !in ids }, fetchedCount = records.size,
            transferring = it.transferring - retired.ids, progress = it.progress - retired.ids,
            hostProgress = it.hostProgress - retired.hostKeys) }
        retired.dispose()
        if (!isCurrent(token)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        if (removeLocalFavorites) favoritesStore.saveFavorites(favorites)
        if (!isCurrent(token)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        cache.save(state.value.records) { isCurrent(token) }
        if (!isCurrent(token)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        reloadEntries()
    }
    /** Actual local metadata IO changes display facts, never camera observations. */
    public fun updateLocalFacts(updates: Map<MediaAssetID, MonitorMediaFilterFacts>, token: MonitorMediaLibraryActionToken) {
        if (!isCurrent(token)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        mutate { it.copy(records = it.records.map { record -> updates[record.asset.id]?.let { facts -> record.copy(facts = facts) } ?: record }) }
    }
    /** Collects the real supplied cursor; app composition performs no query/paging loop. */
    public suspend fun reconcileCatalog(supplied: MediaCatalogCursor, binding: MediaBrowseBinding,
        token: MonitorMediaLibraryActionToken) {
        if (!isCurrent(token) || !state.value.browsing || token.binding != binding) {
            supplied.close(); throw MediaServiceException(MediaServiceFailure.RETIRED)
        }
        val request = UUID.randomUUID(); val generation = lifetime; listing = request
        val oldList = listTask; val oldReconciliation = reconciliationTask; val oldCursor = cursor
        listTask = null; reconciliationTask = null; cursor = null
        oldList?.cancel(); oldReconciliation?.cancel(); oldCursor?.close()
        if (!admitted(generation, request, binding)) { supplied.close(); throw MediaServiceException(MediaServiceFailure.RETIRED) }
        mutate { it.copy(fetching = false, catalogPageCount = 0) }
        if (!admitted(generation, request, binding)) { supplied.close(); throw MediaServiceException(MediaServiceFailure.RETIRED) }
        cursor = supplied
        val work = owner.async(start = CoroutineStart.LAZY) {
            try {
                consumeCursor(supplied, binding, generation, request)
                if (!admitted(generation, request, binding) || !isActive) throw MediaServiceException(MediaServiceFailure.RETIRED)
            } finally {
                supplied.close()
                if (admitted(generation, request, binding)) { cursor = null; reconciliationTask = null }
            }
        }
        reconciliationTask = work; work.start()
        try { work.await() } catch (error: CancellationException) { work.cancel(); throw error }
    }

    /** An app-owned playback/delivery adapter committed through this same root lifetime. */
    public fun refreshLocalCache() { reloadEntries() }
    /** A missing indexed asset is a host-only request and never creates a catalog row. */
    public fun captureIO(key: MonitorMediaLibraryIOKey, asset: MediaAssetID?,
        ifCurrent: () -> Boolean): MonitorMediaLibraryIOAuthority {
        val token = actionToken
        return MonitorMediaLibraryIOAuthority(hostOwner, key, asset, cache.directory) {
            if (disposed || !isCurrent(token) || (asset != null && record(asset) == null)) false
            else {
                val allowed = ifCurrent()
                allowed && !disposed && isCurrent(token) && (asset == null || record(asset) != null)
            }
        }
    }
    /** Capture at confirmation, before SDK preparation can reenter or retire the gallery. */
    public fun captureDeletion(key: MonitorMediaLibraryIOKey,
        ifCurrent: () -> Boolean): MonitorMediaLibraryDeletionAuthority {
        val capturedService = service
        val sourceCurrent = {
            if (disposed || service !== capturedService) false else {
                val allowed = ifCurrent()
                allowed && !disposed && service === capturedService
            }
        }
        return MonitorMediaLibraryDeletionAuthority(hostOwner, key, cache.directory, actionToken, sourceCurrent) { token ->
            if (disposed || !isCurrent(token)) false else {
                val allowed = sourceCurrent()
                allowed && !disposed && isCurrent(token)
            }
        }
    }

    /** Existing IO scheduler, retaining exactly this consumed claim during catalog preparation. */
    public suspend fun <V, L> deleteHostBatch(authority: MonitorMediaLibraryDeletionAuthority,
        targets: List<MonitorMediaDeletionTarget<V, L>>, selectedCount: Int,
        preparation: MonitorMediaDeletionPreparation = MonitorMediaDeletionPreparation.PRESERVE_GALLERY,
        prepare: () -> Unit = {}, progress: ((MonitorMediaDeletionProgress) -> Unit)? = null,
        port: MonitorMediaDeletionPort<V, L>): Int {
        if (authority.owner != hostOwner || authority.directory !== cache.directory ||
            !authority.consume() || !currentCoroutineContext().isActive) return 0
        val io = MonitorMediaLibraryIOAuthority(hostOwner, authority.key, null, authority.directory) { authority.isCurrent }
        val operation = try {
            startHost(io, MonitorMediaLibraryIOPurpose.DELETION, null)?.also { it.deletion = authority }
                ?: run { authority.retire(); return 0 }
        } catch (_: Exception) { authority.retire(); return 0 }
        var removed = 0
        try {
            requireHost(operation); prepare(); requireHost(operation)
            if (preparation == MonitorMediaDeletionPreparation.RETIRE_GALLERY) {
                val replacement = UUID.randomUUID()
                authority.prepare(MonitorMediaLibraryActionToken(replacement, null))
                retire(replacement, io.id); requireHost(operation)
            }
            performHost(operation) {
                var finishedCount = 0
                val scheduledPort = MonitorMediaDeletionPort(port.remove, port.commit, finish = {
                    if (hostCurrent(operation)) {
                        if (authority.clearsSelection) clearSelection()
                        if (hostCurrent(operation)) {
                            val finish = DeletionFinish(authority.id, lifetime, authority.sourceCurrent)
                            finishingDeletions[authority.id] = finish
                            authority.beginCompletion { finishingCurrent(finish) }
                            if (authority.isCompleting && finishingDeletions[authority.id] === finish) {
                                port.finish()
                                // A retired gallery returns to browsing by default (R-01); a caller that
                                // already relisted from finish makes this a refused repeat.
                                if (preparation == MonitorMediaDeletionPreparation.RETIRE_GALLERY && !finish.relisted &&
                                    currentCoroutineContext().isActive && authority.isCompleting && finishingDeletions[authority.id] === finish)
                                    relist(authority)
                                if (currentCoroutineContext().isActive && authority.isCompleting && finishingDeletions[authority.id] === finish) {
                                    val admission = actionToken
                                    finish.admission = admission
                                    authority.sealCompletion(finishedCount, admission)
                                }
                            }
                        }
                    }
                })
                scheduledPort.completed = { finishedCount = it; removed = it }
                removed = MonitorMediaOrderedDeletion.run(targets, selectedCount,
                    ifCurrent = { hostCurrent(operation) }, port = scheduledPort, progress = { value ->
                        if (hostCurrent(operation)) {
                            deletionProgressOwner = authority.id
                            mutate { it.copy(deletionProgress = value) }
                            if (hostCurrent(operation)) progress?.invoke(value)
                        }
                    })
                MediaTransferReceipt(0)
            }
        } catch (_: Exception) {
            // Retirement cannot undo source commits already accepted by this action.
        } finally {
            if (deletionProgressOwner == authority.id) {
                deletionProgressOwner = null; mutate { it.copy(deletionProgress = null) }
            }
            finishingDeletions.remove(authority.id)
            if (authority.completion?.isCurrent == true) authority.expireIO() else authority.retire()
            finishHost(operation, clearingProgress = false)
        }
        return removed
    }
    private fun requireAuthority(authority: MonitorMediaLibraryIOAuthority) {
        if (authority.owner != hostOwner || authority.directory !== cache.directory) throw MediaServiceException(MediaServiceFailure.RETIRED)
        authority.requireCurrent()
    }
    private fun hostCurrent(operation: HostOperation): Boolean {
        if (hostOperations[operation.authority.id] !== operation || !operation.authority.isCurrent) return false
        return hostOperations[operation.authority.id] === operation
    }
    private suspend fun requireHost(operation: HostOperation) {
        currentCoroutineContext().ensureActive()
        if (!hostCurrent(operation)) throw MediaServiceException(MediaServiceFailure.RETIRED)
    }
    private fun startHost(authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose, writer: MonitorMediaCacheWrite?): HostOperation? {
        requireAuthority(authority)
        val claim = HostClaim(authority.key, purpose)
        if (purpose != MonitorMediaLibraryIOPurpose.PLAYBACK && claim in hostClaims) return null
        if (authority.id in hostOperations) throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val operation = HostOperation(authority, purpose, writer)
        hostOperations[authority.id] = operation
        if (purpose != MonitorMediaLibraryIOPurpose.PLAYBACK) hostClaims[claim] = authority.id
        if (purpose.tracksProgress) {
            val previous = hostProgressDelays.remove(authority.key)
            hostProgressOwners[authority.key] = authority
            previous?.cancel()
            mutate { it.copy(hostProgress = it.hostProgress + (authority.key to 0.0)) }
        }
        if (!hostCurrent(operation)) {
            finishHost(operation, clearingProgress = true); writer?.abort()
            throw MediaServiceException(MediaServiceFailure.RETIRED)
        }
        return operation
    }
    private fun finishHost(operation: HostOperation, clearingProgress: Boolean) {
        val authority = operation.authority
        if (hostOperations[authority.id] !== operation) return
        hostOperations.remove(authority.id)
        val claim = HostClaim(authority.key, operation.purpose)
        if (hostClaims[claim] == authority.id) hostClaims.remove(claim)
        if (clearingProgress) clearHostProgress(authority)
    }
    private fun hostSink(operation: HostOperation, attempt: UUID, hint: Long?, sink: MediaByteSink): MediaByteSink =
        object : MediaTransferProgressSink {
            var expected = hint?.takeIf { it > 0 }
            var bytes = 0L
            override suspend fun expectedByteCount(count: Long?) {
                withContext(owner.coroutineContext.minusKey(Job)) {
                    requireHost(operation)
                    if (operation.attempt != attempt) throw MediaServiceException(MediaServiceFailure.RETIRED)
                    expected = count?.takeIf { it > 0 }
                }
            }
            override suspend fun write(chunk: ByteArray) {
                withContext(owner.coroutineContext.minusKey(Job)) {
                    requireHost(operation)
                    if (operation.attempt != attempt) throw MediaServiceException(MediaServiceFailure.RETIRED)
                    sink.write(chunk)
                    requireHost(operation)
                    if (operation.attempt != attempt) throw MediaServiceException(MediaServiceFailure.RETIRED)
                    bytes += chunk.size
                    if (hostProgressOwners[operation.authority.key]?.id == operation.authority.id &&
                        operation.purpose.tracksProgress) {
                        val value = expected?.let { (bytes.toDouble() / it).coerceAtMost(1.0) } ?: 0.0
                        mutate { it.copy(hostProgress = it.hostProgress + (operation.authority.key to value)) }
                    }
                }
            }
        }
    private suspend fun performHost(operation: HostOperation, expected: Long?, sink: MediaByteSink,
        transfer: suspend (MediaByteSink) -> MediaTransferReceipt): MediaTransferReceipt {
        val attempt = UUID.randomUUID(); operation.attempt = attempt
        val progressSink = hostSink(operation, attempt, expected, sink)
        return performHost(operation) { transfer(progressSink) }
    }
    private suspend fun performHost(operation: HostOperation,
        transfer: suspend () -> MediaTransferReceipt): MediaTransferReceipt {
        val task = owner.async(start = CoroutineStart.LAZY) {
            requireHost(operation)
            val receipt = transfer()
            requireHost(operation)
            receipt
        }
        operation.task = task
        if (!hostCurrent(operation)) task.cancel() else task.start()
        try { return task.await() }
        catch (error: CancellationException) {
            if (operation.purpose != MonitorMediaLibraryIOPurpose.DELETION) task.cancel()
            throw error
        }
    }
    /** Original native thumbnail bytes, under the same task/claim lifetime; no cache or progress mutation. */
    public suspend fun readHostThumbnail(authority: MonitorMediaLibraryIOAuthority,
        read: suspend () -> ByteArray): ByteArray? =
        readHostBytes(authority, MonitorMediaLibraryIOPurpose.THUMBNAIL, read)

    /** Uncached original image bytes with a real record and a distinct claim, under existing IO retirement. */
    public suspend fun readHostOriginalImage(authority: MonitorMediaLibraryIOAuthority,
        read: suspend () -> ByteArray): ByteArray? {
        if (authority.asset == null) throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        return readHostBytes(authority, MonitorMediaLibraryIOPurpose.ORIGINAL_IMAGE, read)
    }

    private suspend fun readHostBytes(authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose, read: suspend () -> ByteArray): ByteArray? {
        currentCoroutineContext().ensureActive()
        val operation = startHost(authority, purpose, null) ?: return null
        try {
            var bytes: ByteArray? = null
            performHost(operation) {
                val incoming = read()
                bytes = incoming
                MediaTransferReceipt(incoming.size.toLong())
            }
            requireHost(operation)
            return bytes
        } finally { finishHost(operation, clearingProgress = false) }
    }
    public suspend fun ensureHostThumbnail(authority: MonitorMediaLibraryIOAuthority, address: String,
        read: suspend () -> ByteArray) {
        currentCoroutineContext().ensureActive(); requireAuthority(authority)
        if (HostClaim(authority.key, MonitorMediaLibraryIOPurpose.THUMBNAIL) in hostClaims) return
        if (authority.id in hostOperations) throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val writer = cache.directory.beginWrite(address)
        val operation = startHost(authority, MonitorMediaLibraryIOPurpose.THUMBNAIL, writer)
            ?: run { writer.abort(); return }
        try {
            val receipt = performHost(operation, null, writer) { sink ->
                val bytes = read()
                if (bytes.isEmpty()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.EMPTY)
                sink.write(bytes); MediaTransferReceipt(bytes.size.toLong())
            }
            requireHost(operation); writer.commit(receipt); reloadEntries(authority.asset?.let(::setOf))
        } finally { writer.abort(); finishHost(operation, clearingProgress = false) }
    }
    /** One host stream and canonical write under the existing library/cache lifetime. */
    public suspend fun cacheHostFile(authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose, address: String, expectedByteCount: Long? = null,
        transfer: suspend (MediaByteSink) -> MediaTransferReceipt): File? = cacheHostFile(
            authority, purpose, address, MediaTransferPlan(expectedByteCount, listOf(transfer), retry = { false }))
    /** Each real attempt receives a fresh writer, so a failed partial body cannot join the next. */
    public suspend fun cacheHostFile(authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose, address: String, plan: MediaTransferPlan): File? {
        if (purpose == MonitorMediaLibraryIOPurpose.DELETION) throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        currentCoroutineContext().ensureActive(); requireAuthority(authority)
        // A download of a clip that is already downloading (Share while the player's cache runs,
        // or while a cancelled one finishes its chunk) joins it and downloads only if it failed.
        while (purpose == MonitorMediaLibraryIOPurpose.DOWNLOAD) {
            val claimant = hostClaims[HostClaim(authority.key, purpose)] ?: break
            val running = hostOperations[claimant]?.takeIf { it.purpose == MonitorMediaLibraryIOPurpose.DOWNLOAD } ?: break
            val joined = running.completion.await()
            requireAuthority(authority)
            if (joined != null) return joined
            if (hostOperations[claimant] === running) break
        }
        if (purpose != MonitorMediaLibraryIOPurpose.PLAYBACK && HostClaim(authority.key, purpose) in hostClaims) return null
        if (authority.id in hostOperations) throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val operation = startHost(authority, purpose, null) ?: return null
        var committed: File? = null
        try {
            var lastError: Throwable = MediaServiceException(MediaServiceFailure.UNAVAILABLE)
            for ((index, transfer) in plan.attempts.withIndex()) {
                requireHost(operation)
                val writer = cache.directory.beginWrite(address); operation.writer = writer
                val receipt = try { performHost(operation, plan.expectedByteCount, writer, transfer) }
                catch (error: Exception) {
                    writer.abort(); operation.writer = null; requireHost(operation)
                    if (!plan.retry(error)) throw error
                    requireHost(operation); lastError = error; continue
                }
                requireHost(operation); plan.accepted?.invoke(index, receipt); requireHost(operation)
                val location = writer.commit(receipt); reloadEntries(authority.asset?.let(::setOf)); requireHost(operation)
                committed = location
                return location
            }
            throw lastError
        } finally {
            operation.writer?.abort(); finishHost(operation, clearingProgress = committed == null)
            operation.completion.complete(committed)
        }
    }
    /** SDK staging compatibility; the shared owner alone copies and commits the canonical name. */
    public suspend fun cacheHostStagedFile(authority: MonitorMediaLibraryIOAuthority,
        purpose: MonitorMediaLibraryIOPurpose, address: String, expectedByteCount: Long? = null,
        stagingAt: File? = null, staging: suspend (File) -> Unit): File? {
        if (purpose == MonitorMediaLibraryIOPurpose.DELETION) throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        currentCoroutineContext().ensureActive(); requireAuthority(authority)
        // A running download is joined by cacheHostFile below, not refused here.
        if (purpose != MonitorMediaLibraryIOPurpose.PLAYBACK && purpose != MonitorMediaLibraryIOPurpose.DOWNLOAD &&
            HostClaim(authority.key, purpose) in hostClaims) return null
        if (authority.id in hostOperations) throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val destination = cache.directory.file(address)
        val incoming = stagingAt ?: File(destination.parentFile, ".incoming-${authority.id}")
        try {
            return cacheHostFile(authority, purpose, address, expectedByteCount) { sink ->
                staging(incoming); authority.requireCurrent()
                val count = MonitorMediaLibraryFileCopy.copy(incoming, sink, owner.coroutineContext.minusKey(Job))
                MediaTransferReceipt(count, expectedByteCount)
            }
        } finally { incoming.delete() }
    }
    /** The existing player owns its writer; this library owns progress and source retirement. */
    public suspend fun transferHostFile(authority: MonitorMediaLibraryIOAuthority,
        expectedByteCount: Long? = null, sink: MediaByteSink,
        transfer: suspend (MediaByteSink) -> MediaTransferReceipt): MediaTransferReceipt {
        currentCoroutineContext().ensureActive()
        val operation = startHost(authority, MonitorMediaLibraryIOPurpose.PLAYBACK, null)
            ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        var complete = false
        try {
            val receipt = performHost(operation, expectedByteCount, sink, transfer)
            requireHost(operation); complete = true
            return receipt
        } finally { finishHost(operation, clearingProgress = !complete) }
    }
    /** A borrowed native writer cannot rewind; only the accepted attempt is copied from disk. */
    public suspend fun transferHostFile(authority: MonitorMediaLibraryIOAuthority,
        sink: MediaByteSink, plan: MediaTransferPlan, stagingRoot: File): MediaTransferReceipt {
        currentCoroutineContext().ensureActive()
        val operation = startHost(authority, MonitorMediaLibraryIOPurpose.PLAYBACK, null)
            ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        var complete = false
        try {
            var lastError: Throwable = MediaServiceException(MediaServiceFailure.UNAVAILABLE)
            for ((index, transfer) in plan.attempts.withIndex()) {
                requireHost(operation)
                val incoming = File(stagingRoot, "opc-player-${UUID.randomUUID()}.incoming")
                val staged = LibraryHostFileSink(incoming)
                try {
                    val receipt = try { performHost(operation, plan.expectedByteCount, staged, transfer) }
                    catch (error: Exception) {
                        requireHost(operation)
                        if (!plan.retry(error)) throw error
                        requireHost(operation); lastError = error; continue
                    }
                    staged.close(); requireHost(operation)
                    plan.accepted?.invoke(index, receipt); requireHost(operation)
                    val admitted = object : MediaByteSink {
                        override suspend fun write(chunk: ByteArray) {
                            requireHost(operation); sink.write(chunk); requireHost(operation)
                        }
                    }
                    val count = MonitorMediaLibraryFileCopy.copy(incoming, admitted, owner.coroutineContext.minusKey(Job))
                    requireHost(operation)
                    if (count != receipt.byteCount) throw MonitorMediaCacheException(MonitorMediaCacheFailure.INVALID_RECEIPT)
                    complete = true
                    return MediaTransferReceipt(count, receipt.expectedByteCount)
                } finally { try { staged.close() } finally { incoming.delete() } }
            }
            throw lastError
        } finally { finishHost(operation, clearingProgress = !complete) }
    }
    public fun clearHostProgress(authority: MonitorMediaLibraryIOAuthority) {
        if (authority.owner != hostOwner || hostProgressOwners[authority.key]?.id != authority.id) return
        hostProgressOwners.remove(authority.key)
        hostProgressDelays.remove(authority.key)?.cancel()
        mutate { it.copy(hostProgress = it.hostProgress - authority.key) }
    }
    public fun completeHostTransfer(authority: MonitorMediaLibraryIOAuthority, role: MediaRepresentationRole) {
        val progressOwner = hostProgressOwners[authority.key]
        if (authority.owner != hostOwner || !authority.isCurrent || (progressOwner != null && progressOwner.id != authority.id)) return
        hostProgressOwners[authority.key] = authority
        reloadEntries(authority.asset?.let(::setOf))
        if (!authority.isCurrent || hostProgressOwners[authority.key]?.id != authority.id) return
        if (role != MediaRepresentationRole.ORIGINAL) { clearHostProgress(authority); return }
        hostProgressDelays.remove(authority.key)?.cancel()
        val task = owner.launch(start = CoroutineStart.LAZY) {
            sleep(450)
            if (isActive && authority.isCurrent && hostProgressOwners[authority.key]?.id == authority.id &&
                hostProgress[authority.key] == 1.0) clearHostProgress(authority)
        }
        hostProgressDelays[authority.key] = task
        mutate { it.copy(hostProgress = it.hostProgress + (authority.key to 1.0)) }
        if (!authority.isCurrent || hostProgressOwners[authority.key]?.id != authority.id) task.cancel() else task.start()
    }
    private data class RetiredOperations(val ids: Set<MediaAssetID>,
        val hostKeys: Set<MonitorMediaLibraryIOKey>, val dispose: () -> Unit)
    private fun extractRetiredOperations(retained: Set<MediaAssetID>? = null, retainingHost: UUID? = null,
        completingClaim: UUID? = null): RetiredOperations {
        val ids = transfers.keys.filterNot { retained?.contains(it) == true }.toSet()
        val oldTransfers = ids.mapNotNull { transfers.remove(it) }
        val thumbIDs = thumbnails.keys.filterNot { retained?.contains(it) == true }
        val tasks = thumbIDs.mapNotNull { thumbnailTasks.remove(it) }
        val writers = thumbIDs.mapNotNull { thumbnailWriters.remove(it) }
        thumbIDs.forEach { thumbnails.remove(it) }
        fun retireHost(authority: MonitorMediaLibraryIOAuthority): Boolean =
            retained == null || authority.asset?.let { it !in retained } == true
        val hostRuns = hostOperations.values.filter { it.authority.id != retainingHost && retireHost(it.authority) }
        hostRuns.forEach {
            hostOperations.remove(it.authority.id)
            val claim = HostClaim(it.authority.key, it.purpose)
            if (hostClaims[claim] == it.authority.id) hostClaims.remove(claim)
        }
        val hostKeys = hostProgressOwners.filterValues(::retireHost).keys.toSet()
        val hostDelays = hostKeys.mapNotNull { hostProgressDelays.remove(it) }
        hostKeys.forEach { hostProgressOwners.remove(it) }
        return RetiredOperations(ids, hostKeys) {
            oldTransfers.forEach { it.task.cancel(); it.writer.abort() }
            tasks.forEach { it.cancel() }; writers.forEach { it.abort() }
            hostRuns.forEach {
                if (it.deletion?.id == completingClaim) it.deletion?.expireIO() else it.deletion?.retire()
                if (it.purpose != MonitorMediaLibraryIOPurpose.DELETION) it.task?.cancel()
                it.writer?.abort()
            }
            hostDelays.forEach { it.cancel() }
        }
    }
    private fun retireOperations(retained: Set<MediaAssetID>? = null) {
        val retired = extractRetiredOperations(retained)
        if (retired.ids.isNotEmpty() || retired.hostKeys.isNotEmpty()) mutate {
            it.copy(transferring = it.transferring - retired.ids, progress = it.progress - retired.ids,
                hostProgress = it.hostProgress - retired.hostKeys)
        }
        retired.dispose()
    }

    public fun ensureThumbnail(id: MediaAssetID) {
        if (id in thumbnails) return
        val record = record(id) ?: return
        val address = record.address.thumbnail ?: return
        if (cache.entry(record).thumbnail != null) return
        val source = browse?.thumbnails ?: return
        val operation = UUID.randomUUID(); val generation = lifetime; val cacheGeneration = cache.directory.generation
        thumbnails[id] = operation
        val task = owner.launch(start = CoroutineStart.LAZY) {
            try {
                if (!current(generation) || thumbnails[id] != operation) return@launch
                val bytes = source.thumbnail(id)
                if (!current(generation) || thumbnails[id] != operation || cache.directory.generation != cacheGeneration || !isActive) return@launch
                val writer = cache.directory.beginWrite(address); thumbnailWriters[id] = writer
                try {
                    writer.write(bytes)
                    if (!current(generation) || thumbnails[id] != operation || !isActive) return@launch
                    writer.commit(MediaTransferReceipt(bytes.size.toLong())); reloadEntries(setOf(id))
                } finally { writer.abort() }
            } catch (_: Exception) { /* A thumbnail refusal leaves the row and original untouched. */ }
            finally {
                if (thumbnails[id] == operation) { thumbnails.remove(id); thumbnailTasks.remove(id); thumbnailWriters.remove(id) }
            }
        }
        thumbnailTasks[id] = task; task.start()
    }
    public suspend fun ensureThumbnailAndWait(id: MediaAssetID) {
        ensureThumbnail(id)
        thumbnailTasks[id]?.join()
    }
    public suspend fun cacheRepresentation(representation: MediaRepresentationID, id: MediaAssetID): File {
        // A clip already being cached (the player left its cache running, or a cancelled cache
        // is still finishing a chunk) is joined, never refused: Share of that clip waits for it
        // and caches the clip itself only when it ended without this representation.
        while (true) {
            val running = transfers[id] ?: break
            val joined = running.completion.await()
            if (running.representation == representation && joined != null && isCurrentFile(joined, representation, id)) return joined
            // An operation refused before it started can leave its finished slot behind.
            if (transfers[id]?.id == running.id) transfers.remove(id)
        }
        val record = record(id) ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val source = browse?.transfers ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val descriptor = record.asset.representations.firstOrNull { it.id == representation }
            ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val address = record.address.representations[representation]
            ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        if (id in transfers) throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val operation = UUID.randomUUID(); val generation = lifetime
        val writer = cache.directory.beginWrite(address)
        val sink = object : MediaByteSink {
            var bytes = 0L
            override suspend fun write(chunk: ByteArray) {
                writer.write(chunk); bytes += chunk.size
                withContext(owner.coroutineContext.minusKey(Job)) {
                    if (current(generation) && transfers[id]?.id == operation && (descriptor.byteCount ?: 0) > 0) {
                        mutate { it.copy(progress = it.progress + (id to (bytes.toDouble() / checkNotNull(descriptor.byteCount)).coerceAtMost(1.0))) }
                    }
                }
            }
        }
        val task = owner.async(start = CoroutineStart.LAZY) {
            try {
                if (!current(generation) || transfers[id]?.id != operation) throw MediaServiceException(MediaServiceFailure.RETIRED)
                val receipt = source.transfer(representation, sink)
                currentCoroutineContext().ensureActive()
                if (!current(generation) || transfers[id]?.id != operation) throw MediaServiceException(MediaServiceFailure.RETIRED)
                // A response that ended short of the catalog size (an early EOF, or a shorter
                // response length) is not this original: the cache would never read it as one.
                if (descriptor.role == MediaRepresentationRole.ORIGINAL &&
                    !cache.eligibility.accepts(receipt.byteCount, descriptor.byteCount))
                    throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
                val file = writer.commit(receipt); reloadEntries(setOf(id))
                if (!current(generation) || transfers[id]?.id != operation || !isActive) throw MediaServiceException(MediaServiceFailure.RETIRED)
                if (id in state.value.progress) mutate { it.copy(progress = it.progress + (id to 1.0)) }
                sleep(450)
                currentCoroutineContext().ensureActive()
                if (!current(generation) || transfers[id]?.id != operation) throw MediaServiceException(MediaServiceFailure.RETIRED)
                file
            } finally { writer.abort() }
        }
        val completion = CompletableDeferred<File?>()
        var location: File? = null
        transfers[id] = Transfer(operation, representation, writer, task, completion)
        mutate { it.copy(transferring = it.transferring + id,
            progress = if (descriptor.byteCount != null) it.progress + (id to 0.0) else it.progress) }
        if (!current(generation) || transfers[id]?.id != operation) {
            task.cancel(); writer.abort(); completion.complete(null)
            throw MediaServiceException(MediaServiceFailure.RETIRED)
        }
        task.start()
        try {
            val file = try { task.await() } catch (error: CancellationException) {
                task.cancel()
                // Only the caller's own cancellation stays a cancellation. A transfer the source
                // or a retirement cancelled is a failure, so a batch reports it and goes on.
                currentCoroutineContext().ensureActive()
                throw MediaServiceException(MediaServiceFailure.RETIRED)
            }
            location = file
            return file
        }
        catch (error: CancellationException) { throw error }
        catch (error: Exception) {
            if (current(generation) && transfers[id]?.id == operation) mutate { it.copy(note = copy.downloadFailed) }
            throw error
        }
        finally {
            if (transfers[id]?.id == operation) {
                transfers.remove(id); mutate { it.copy(transferring = it.transferring - id, progress = it.progress - id) }
            }
            // After the slot is released, so a joiner never rejoins this operation.
            completion.complete(location)
        }
    }
    /** A joined file stands only while it is still the current record's file: a retained amendment can move an original's address while its transfer runs. */
    private fun isCurrentFile(location: File, representation: MediaRepresentationID, id: MediaAssetID): Boolean {
        val current = record(id) ?: return false
        val descriptor = current.asset.representations.firstOrNull { it.id == representation } ?: return false
        if (descriptor.role != MediaRepresentationRole.ORIGINAL) return true
        return cache.entry(current).original?.absoluteFile?.normalize() == location.absoluteFile.normalize()
    }
    public suspend fun cacheOriginal(id: MediaAssetID): File = cacheRepresentation(
        record(id)?.asset?.representations?.firstOrNull { it.role == MediaRepresentationRole.ORIGINAL }?.id
            ?: throw MediaServiceException(MediaServiceFailure.UNSUPPORTED), id)
    public suspend fun delete(ids: List<MediaAssetID>): List<MediaDeleteResult> {
        val browse = browse ?: throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        val source = browse.deletion ?: throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        val token = actionToken; val results = source.delete(ids)
        currentCoroutineContext().ensureActive()
        if (!isCurrent(token) || this.browse?.binding != browse.binding) throw MediaServiceException(MediaServiceFailure.RETIRED)
        val accepted = results.filter { it.outcome == MediaDeleteOutcome.ACCEPTED }.map { it.asset }.toSet()
        // This optimistic local change does not mutate the reported source catalog.
        applyLocalRemoval(accepted, token, removeLocalFavorites = false); return results
    }
    public suspend fun clearCache() { clearCache(preservingMetadata = true) }
    /** Settings may drop cached camera metadata; the original no-argument API preserves it. */
    public suspend fun clearCache(preservingMetadata: Boolean) {
        val token = actionToken; retireOperations()
        currentCoroutineContext().ensureActive()
        if (!isCurrent(token)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        cache.clear(preservingMetadata)
        currentCoroutineContext().ensureActive()
        if (!isCurrent(token)) throw MediaServiceException(MediaServiceFailure.RETIRED)
        reloadEntries()
    }
}
