package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MediaAssetID
import com.opencapture.opencine.media.MediaRepresentationRole
import com.opencapture.opencine.media.MonitorMediaProjectionResult
import com.opencapture.opencine.media.MonitorMediaProjectionExpansionEntry
import java.lang.ref.WeakReference
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Captured deletion port; execution belongs to the existing Library operation scheduler. */
public class MonitorMediaGalleryDeletion<P>(
    public val capture: (List<MonitorMediaRecord<P>>) -> MonitorMediaLibraryDeletionAuthority?,
    public val perform: suspend (List<MonitorMediaRecord<P>>, MonitorMediaLibraryDeletionAuthority) -> Unit,
)

public data class MonitorMediaGalleryAccess(
    public val download: Boolean? = null,
    public val share: Boolean? = null,
    public val delete: Boolean? = null,
)

/** One-record SDK ports; bulk order/cancellation remains in the common catalog owner. */
public class MonitorMediaGalleryOperations<P>(
    public val download: (suspend (MonitorMediaRecord<P>) -> Unit)? = null,
    public val delete: (suspend (MonitorMediaRecord<P>) -> Unit)? = null,
    public val favorite: ((MonitorMediaRecord<P>) -> Unit)? = null,
    public val acceptedDeletion: MonitorMediaGalleryDeletion<P>? = null,
    public val access: ((MonitorMediaRecord<P>) -> MonitorMediaGalleryAccess)? = null,
    public val deletionMessage: ((List<MonitorMediaRecord<P>>) -> String?)? = null,
    public val openNotice: ((MonitorMediaRecord<P>) -> String?)? = null,
)

/** Immutable displayed window, qualified by source and presentation retirement. */
public class MonitorMediaGallerySnapshot<P> internal constructor(
    library: MonitorMediaLibraryModel<P>,
    internal val presentation: UUID,
    public val projection: MonitorMediaProjectionResult? = null,
) {
    private val owner = WeakReference(library)
    public val token: MonitorMediaLibraryActionToken = library.actionToken
    /** The supplied list this window was built from; a gallery reuses an unchanged window. */
    internal val basis: List<MonitorMediaRecord<P>> = if (projection == null) library.displayedRecords else library.state.value.records
    private val available: Map<MediaAssetID, MonitorMediaRecord<P>> = basis.associateBy { it.asset.id }
    private val selectionOrder: List<MediaAssetID> = projection?.displayIDs ?: available.keys.toList()
    /** Hash lookups for admission: a whole-card selection resolves in linear time. */
    private val admittedIDs: Set<MediaAssetID> = HashSet<MediaAssetID>(selectionOrder.size * 2).also { ids ->
        ids.addAll(selectionOrder); projection?.groups?.forEach { ids.addAll(it.members) }
    }
    public val records: List<MonitorMediaRecord<P>> = (projection?.gridIDs ?: selectionOrder).mapNotNull(available::get)
    public val isCurrent: Boolean get() = owner.get()?.isCurrent(token) == true
    public fun record(id: MediaAssetID): MonitorMediaRecord<P>? {
        if (!isCurrent || owner.get()?.record(id) == null) return null
        if (id !in admittedIDs) return null
        return available[id]
    }
    public fun selected(ids: Set<MediaAssetID>, expanded: Boolean = true): List<MonitorMediaRecord<P>> {
        if (!isCurrent) return emptyList()
        val basis = selectionOrder.filter { it in ids }
        val source = projection
        if (!expanded || source == null) return basis.mapNotNull(::record)
        return source.expansion(basis, available.keys).mapNotNull { entry ->
            if (record(entry.id) == null) null else when (entry) {
                is MonitorMediaProjectionExpansionEntry.Supplied -> record(entry.id)
                is MonitorMediaProjectionExpansionEntry.Member -> owner.get()?.record(entry.id)
            }
        }
    }
    public val selectableIDs: Set<MediaAssetID> get() = selectionOrder.filter { record(it) != null }.toSet()
}
public class MonitorMediaGalleryOpen<P>(
    public val record: MonitorMediaRecord<P>,
    public val playlist: List<MonitorMediaRecord<P>>,
    public val admission: MonitorMediaLibraryActionToken,
) { public val id: UUID = UUID.randomUUID() }
public enum class MonitorMediaDateBound { START, END }
public class MonitorMediaGalleryDateRequest internal constructor(
    public val bound: MonitorMediaDateBound,
    public val admission: MonitorMediaLibraryActionToken,
    internal val lifetime: UUID,
) { public val id: UUID = UUID.randomUUID() }
public data class MonitorMediaGalleryState(
    public val presentationRevision: Long = 0,
    public val filterPopupPresented: Boolean = false,
    public val filterRequestID: UUID? = null,
    public val pickingDate: MonitorMediaGalleryDateRequest? = null,
    public val deleteCount: Int = 0,
    public val confirmationPresented: Boolean = false,
    public val deleteRequestID: UUID? = null,
    public val resolvedDurations: Map<MediaAssetID, String> = emptyMap(),
    public val failure: String? = null,
    public val deletionMessage: String? = null,
    public val notice: String? = null,
)

/** Presentation/actions over the existing library/cache/source; no source or storage owner. */
public class MonitorMediaGalleryModel<P>(public val library: MonitorMediaLibraryModel<P>, private val scope: CoroutineScope,
    private val sleep: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) }) {
    private val mutable = MutableStateFlow(MonitorMediaGalleryState())
    public val state: StateFlow<MonitorMediaGalleryState> = mutable.asStateFlow()
    private var lifetime = UUID.randomUUID()
    private var active = true
    private data class Deletion<P>(val snapshot: MonitorMediaGallerySnapshot<P>, val records: List<MonitorMediaRecord<P>>,
        val operations: MonitorMediaGalleryOperations<P>, val origin: UUID)
    private var deletion: Deletion<P>? = null
    private val tasks = mutableMapOf<UUID, Job>()
    private var noticeID = UUID.randomUUID()
    private var noticeJob: Job? = null
    private val acceptedDeletions = mutableMapOf<UUID, MonitorMediaLibraryDeletionAuthority>()
    private var snapshotMemo: MonitorMediaGallerySnapshot<P>? = null
    /** One window per actual change: a recomposition with the same inputs reuses it. */
    public fun snapshot(projection: MonitorMediaProjectionResult? = null): MonitorMediaGallerySnapshot<P> {
        val basis = if (projection == null) library.displayedRecords else library.state.value.records
        snapshotMemo?.let { memo ->
            if (memo.presentation == lifetime && memo.projection === projection && memo.basis === basis &&
                memo.token == library.actionToken) return memo
        }
        return MonitorMediaGallerySnapshot(library, lifetime, projection).also { snapshotMemo = it }
    }
    public fun activate(): Unit { active = true }
    public fun retire(): Unit {
        active = false; lifetime = UUID.randomUUID(); dismissNotice()
        acceptedDeletions.values.forEach { it.retire() }; acceptedDeletions.clear()
        tasks.values.forEach { it.cancel() }; tasks.clear(); deletion = null
        mutable.value = MonitorMediaGalleryState(presentationRevision = mutable.value.presentationRevision + 1)
    }
    /** The operator closes the browser: the next visit starts without a selection, as covers keep it. */
    public fun leave(): Unit { library.clearSelection(); retire() }
    public fun sourceChanged(): Unit {
        val retained = acceptedDeletions.filterValues { it.isPrepared && it.isCurrent }.keys.toSet()
        if (retained.isEmpty()) { retire(); activate(); return }
        tasks.keys.toList().filterNot { it in retained }.forEach { tasks.remove(it)?.cancel() }
        acceptedDeletions.keys.toList().filterNot { it in retained }.forEach { acceptedDeletions.remove(it)?.retire() }
        deletion = null; dismissNotice()
        mutable.value = MonitorMediaGalleryState(presentationRevision = mutable.value.presentationRevision + 1)
    }
    public fun isCurrent(snapshot: MonitorMediaGallerySnapshot<P>): Boolean =
        active && snapshot.presentation == lifetime && snapshot.isCurrent && library.isCurrent(snapshot.token)
    public fun filterPopup(presented: Boolean): Unit {
        val old = mutable.value
        if (old.filterPopupPresented == presented) return
        mutable.value = old.copy(filterPopupPresented = presented, filterRequestID = if (presented) UUID.randomUUID() else null,
            pickingDate = if (presented) old.pickingDate else null)
    }
    public fun admitsFilter(snapshot: MonitorMediaGallerySnapshot<P>, admitted: UUID?): Boolean =
        admitted != null && admitted == state.value.filterRequestID && state.value.filterPopupPresented && isCurrent(snapshot)
    public fun dismissFilter(admitted: UUID?): Unit {
        if (admitted != null && admitted == state.value.filterRequestID) filterPopup(false)
    }
    public fun dismissFailure(): Unit { mutable.value = mutable.value.copy(failure = null) }
    public fun duration(label: String, id: MediaAssetID, admitted: MonitorMediaGallerySnapshot<P>): Unit {
        if (!isCurrent(admitted) || admitted.record(id) == null) return
        mutable.value = mutable.value.copy(resolvedDurations = mutable.value.resolvedDurations + (id to label))
    }
    public fun canDownload(record: MonitorMediaRecord<P>, operations: MonitorMediaGalleryOperations<P>): Boolean {
        if (operations.download == null) return false
        operations.access?.invoke(record)?.download?.let { return it }
        return library.state.value.entries[record.asset.id]?.original == null &&
            record.asset.representations.any { it.role == MediaRepresentationRole.ORIGINAL }
    }
    public fun canShare(record: MonitorMediaRecord<P>, operations: MonitorMediaGalleryOperations<P>): Boolean {
        operations.access?.invoke(record)?.share?.let { return it }
        return library.state.value.entries[record.asset.id]?.original != null || (operations.download != null &&
            record.asset.representations.any { it.role == MediaRepresentationRole.ORIGINAL })
    }
    public fun canDelete(record: MonitorMediaRecord<P>, operations: MonitorMediaGalleryOperations<P>): Boolean {
        if (operations.delete == null && operations.acceptedDeletion == null) return false
        return operations.access?.invoke(record)?.delete ?: (record.asset.deletable == true)
    }
    public fun dismissNotice(): Unit {
        noticeID = UUID.randomUUID(); noticeJob?.cancel(); noticeJob = null
        mutable.value = mutable.value.copy(notice = null)
    }
    private fun showNotice(message: String, admitted: MonitorMediaGallerySnapshot<P>) {
        dismissNotice()
        if (!isCurrent(admitted)) return
        val id = noticeID
        mutable.value = mutable.value.copy(notice = message)
        noticeJob = scope.launch {
            sleep(2600)
            if (!isActive || noticeID != id || !isCurrent(admitted)) return@launch
            noticeJob = null; mutable.value = mutable.value.copy(notice = null)
        }
    }
    /** True only when selection begins, for the original selection feedback. */
    public fun select(ids: Set<MediaAssetID>, admitted: MonitorMediaGallerySnapshot<P>, selecting: Boolean = true): Boolean {
        if (!isCurrent(admitted) || ids.any { admitted.record(it) == null }) return false
        val began = !library.state.value.selecting && selecting
        library.select(ids, selecting)
        return began
    }
    public fun toggleSelection(id: MediaAssetID, admitted: MonitorMediaGallerySnapshot<P>): Boolean {
        if (!isCurrent(admitted) || admitted.record(id) == null) return false
        val selected = library.state.value.selectedIDs
        return select(if (id in selected) selected - id else selected + id, admitted)
    }
    public fun retainSelection(admitted: MonitorMediaGallerySnapshot<P>): Unit {
        if (!isCurrent(admitted)) return
        val old = library.state.value
        val retained = old.selectedIDs.intersect(admitted.selectableIDs)
        if (retained != old.selectedIDs || retained.isEmpty() && old.selecting) library.select(retained, retained.isNotEmpty())
    }
    public fun open(id: MediaAssetID, admitted: MonitorMediaGallerySnapshot<P>,
        operations: MonitorMediaGalleryOperations<P>, sourceAvailable: Boolean = false): MonitorMediaGalleryOpen<P>? {
        if (!isCurrent(admitted)) return null
        val record = admitted.record(id) ?: return null
        if (library.state.value.selecting) { toggleSelection(id, admitted); return null }
        operations.openNotice?.invoke(record)?.let { showNotice(it, admitted); return null }
        if (!isCurrent(admitted) || record.facts.playbackEligible == false) return null
        val kind = record.facts.presentationKind ?: record.asset.kind ?: return null
        if (!sourceAvailable && operations.download == null && library.state.value.entries[id]?.isPlayableOffline != true) return null
        return MonitorMediaGalleryOpen(record, admitted.records.filter {
            (it.facts.presentationKind ?: it.asset.kind) == kind && it.facts.playbackEligible != false
        }, admitted.token)
    }
    public fun shareSelection(admitted: MonitorMediaGallerySnapshot<P>, operations: MonitorMediaGalleryOperations<P>): List<MonitorMediaRecord<P>>? {
        val records = selected(admitted)
        return records.takeIf { it.isNotEmpty() && it.all { record -> canShare(record, operations) } && isCurrent(admitted) }
    }
    public fun favorite(id: MediaAssetID, admitted: MonitorMediaGallerySnapshot<P>, operations: MonitorMediaGalleryOperations<P>): Unit {
        if (!isCurrent(admitted)) return
        val record = admitted.record(id) ?: return
        val favorite = operations.favorite
        if (favorite != null) favorite(record) else library.toggleFavorite(id)
    }
    public fun favoriteSelection(admitted: MonitorMediaGallerySnapshot<P>, operations: MonitorMediaGalleryOperations<P>,
        toggleUniform: Boolean = false): Unit {
        val records = selected(admitted, expanded = false)
        val target = !toggleUniform || records.any { library.record(it.asset.id)?.favorite == false }
        records.filter { library.record(it.asset.id)?.favorite != target }.forEach { favorite(it.asset.id, admitted, operations) }
    }
    public fun cacheSelection(admitted: MonitorMediaGallerySnapshot<P>, operations: MonitorMediaGalleryOperations<P>): Unit {
        val download = operations.download ?: return
        perform(selected(admitted).filter { canDownload(it, operations) }, admitted, false, download)
    }
    public fun requestDelete(admitted: MonitorMediaGallerySnapshot<P>, operations: MonitorMediaGalleryOperations<P>,
        supportedSubset: Boolean = false): Unit {
        val selected = selected(admitted)
        val records = if (supportedSubset) selected.filter { canDelete(it, operations) } else selected
        if (records.isEmpty() || records.any { !canDelete(it, operations) }) return
        if (!isCurrent(admitted)) return
        val message = operations.deletionMessage?.invoke(records)
        if (!isCurrent(admitted)) return
        deletion = Deletion(admitted, records, operations, lifetime)
        mutable.value = mutable.value.copy(deleteCount = records.size, confirmationPresented = true,
            deleteRequestID = UUID.randomUUID(), deletionMessage = message)
    }
    public fun cancelDelete(): Unit {
        deletion = null
        mutable.value = mutable.value.copy(deleteCount = 0, confirmationPresented = false, deleteRequestID = null, deletionMessage = null)
    }
    public fun cancelDelete(admitted: UUID?): Unit {
        if (admitted != null && admitted == state.value.deleteRequestID) cancelDelete()
    }
    public fun confirmDelete(admitted: UUID?): Unit {
        if (admitted == null || admitted != mutable.value.deleteRequestID) return
        val captured = deletion; cancelDelete()
        if (captured == null || captured.origin != lifetime || !isCurrent(captured.snapshot)) return
        val port = captured.operations.acceptedDeletion
        if (port != null) {
            val authority = port.capture(captured.records) ?: return
            if (!isCurrent(captured.snapshot) || !authority.isCurrent) { authority.retire(); return }
            authority.clearsSelection = true
            val id = UUID.randomUUID()
            acceptedDeletions[id] = authority
            val task = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    if (!active || !authority.isCurrent) { authority.retire(); return@launch }
                    port.perform(captured.records, authority)
                } finally { acceptedDeletions.remove(id); tasks.remove(id) }
            }
            tasks[id] = task; task.start()
            return
        }
        val delete = captured.operations.delete ?: return
        perform(captured.records, captured.snapshot, true, delete)
    }
    public fun pickDate(bound: MonitorMediaDateBound, admitted: MonitorMediaGallerySnapshot<P>): Unit {
        if (!isCurrent(admitted)) return
        mutable.value = mutable.value.copy(pickingDate = MonitorMediaGalleryDateRequest(bound, admitted.token, lifetime))
    }
    public fun cancelDate(): Unit { mutable.value = mutable.value.copy(pickingDate = null) }
    public fun cancelDate(admitted: UUID?): Unit {
        if (admitted != null && admitted == state.value.pickingDate?.id) cancelDate()
    }
    public fun date(key: String?, admitted: MonitorMediaGalleryDateRequest): Unit {
        if (!active || mutable.value.pickingDate?.id != admitted.id || lifetime != admitted.lifetime || !library.isCurrent(admitted.admission)) return
        val value = library.state.value
        if (admitted.bound == MonitorMediaDateBound.START) library.filter(dateStart = key,
            dateEnd = if (key != null && value.dateEnd != null && key > value.dateEnd) key else value.dateEnd)
        else library.filter(dateEnd = key,
            dateStart = if (key != null && value.dateStart != null && key < value.dateStart) key else value.dateStart)
    }
    public fun selectAll(admitted: MonitorMediaGallerySnapshot<P>): Unit {
        if (isCurrent(admitted)) library.select(admitted.selectableIDs)
    }
    public fun selected(snapshot: MonitorMediaGallerySnapshot<P>, expanded: Boolean = true): List<MonitorMediaRecord<P>> {
        if (!isCurrent(snapshot)) return emptyList()
        return snapshot.selected(library.state.value.selectedIDs, expanded)
    }
    private fun perform(records: List<MonitorMediaRecord<P>>, snapshot: MonitorMediaGallerySnapshot<P>,
        clearSelection: Boolean, operation: suspend (MonitorMediaRecord<P>) -> Unit): Unit {
        if (records.isEmpty() || !isCurrent(snapshot)) return
        val id = UUID.randomUUID(); val origin = lifetime
        val task = scope.launch(start = CoroutineStart.LAZY) {
            try {
                for (record in records) {
                    if (!isActive || lifetime != origin || !isCurrent(snapshot) || snapshot.record(record.asset.id) == null) return@launch
                    try { operation(record) }
                    catch (failure: Exception) {
                        // A record's operation cancelled by its source is that record's failure;
                        // only this batch's own cancellation ends the batch.
                        if (failure is CancellationException) currentCoroutineContext().ensureActive()
                        if (isActive && lifetime == origin && isCurrent(snapshot))
                            mutable.value = mutable.value.copy(failure = if (clearSelection)
                                "Could not delete that clip." else "Could not cache that clip.")
                    }
                }
                if (isActive && lifetime == origin && isCurrent(snapshot) && clearSelection) library.clearSelection()
            } finally { tasks.remove(id) }
        }
        tasks[id] = task; task.start()
    }
}
