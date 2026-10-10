package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MediaAssetID
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

public enum class MonitorMediaPictureLoadPolicy { PREVIEW_THEN_ORIGINAL, FIRST_AVAILABLE }

/** Captured one-record admission; the SDK checks it before dispatch and after native decoding. */
public class MonitorMediaPictureRequest<P> internal constructor(
    public val record: MonitorMediaRecord<P>,
    public val admission: MonitorMediaLibraryActionToken,
    public val isCurrent: () -> Boolean,
)
public class MonitorMediaPictureLoaders<P, I>(
    public val preview: (suspend (MonitorMediaPictureRequest<P>) -> I?)? = null,
    public val cached: (suspend (MonitorMediaPictureRequest<P>) -> I?)? = null,
    public val source: (suspend (MonitorMediaPictureRequest<P>) -> I?)? = null,
    public val progressive: (suspend (MonitorMediaPicturePublication<P, I>) -> I?)? = null,
)
public data class MonitorMediaPictureState<I>(
    public val picture: I? = null,
    public val loading: Boolean = false,
    public val closing: Boolean = false,
    public val presentation: UUID = UUID.randomUUID(),
    public val deleteRequestID: UUID? = null,
    public val optionsPresented: Boolean = false,
    public val helpPresented: Boolean = false,
    public val failure: String? = null,
    public val recordID: MediaAssetID? = null,
    public val deletionMessage: String? = null,
    public val variantSwitching: Boolean = false,
    public val preparingShare: Boolean = false,
    public val ratingStars: Int? = null,
    public val ratingPending: Boolean = false,
    public val ratingNotice: String? = null,
    public val status: MonitorMediaPictureStatus = MonitorMediaPictureStatus(),
)

/** Borrowed still-picture UI lifetime over the one existing source/library/cache. */
public class MonitorMediaPictureModel<P, I>(
    public val library: MonitorMediaLibraryModel<P>, record: MonitorMediaRecord<P>,
    private val scope: CoroutineScope, admission: MonitorMediaLibraryActionToken = library.actionToken,
    public val variants: List<MonitorMediaPictureVariant<P>> = emptyList(),
    private val sleep: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) },
    private val sourceCurrent: () -> Boolean = { true },
) {
    public var admission: MonitorMediaLibraryActionToken = admission
        private set
    public var deletionCompletion: MonitorMediaDeletionCompletion? = null
        private set
    public val baseRecord: MonitorMediaRecord<P> = record
    public var record: MonitorMediaRecord<P> = record
        private set
    private val mutable = MutableStateFlow(MonitorMediaPictureState<I>(recordID = record.asset.id))
    public val state: StateFlow<MonitorMediaPictureState<I>> = mutable.asStateFlow()
    private var active = false
    private var deletion: Pair<MonitorMediaPictureRequest<P>, List<MonitorMediaRecord<P>>>? = null
    private val acceptedDeletions = mutableMapOf<UUID, MonitorMediaLibraryDeletionAuthority>()
    private val tasks = mutableMapOf<UUID, Job>()
    private var loadID: UUID? = null
    private var loadRevision = UUID.randomUUID()
    private var variantRevision = UUID.randomUUID()
    private var ratingRevision = UUID.randomUUID()
    private var confirmedRating: Int? = null
    private var noticeID: UUID? = null
    public val isCurrent: Boolean get() {
        if (!active || !library.isCurrent(admission)) return false
        val available = sourceCurrent()
        return available && active && library.isCurrent(admission)
    }
    public val favorite: Boolean get() = library.record(baseRecord.asset.id)?.favorite ?: baseRecord.favorite
    public fun activate(): Unit { active = library.isCurrent(admission) && sourceCurrent() }
    public fun retire(): Unit {
        active = false; loadRevision = UUID.randomUUID(); variantRevision = UUID.randomUUID(); ratingRevision = UUID.randomUUID()
        loadID = null; noticeID = null
        acceptedDeletions.values.forEach { it.retire() }; acceptedDeletions.clear()
        deletionCompletion?.retire(); deletionCompletion = null
        tasks.values.forEach { it.cancel() }; tasks.clear(); deletion = null
        mutable.value = mutable.value.copy(loading = false, closing = false, presentation = UUID.randomUUID(), deleteRequestID = null,
            optionsPresented = false, helpPresented = false, failure = null, deletionMessage = null,
            variantSwitching = false, preparingShare = false, ratingPending = false, ratingNotice = null)
    }
    /** Return waits for entered native work to clean up while revoking new picture actions. */
    public fun close(completed: () -> Unit): Unit {
        if (mutable.value.closing) return
        val entered = tasks.values.toList()
        retire(); val origin = mutable.value.presentation; val id = UUID.randomUUID()
        mutable.value = mutable.value.copy(closing = true)
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                entered.forEach { it.join() }
                if (!isActive || active || mutable.value.presentation != origin) return@launch
                mutable.value = mutable.value.copy(closing = false); completed()
            } finally { tasks.remove(id) }
        }
        tasks[id] = job; job.start()
    }
    private suspend fun stopLoading() {
        loadRevision = UUID.randomUUID(); val revision = loadRevision; val origin = mutable.value.presentation
        val previous = loadID?.let { tasks[it] }
        loadID = null; previous?.cancel(); previous?.join()
        if (mutable.value.presentation == origin && loadRevision == revision) mutable.value = mutable.value.copy(loading = false)
    }
    /** Selecting another shot returns this picture before the next native load enters. */
    public fun navigate(id: MediaAssetID, selected: (MonitorMediaRecord<P>) -> Unit): Unit {
        if (id == baseRecord.asset.id) return
        val request = request(baseRecord, false) ?: return
        val target = library.record(id) ?: return
        if (!request.isCurrent()) return
        val generation = library.cache.directory.generation
        close {
            if (!library.isCurrent(request.admission) || library.cache.directory.generation != generation || library.record(id) == null) return@close
            val available = sourceCurrent()
            if (available && library.isCurrent(request.admission) && library.cache.directory.generation == generation && library.record(id) != null)
                selected(target)
        }
    }
    public fun sourceChanged(): Unit {
        if (isCurrent) return
        val retained = acceptedDeletions.filterValues {
            it.isPrepared && (it.isCurrent || it.isCompleting || it.completion?.isCurrent == true)
        }.keys
        if (retained.isEmpty()) { retire(); return }
        tasks.keys.toList().filterNot { it in retained }.forEach { tasks.remove(it)?.cancel() }
        loadRevision = UUID.randomUUID(); variantRevision = UUID.randomUUID(); ratingRevision = UUID.randomUUID()
        loadID = null; noticeID = null; deletion = null
        mutable.value = mutable.value.copy(loading = false, deleteRequestID = null, deletionMessage = null,
            variantSwitching = false, preparingShare = false, ratingPending = false, ratingNotice = null,
            optionsPresented = false, helpPresented = false)
    }
    public fun request(): MonitorMediaPictureRequest<P>? = request(record, true)
    public fun request(id: MediaAssetID): MonitorMediaPictureRequest<P>? = library.record(id)?.let { request(it, false) }
    private fun request(value: MonitorMediaRecord<P>, variant: Boolean): MonitorMediaPictureRequest<P>? {
        if (!isCurrent || library.record(value.asset.id) == null) return null
        val origin = mutable.value.presentation; val selected = variantRevision; val generation = library.cache.directory.generation
        val token = admission
        return MonitorMediaPictureRequest(value, token) {
            isCurrent && admission == token && mutable.value.presentation == origin && library.cache.directory.generation == generation &&
                (!variant || variantRevision == selected)
        }
    }
    public fun options(presented: Boolean): Unit {
        if (presented && !isCurrent) return
        mutable.value = mutable.value.copy(optionsPresented = presented, helpPresented = false)
    }
    public fun help(presented: Boolean): Unit { mutable.value = mutable.value.copy(helpPresented = presented) }
    public fun dismissFailure(): Unit { mutable.value = mutable.value.copy(failure = null) }
    public fun load(loaders: MonitorMediaPictureLoaders<P, I>,
        policy: MonitorMediaPictureLoadPolicy = MonitorMediaPictureLoadPolicy.PREVIEW_THEN_ORIGINAL): Unit {
        val request = request() ?: return
        loadID?.let { tasks[it]?.cancel() }
        loadRevision = UUID.randomUUID(); val revision = loadRevision
        mutable.value = mutable.value.copy(loading = true, failure = null, status = MonitorMediaPictureStatus())
        val loadRequest = MonitorMediaPictureRequest(request.record, request.admission) {
            request.isCurrent() && loadRevision == revision
        }
        val progressive: (suspend (MonitorMediaPictureRequest<P>) -> I?)? = loaders.progressive?.let { port ->
            { captured: MonitorMediaPictureRequest<P> -> port(MonitorMediaPicturePublication(captured,
                picture = { if (captured.isCurrent()) mutable.value = mutable.value.copy(picture = it) },
                status = { if (captured.isCurrent()) mutable.value = mutable.value.copy(status = it) })) }
        }
        val preview = loaders.preview
        val stages = if (policy == MonitorMediaPictureLoadPolicy.PREVIEW_THEN_ORIGINAL)
            listOf(preview to false, loaders.cached to true, progressive to true, loaders.source to true)
            else listOf(loaders.cached to true, preview to true, progressive to true, loaders.source to true)
        val id = UUID.randomUUID(); val origin = mutable.value.presentation
        loadID = id
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                for ((stage, complete) in stages) {
                    if (!isActive || !loadRequest.isCurrent()) return@launch
                    if (stage == null) continue
                    val picture = stage(loadRequest)
                    if (!isActive || !loadRequest.isCurrent()) return@launch
                    if (picture != null) {
                        mutable.value = mutable.value.copy(picture = picture)
                        if (complete) return@launch
                    }
                }
            } catch (cancel: CancellationException) { throw cancel }
            catch (error: Exception) { if (loadRequest.isCurrent()) mutable.value = mutable.value.copy(failure = error.message) }
            finally {
                if (tasks.remove(id) != null && mutable.value.presentation == origin && loadID == id) {
                    loadID = null; mutable.value = mutable.value.copy(loading = false)
                }
            }
        }
        tasks[id] = job; job.start()
    }
    public fun selectVariant(id: MediaAssetID, loaders: MonitorMediaPictureLoaders<P, I>,
        policy: MonitorMediaPictureLoadPolicy = MonitorMediaPictureLoadPolicy.PREVIEW_THEN_ORIGINAL): Unit {
        if (mutable.value.variantSwitching || id == record.asset.id) return
        val choice = variants.firstOrNull { it.id == id } ?: return
        val source = request(baseRecord, false) ?: return
        if (library.record(id) == null) return
        variantRevision = UUID.randomUUID(); val selected = variantRevision; val origin = mutable.value.presentation
        loadRevision = UUID.randomUUID(); val previous = loadID?.let { tasks[it] }
        loadID = null; previous?.cancel()
        mutable.value = mutable.value.copy(variantSwitching = true, preparingShare = false)
        val taskID = UUID.randomUUID()
        val task = scope.launch(start = CoroutineStart.LAZY) {
            try {
                previous?.join()
                if (!isActive || !source.isCurrent() || variantRevision != selected) return@launch
                record = choice.record; mutable.value = mutable.value.copy(recordID = id)
                load(loaders, policy)
            } finally {
                tasks.remove(taskID)
                if (mutable.value.presentation == origin && variantRevision == selected)
                    mutable.value = mutable.value.copy(variantSwitching = false)
            }
        }
        tasks[taskID] = task; task.start()
    }
    public fun toggleFavorite(operations: MonitorMediaGalleryOperations<P>): Unit {
        val request = request(baseRecord, false) ?: return
        if (!request.isCurrent()) return
        operations.favorite?.invoke(request.record) ?: library.toggleFavorite(baseRecord.asset.id)
    }
    public fun canDelete(operations: MonitorMediaGalleryOperations<P>): Boolean {
        if (operations.delete == null && operations.acceptedDeletion == null) return false
        val allowed = operations.access?.invoke(baseRecord)?.delete ?: (baseRecord.asset.deletable == true)
        return allowed && isCurrent
    }
    public fun requestDelete(operations: MonitorMediaGalleryOperations<P>, records: List<MonitorMediaRecord<P>>? = null): Unit {
        if (!canDelete(operations)) return
        val request = request(baseRecord, false) ?: return
        val targets = records ?: listOf(baseRecord)
        if (targets.isEmpty() || targets.any { library.record(it.asset.id) == null }) return
        val message = operations.deletionMessage?.invoke(targets)
        if (!request.isCurrent()) return
        deletion = request to targets
        mutable.value = mutable.value.copy(deleteRequestID = UUID.randomUUID(), deletionMessage = message)
    }
    public fun cancelDelete(): Unit { deletion = null; mutable.value = mutable.value.copy(deleteRequestID = null, deletionMessage = null) }
    public fun cancelDelete(admitted: UUID?): Unit { if (admitted != null && admitted == mutable.value.deleteRequestID) cancelDelete() }
    public fun confirmDelete(id: UUID?, operations: MonitorMediaGalleryOperations<P>, completed: () -> Unit): Unit {
        if (id == null || id != mutable.value.deleteRequestID) return
        val (request, records) = deletion ?: return
        cancelDelete()
        if (!request.isCurrent()) return
        val taskID = UUID.randomUUID()
        val port = operations.acceptedDeletion
        if (port != null) {
            val authority = port.capture(records) ?: return
            if (!request.isCurrent() || !authority.isCurrent) { authority.retire(); return }
            val origin = mutable.value.presentation
            acceptedDeletions[taskID] = authority
            val task = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    if (!isActive || !active || !authority.isCurrent) { authority.retire(); return@launch }
                    stopLoading()
                    if (!isActive || !active || mutable.value.presentation != origin || !authority.isCurrent) {
                        authority.retire(); return@launch
                    }
                    port.perform(records, authority)
                    if (!isActive || !active || mutable.value.presentation != origin) return@launch
                    val proof = authority.completion
                    if (proof != null) {
                        if (proof.claim != authority.id || !proof.isCurrent || !library.isCurrent(proof.admission)) return@launch
                        val available = sourceCurrent()
                        if (!available || !isActive || !active || mutable.value.presentation != origin ||
                            !proof.isCurrent || !library.isCurrent(proof.admission)) return@launch
                        admission = proof.admission; deletionCompletion = proof
                        if (proof.removedCount > 0) completed()
                    } else if (authority.isCurrent && active && mutable.value.presentation == origin) completed()
                } finally { acceptedDeletions.remove(taskID); tasks.remove(taskID) }
            }
            tasks[taskID] = task; task.start(); return
        }
        val delete = operations.delete ?: return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                if (!isActive || !request.isCurrent()) return@launch
                for (record in records) {
                    if (!isActive || !request.isCurrent()) return@launch
                    delete(record)
                }
                if (isActive && request.isCurrent()) completed()
            } catch (cancel: CancellationException) { throw cancel }
            catch (error: Exception) { if (request.isCurrent()) mutable.value = mutable.value.copy(failure = error.message) }
            finally { tasks.remove(taskID) }
        }
        tasks[taskID] = job; job.start()
    }
    public fun share(present: (MonitorMediaPictureRequest<P>) -> Unit): Unit {
        val request = request() ?: return
        if (!request.isCurrent()) return
        options(false); present(request)
    }
    public fun canShare(sharing: MonitorMediaPictureSharing<P>?): Boolean {
        val request = request() ?: return false
        val allowed = sharing?.readiness?.invoke(request) != MonitorMediaPictureShareReadiness.UNAVAILABLE
        return allowed && request.isCurrent() && !mutable.value.variantSwitching && !mutable.value.preparingShare
    }
    public fun share(present: (MonitorMediaPictureRequest<P>) -> Unit, sharing: MonitorMediaPictureSharing<P>?): Unit {
        if (sharing == null) { share(present); return }
        if (!canShare(sharing)) return
        val request = request() ?: return
        options(false); mutable.value = mutable.value.copy(preparingShare = true)
        val id = UUID.randomUUID(); val origin = mutable.value.presentation; val selected = variantRevision
        val task = scope.launch(start = CoroutineStart.LAZY) {
            try {
                while (isActive && request.isCurrent()) {
                    val readiness = sharing.readiness(request)
                    if (!request.isCurrent()) return@launch
                    when (readiness) {
                        MonitorMediaPictureShareReadiness.READY -> {
                            sharing.perform?.invoke(request)
                            if (!isActive || !request.isCurrent()) return@launch
                            present(request); return@launch
                        }
                        MonitorMediaPictureShareReadiness.UNAVAILABLE -> return@launch
                        MonitorMediaPictureShareReadiness.WAITING -> sleep(300)
                    }
                }
            } catch (cancel: CancellationException) { throw cancel }
            catch (error: Exception) {
                if (request.isCurrent()) mutable.value = mutable.value.copy(failure = error.message)
            } finally {
                tasks.remove(id)
                if (mutable.value.presentation == origin && variantRevision == selected)
                    mutable.value = mutable.value.copy(preparingShare = false)
            }
        }
        tasks[id] = task; task.start()
    }
    public fun readRating(service: MonitorMediaPictureRatingService<P>?): Unit {
        if (service == null) return
        val request = request(baseRecord, false) ?: return
        val id = UUID.randomUUID(); val revision = ratingRevision
        val task = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val value = service.read(request)
                if (!isActive || !request.isCurrent() || ratingRevision != revision) return@launch
                confirmedRating = value; mutable.value = mutable.value.copy(ratingStars = value)
            } finally { tasks.remove(id) }
        }
        tasks[id] = task; task.start()
    }
    public fun setRating(target: Int, service: MonitorMediaPictureRatingService<P>): Unit {
        if (target != 0 && target !in service.levels) return
        val request = request(baseRecord, false) ?: return
        ratingRevision = UUID.randomUUID(); val revision = ratingRevision; val id = UUID.randomUUID()
        mutable.value = mutable.value.copy(ratingStars = target, ratingPending = true)
        val task = scope.launch(start = CoroutineStart.LAZY) {
            try {
                if (!isActive || !request.isCurrent()) return@launch
                val result = service.commit(target, request)
                if (!isActive || !request.isCurrent() || ratingRevision != revision) return@launch
                when (result) {
                    is MonitorMediaPictureRatingResult.Confirmed -> {
                        confirmedRating = result.value; mutable.value = mutable.value.copy(ratingStars = result.value)
                        dismissRatingNotice()
                    }
                    is MonitorMediaPictureRatingResult.Refused -> {
                        mutable.value = mutable.value.copy(ratingStars = confirmedRating)
                        result.message?.let { showRatingNotice(it, request) }
                    }
                    MonitorMediaPictureRatingResult.Unavailable -> mutable.value = mutable.value.copy(ratingStars = confirmedRating)
                }
            } finally {
                tasks.remove(id)
                if (ratingRevision == revision) mutable.value = mutable.value.copy(ratingPending = false)
            }
        }
        tasks[id] = task; task.start()
    }
    public fun dismissRatingNotice(): Unit {
        noticeID?.let { tasks.remove(it)?.cancel() }; noticeID = null
        mutable.value = mutable.value.copy(ratingNotice = null)
    }
    private fun showRatingNotice(message: String, request: MonitorMediaPictureRequest<P>): Unit {
        dismissRatingNotice()
        if (!request.isCurrent()) return
        val id = UUID.randomUUID(); noticeID = id; mutable.value = mutable.value.copy(ratingNotice = message)
        val task = scope.launch(start = CoroutineStart.LAZY) {
            try {
                sleep(4000)
                if (!isActive || noticeID != id || !request.isCurrent()) return@launch
                noticeID = null; mutable.value = mutable.value.copy(ratingNotice = null)
            } finally { tasks.remove(id) }
        }
        tasks[id] = task; task.start()
    }
    public fun back(): Boolean {
        if (mutable.value.optionsPresented) { options(false); return true }
        if (mutable.value.deleteRequestID != null) { cancelDelete(); return true }
        return false
    }
}
