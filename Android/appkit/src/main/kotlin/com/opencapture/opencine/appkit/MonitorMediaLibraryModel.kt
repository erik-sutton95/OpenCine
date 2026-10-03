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
)
public enum class MonitorMediaCategoryFilter { ALL, VIDEOS, PHOTOS, FAVORITES }
public enum class MonitorMediaSort { NEWEST, OLDEST, NAME, RATING }
public interface MonitorMediaFavoritesStore {
    public fun favorites(): Set<String>
    public fun saveFavorites(keys: Set<String>)
}

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
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    private val owner = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private var favorites = favoritesStore.favorites()
    private val mutable = MutableStateFlow(MonitorMediaLibraryState(records = cache.load().map {
        it.copy(favorite = it.favorite || it.address.favoriteKey in favorites)
    }))
    public val state: StateFlow<MonitorMediaLibraryState<P>> = mutable.asStateFlow()
    private var browse: CameraMediaBrowse? = null
    private var cursor: MediaCatalogCursor? = null
    private val lifetime: UUID get() = state.value.lifetimeToken
    private var listing = UUID.randomUUID()
    private var openTask: Job? = null
    private var listTask: Job? = null
    private data class Transfer(val id: UUID, val writer: MonitorMediaCacheWrite, val task: Deferred<File>)
    private val transfers = mutableMapOf<MediaAssetID, Transfer>()
    private val thumbnails = mutableMapOf<MediaAssetID, UUID>()
    private val thumbnailTasks = mutableMapOf<MediaAssetID, Job>()
    private val thumbnailWriters = mutableMapOf<MediaAssetID, MonitorMediaCacheWrite>()
    init { mutate { it.copy(catalog = MediaCatalog(assets = it.records.map { record -> record.asset })) }; reloadEntries() }
    private fun mutate(change: (MonitorMediaLibraryState<P>) -> MonitorMediaLibraryState<P>) { mutable.value = change(mutable.value) }
    public val canRefresh: Boolean get() = service != null
    public val binding: MediaBrowseBinding? get() = browse?.binding
    public val canTransfer: Boolean get() = browse?.transfers != null
    public val canDelete: Boolean get() = browse?.deletion != null
    public val libraryRecords: List<MonitorMediaRecord<P>> get() = state.value.records.let { records ->
        if (service == null) records.filter { state.value.entries[it.asset.id]?.isPlayableOffline == true } else records
    }
    public fun records(category: MonitorMediaCategoryFilter): List<MonitorMediaRecord<P>> = libraryRecords.filter {
        when (category) {
            MonitorMediaCategoryFilter.ALL -> true
            MonitorMediaCategoryFilter.VIDEOS -> it.asset.kind == MediaAssetKind.VIDEO
            MonitorMediaCategoryFilter.PHOTOS -> it.asset.kind == MediaAssetKind.PHOTO
            MonitorMediaCategoryFilter.FAVORITES -> it.favorite
        }
    }
    public val displayedRecords: List<MonitorMediaRecord<P>> get() {
        val state = state.value
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
    public fun record(id: MediaAssetID): MonitorMediaRecord<P>? = state.value.records.firstOrNull { it.asset.id == id }
    public fun filter(category: MonitorMediaCategoryFilter = state.value.category, formats: Set<String> = state.value.formats,
        resolutions: Set<String> = state.value.resolutions, colors: Set<String> = state.value.colors,
        dateStart: String? = state.value.dateStart, dateEnd: String? = state.value.dateEnd) {
        mutate { it.copy(category = category, formats = formats.toSet(), resolutions = resolutions.toSet(),
            colors = colors.toSet(), dateStart = dateStart, dateEnd = dateEnd) }
    }
    public fun display(sort: MonitorMediaSort = state.value.sort, layout: MonitorMediaLayout = state.value.layout,
        thumbnailSize: MonitorThumbnailSize = state.value.thumbnailSize) { mutate { it.copy(sort = sort, layout = layout, thumbnailSize = thumbnailSize) } }
    public fun resetFilters() { filter(formats = emptySet(), resolutions = emptySet(), colors = emptySet(), dateStart = null, dateEnd = null) }
    public fun select(ids: Set<MediaAssetID>, selecting: Boolean = true) { mutate { it.copy(selecting = selecting, selectedIDs = ids.toSet()) } }
    public fun selectAll() { select(displayedRecords.map { it.asset.id }.toSet()) }
    public fun clearSelection() { select(emptySet(), selecting = false) }
    public fun toggleFavorite(id: MediaAssetID) {
        val record = record(id) ?: return
        val changed = record.copy(favorite = !record.favorite)
        favorites = if (changed.favorite) favorites + changed.address.favoriteKey else favorites - changed.address.favoriteKey
        favoritesStore.saveFavorites(favorites)
        mutate { it.copy(records = it.records.map { old -> if (old.asset.id == id) changed else old }) }
        try { cache.save(state.value.records) }
        catch (_: Exception) { mutate { it.copy(note = "Could not save local clip favorites.") } }
    }
    public fun bind(service: CameraMediaService?) {
        val wasBrowsing = state.value.browsing
        close(); this.service = service
        if (wasBrowsing) begin()
    }
    public fun begin() {
        if (state.value.browsing) return
        mutate { it.copy(lifetimeToken = UUID.randomUUID(), browsing = true, note = null) }
        open()
    }
    private fun open() {
        val service = service ?: return
        val generation = lifetime
        val task = owner.launch(start = CoroutineStart.LAZY) {
            if (!current(generation)) return@launch
            try {
                val opened = service.openBrowse()
                if (!current(generation) || !isActive) { opened.close(); return@launch }
                browse = opened; openTask = null; refresh()
            } catch (error: Exception) {
                if (current(generation)) { openTask = null; mutate { it.copy(note = "Could not open the camera library.") } }
            }
        }
        openTask = task; task.start()
    }
    private fun retire(): CameraMediaBrowse? {
        listing = UUID.randomUUID()
        mutate { it.copy(lifetimeToken = UUID.randomUUID(), browsing = false, fetching = false) }
        openTask?.cancel(); openTask = null; listTask?.cancel(); listTask = null; cursor?.close(); cursor = null
        retireOperations()
        val closed = browse; browse = null
        return closed
    }
    public fun close() { val closed = retire(); if (closed != null) owner.launch { closed.close() } }
    public suspend fun dispose() {
        val closed = retire()
        try { if (closed != null) withContext(NonCancellable) { closed.close() } } finally { owner.cancel() }
    }
    private fun current(generation: UUID): Boolean = state.value.browsing && lifetime == generation
    public fun refresh() {
        if (!state.value.browsing) return
        val browse = browse ?: run { if (openTask == null) open(); return }
        listTask?.cancel(); cursor?.close(); cursor = null
        val request = UUID.randomUUID(); listing = request; val generation = lifetime
        mutate { it.copy(fetching = true, fetchedCount = 0, note = null) }
        val task = owner.launch(start = CoroutineStart.LAZY) {
            if (!current(generation) || listing != request) return@launch
            try {
                val opened = browse.catalog()
                if (!current(generation) || listing != request || !isActive) { opened.close(); return@launch }
                cursor = opened
                try {
                    while (true) {
                        val delta = opened.next() ?: break
                        if (!current(generation) || listing != request || !isActive) return@launch
                        // No suspension between the fenced delta and immutable source capture.
                        val captures = delta.upserts.map { cache.codec.capture(it, browse.binding) }
                        apply(delta, captures); cache.save(state.value.records)
                    }
                } finally { opened.close() }
                if (current(generation) && listing == request) {
                    cursor = null; listTask = null; mutate { it.copy(fetching = false) }
                }
            } catch (error: Exception) {
                if (current(generation) && listing == request) {
                    cursor = null; listTask = null
                    mutate { it.copy(fetching = false, note = if (error is CancellationException) it.note else "Could not list camera clips.") }
                }
            }
        }
        listTask = task; task.start()
    }
    private fun apply(delta: MediaCatalogDelta, captures: List<MonitorMediaRecord<P>>) {
        val catalog = state.value.catalog.applying(delta)
        val byID = linkedMapOf<MediaAssetID, MonitorMediaRecord<P>>()
        if (!delta.reset) state.value.records.forEach { byID[it.asset.id] = it }
        delta.removed.forEach { byID.remove(it) }
        captures.forEach { byID[it.asset.id] = it.copy(favorite = it.favorite || it.address.favoriteKey in favorites) }
        val records = catalog.assets.mapNotNull { byID[it.id] }
        mutate { it.copy(catalog = catalog, records = records, fetchedCount = records.size,
            selectedIDs = it.selectedIDs.intersect(records.map { record -> record.asset.id }.toSet())) }
        retireOperations(records.map { it.asset.id }.toSet())
        reloadEntries()
    }
    private fun reloadEntries() { mutate { it.copy(entries = it.records.associate { record -> record.asset.id to cache.entry(record) }, cacheRevision = it.cacheRevision + 1) } }
    /** An app-owned playback/delivery adapter committed through this same root lifetime. */
    public fun refreshLocalCache() { reloadEntries() }
    private fun retireOperations(retained: Set<MediaAssetID> = emptySet()) {
        val removedTransfers = transfers.keys.filterNot { it in retained }.toSet()
        removedTransfers.forEach { id -> transfers.remove(id)?.let { it.task.cancel(); it.writer.abort() } }
        thumbnails.keys.filterNot { it in retained }.forEach { id ->
            thumbnailTasks.remove(id)?.cancel(); thumbnailWriters.remove(id)?.abort(); thumbnails.remove(id)
        }
        mutate { it.copy(transferring = it.transferring - removedTransfers, progress = it.progress - removedTransfers) }
    }
    public fun ensureThumbnail(id: MediaAssetID) {
        if (id in thumbnails) return
        val record = record(id) ?: return
        if (cache.entry(record).thumbnail != null) return
        val source = browse?.thumbnails ?: return
        val operation = UUID.randomUUID(); val generation = lifetime; val cacheGeneration = cache.directory.generation
        thumbnails[id] = operation
        val task = owner.launch(start = CoroutineStart.LAZY) {
            try {
                if (!current(generation) || thumbnails[id] != operation) return@launch
                val bytes = source.thumbnail(id)
                if (!current(generation) || thumbnails[id] != operation || cache.directory.generation != cacheGeneration || !isActive) return@launch
                val writer = cache.directory.beginWrite(record.address.thumbnail); thumbnailWriters[id] = writer
                try {
                    writer.write(bytes)
                    if (!current(generation) || thumbnails[id] != operation || !isActive) return@launch
                    writer.commit(MediaTransferReceipt(bytes.size.toLong())); reloadEntries()
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
        val record = record(id) ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val source = browse?.transfers ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val descriptor = record.asset.representations.firstOrNull { it.id == representation }
            ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val address = record.address.representations[representation]
            ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        if (id in transfers) throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        val operation = UUID.randomUUID(); val generation = lifetime
        val writer = cache.directory.beginWrite(address)
        mutate { it.copy(transferring = it.transferring + id,
            progress = if (descriptor.byteCount != null) it.progress + (id to 0.0) else it.progress) }
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
                val file = writer.commit(receipt); reloadEntries()
                if (id in state.value.progress) mutate { it.copy(progress = it.progress + (id to 1.0)) }
                sleep(450)
                currentCoroutineContext().ensureActive()
                if (!current(generation) || transfers[id]?.id != operation) throw MediaServiceException(MediaServiceFailure.RETIRED)
                file
            } finally { writer.abort() }
        }
        transfers[id] = Transfer(operation, writer, task); task.start()
        try { return task.await() }
        catch (error: CancellationException) { task.cancel(); throw error }
        catch (error: Exception) {
            if (current(generation) && transfers[id]?.id == operation) mutate { it.copy(note = "Could not download that clip.") }
            throw error
        }
        finally {
            if (transfers[id]?.id == operation) {
                transfers.remove(id); mutate { it.copy(transferring = it.transferring - id, progress = it.progress - id) }
            }
        }
    }
    public suspend fun cacheOriginal(id: MediaAssetID): File = cacheRepresentation(
        record(id)?.asset?.representations?.firstOrNull { it.role == MediaRepresentationRole.ORIGINAL }?.id
            ?: throw MediaServiceException(MediaServiceFailure.UNSUPPORTED), id)
    public suspend fun delete(ids: List<MediaAssetID>): List<MediaDeleteResult> {
        val browse = browse ?: throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        val source = browse.deletion ?: throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        val generation = lifetime; val results = source.delete(ids)
        currentCoroutineContext().ensureActive()
        if (!current(generation) || this.browse?.binding != browse.binding) throw MediaServiceException(MediaServiceFailure.RETIRED)
        val accepted = results.filter { it.outcome == MediaDeleteOutcome.ACCEPTED }.map { it.asset }.toSet()
        // This optimistic local change does not mutate the reported source catalog.
        mutate { it.copy(records = it.records.filterNot { record -> record.asset.id in accepted }, selectedIDs = it.selectedIDs - accepted) }
        cache.save(state.value.records); reloadEntries(); return results
    }
    public suspend fun clearCache() { retireOperations(); cache.clear(); reloadEntries() }
}
