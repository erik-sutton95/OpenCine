package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.media.CameraMediaService
import com.opencapture.opencine.media.MediaAssetID
import com.opencapture.opencine.media.MonitorPlaybackDeletionConfirmation
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.MonitorPlaybackStartTiming
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Bounded source IO; order and presentation admission stay with the common player. */
public class MonitorOperatorPlaybackOperations<P, L>(
    public val cacheOriginal: (suspend (MonitorMediaRecord<P>) -> Unit)? = null,
    public val delete: (suspend (MonitorMediaRecord<P>) -> Boolean)? = null,
    public val favorite: ((MonitorMediaRecord<P>) -> Unit)? = null,
    public val adoptLook: ((MonitorMediaRecord<P>, MonitorPlaybackLook<L>) -> Unit)? = null,
    public val access: ((MonitorMediaRecord<P>) -> MonitorMediaGalleryAccess)? = null,
    public val rating: MonitorMediaPlaybackRatingService<P>? = null,
) {
    /** The legacy six-parameter/default constructor remains unchanged. */
    public var captureDeletion: ((MonitorMediaRecord<P>) -> MonitorOperatorPlaybackDeletionRequest?)? = null
        private set
    public constructor(captureDeletion: (MonitorMediaRecord<P>) -> MonitorOperatorPlaybackDeletionRequest?,
        cacheOriginal: (suspend (MonitorMediaRecord<P>) -> Unit)? = null,
        delete: (suspend (MonitorMediaRecord<P>) -> Boolean)? = null,
        favorite: ((MonitorMediaRecord<P>) -> Unit)? = null,
        adoptLook: ((MonitorMediaRecord<P>, MonitorPlaybackLook<L>) -> Unit)? = null,
        access: ((MonitorMediaRecord<P>) -> MonitorMediaGalleryAccess)? = null,
        rating: MonitorMediaPlaybackRatingService<P>? = null,
    ) : this(cacheOriginal, delete, favorite, adoptLook, access, rating) {
        this.captureDeletion = captureDeletion
    }
}

/** A genuine removal may retire exactly the outgoing item once, never its successor. */
public object MonitorPlaybackRemovalAdmission {
    public fun accepts(removed: MediaAssetID?, captured: MediaAssetID,
        token: MonitorPlaybackItemToken, current: MonitorPlaybackItemToken, active: MediaAssetID?, closed: Boolean,
        sameComposition: Boolean, sameGallery: Boolean, sameContent: Boolean): Boolean =
        removed == captured && sameComposition && sameGallery && sameContent && active == captured &&
            (current == token || (closed && current == token.copy(revision = token.revision + 1)))
}

/** Owns gallery binding and its player while the shell keeps one camera owner. */
public class MonitorOperatorMediaModel<P, L>(
    public val library: MonitorMediaLibraryModel<P>,
    private val scope: CoroutineScope?,
    private val recordAdmission: ((MonitorMediaRecord<P>) -> MonitorPlaybackAdmission)? = null,
    private val sleep: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) },
    private val makeAdmittedPlayback: (MonitorMediaLibraryModel<P>, MonitorPlaybackAdmission) -> MonitorMediaPlaybackModel<P, L>?,
) {
    public constructor(library: MonitorMediaLibraryModel<P>,
        makePlayback: (MonitorMediaLibraryModel<P>) -> MonitorMediaPlaybackModel<P, L>) :
        this(library, null, null, { kotlinx.coroutines.delay(it) }, { owner, _ -> makePlayback(owner) })
    public constructor(library: MonitorMediaLibraryModel<P>, scope: CoroutineScope?,
        recordAdmission: ((MonitorMediaRecord<P>) -> MonitorPlaybackAdmission)? = null,
        sleep: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) },
        makePlayback: (MonitorMediaLibraryModel<P>) -> MonitorMediaPlaybackModel<P, L>) :
        this(library, scope, recordAdmission, sleep, { owner, _ -> makePlayback(owner) })

    public data class State<P, L>(
        public val galleryOpen: Boolean = false,
        public val playback: MonitorMediaPlaybackModel<P, L>? = null,
        public val playerVisible: Boolean = false,
        public val deliveryPresented: Boolean = false,
        public val ratingStars: Int? = null,
        public val ratingPending: Boolean = false,
        public val ratingNotice: String? = null,
        public val ratingShadeOpen: Boolean = false,
    )
    private val mutable = MutableStateFlow(State<P, L>())
    public val state: StateFlow<State<P, L>> = mutable.asStateFlow()
    private var source: CameraSessionID? = null
    private var bound = false
    private var page = UUID.randomUUID()
    private var transition = UUID.randomUUID()
    private var sceneActive = true
    private var cacheRequest: MonitorPlaybackItemToken? = null
    /**
     * Full-resolution downloads started by playback (Full Resolution Caching), keyed by clip. They
     * run for the library's lifetime, not one player page: closing the player or moving to the
     * next clip keeps the download running, so the clip reads as cached afterwards. Closing the
     * gallery this model opened, or the library retiring its source, stops them.
     */
    private val originalTasks = mutableMapOf<MediaAssetID, Job>()
    private class CapturedDeletion<P, L>(val request: MonitorOperatorPlaybackDeletionRequest,
        val record: MonitorMediaRecord<P>, val owner: MonitorMediaPlaybackModel<P, L>,
        val token: MonitorPlaybackItemToken, val page: UUID, val generation: Long,
        val source: MonitorMediaLibraryActionToken,
        val survivors: List<MonitorMediaRecord<P>>, val successor: MediaAssetID?)
    private var deletionRevision = UUID.randomUUID()
    private var pendingDeletion: CapturedDeletion<P, L>? = null
    private var enteredDeletion: MonitorOperatorPlaybackDeletionRequest? = null
    private var deleteTask: Job? = null
    private var adoptedLook: UUID? = null
    private var ratingRead: MonitorPlaybackItemToken? = null
    private var ratingRevision = UUID.randomUUID()
    private var confirmedRating: Int? = null
    private val ratingTasks = mutableMapOf<UUID, Job>()
    private var ratingNoticeID: UUID? = null

    public fun bind(camera: ConnectedCamera?): Unit {
        val next = camera?.session?.id
        if (bound && source == next) return
        if (!retireGallery()) return
        bound = true; source = next
        library.bind(camera?.services?.get<CameraMediaService>())
    }

    public fun showGallery(): Unit {
        if (state.value.galleryOpen) return
        transition = UUID.randomUUID(); val captured = transition
        mutable.value = state.value.copy(galleryOpen = true)
        if (transition != captured || !state.value.galleryOpen) return
        library.begin()
    }

    public fun closeGallery(): Unit {
        retireGallery()
    }
    private fun retireGallery(): Boolean {
        if (!retirePlayback()) return false
        val captured = transition
        val originals = originalTasks.values.toList(); originalTasks.clear()
        originals.forEach { it.cancel() }
        if (transition != captured || state.value.playback != null) return false
        if (!state.value.galleryOpen) return true
        mutable.value = state.value.copy(galleryOpen = false)
        if (transition != captured || state.value.galleryOpen) return false
        library.close()
        return transition == captured && !state.value.galleryOpen
    }

    public fun open(id: MediaAssetID, admitted: MonitorMediaLibraryActionToken): Boolean {
        if (!state.value.galleryOpen || !library.isCurrent(admitted)) return false
        val record = library.displayedRecords.firstOrNull { it.asset.id == id } ?: return false
        return open(record, library.displayedRecords, admitted)
    }

    /** Borrows an already-open gallery; it never starts or closes that gallery. */
    public fun open(record: MonitorMediaRecord<P>, playlist: List<MonitorMediaRecord<P>>,
        admitted: MonitorMediaLibraryActionToken): Boolean {
        if (record.facts.playbackEligible == false) return false
        val capturedPage = page
        transition = UUID.randomUUID(); val request = transition
        if (!library.isCurrent(admitted)) return false
        val source = recordAdmission?.invoke(record)
        if (transition != request || page != capturedPage || !library.isCurrent(admitted)) return false
        val acceptsRecord = source?.isCurrent?.invoke() ?: (library.record(record.asset.id) != null)
        if (!acceptsRecord || transition != request || page != capturedPage || !library.isCurrent(admitted)) return false
        if (state.value.playback?.state?.value?.closed != false) {
            val muted = state.value.playback?.state?.value?.muted ?: false
            val looping = state.value.playback?.state?.value?.looping ?: false
            val admission = MonitorPlaybackAdmission {
                transition == request && page == capturedPage && library.isCurrent(admitted)
            }
            val next = makeAdmittedPlayback(library, admission) ?: return false
            if (transition != request || page != capturedPage || !library.isCurrent(admitted)) {
                if (state.value.playback !== next) next.close(); return false
            }
            val initial = next.state.value.token
            mutable.value = state.value.copy(playback = next)
            if (transition != request || page != capturedPage || state.value.playback !== next) {
                if (state.value.playback !== next) next.close(); return false
            }
            if (next.state.value.token != initial) return false
            next.setMuted(muted)
            if (transition != request || page != capturedPage || state.value.playback !== next || next.state.value.token != initial) return false
            next.setLooping(looping)
        }
        val owner = state.value.playback ?: return false
        if (transition != request || page != capturedPage) return false
        if (owner.state.value.active?.asset?.id != record.asset.id || owner.state.value.closed) {
            retireWork()
            if (transition != request || page != capturedPage || state.value.playback !== owner) return false
            owner.load(record, playlist.filter { it.facts.playbackEligible != false })
        }
        if (transition != request || page != capturedPage || state.value.playback !== owner || owner.state.value.closed ||
            owner.state.value.active?.asset?.id != record.asset.id) return false
        owner.setSceneActive(sceneActive)
        if (transition != request || page != capturedPage || state.value.playback !== owner) return false
        owner.setPresentationActive(state.value.playerVisible && !state.value.deliveryPresented)
        return transition == request && page == capturedPage && state.value.playback === owner && owner.state.value.active?.asset?.id == record.asset.id
    }

    public fun playerVisible(value: Boolean): Unit {
        val capturedPage = page; val owner = state.value.playback
        mutable.value = state.value.copy(playerVisible = value)
        if (page == capturedPage && state.value.playback === owner) owner?.setPresentationActive(value && !state.value.deliveryPresented)
    }
    public fun sceneActive(value: Boolean): Unit { sceneActive = value; state.value.playback?.setSceneActive(value) }
    /**
     * The shared share entry for the playing item (A4-11): the transport pauses before the
     * delivery sheet covers it, and dismissing the sheet leaves it paused.
     */
    public fun beginShare(token: MonitorPlaybackItemToken): Boolean {
        val owner = state.value.playback
        if (owner == null || !isCurrent(token)) return false
        owner.setPlaying(false)
        if (!isCurrent(token)) return false
        deliveryPresented(true)
        return isCurrent(token)
    }
    public fun deliveryPresented(value: Boolean): Unit {
        val capturedPage = page; val owner = state.value.playback
        mutable.value = state.value.copy(deliveryPresented = value)
        if (page == capturedPage && state.value.playback === owner) owner?.setPresentationActive(state.value.playerVisible && !value)
    }
    public fun isCurrent(token: MonitorPlaybackItemToken): Boolean {
        val owner = state.value.playback ?: return false
        if (owner.state.value.token != token || owner.state.value.closed) return false
        val capturedPage = page; val admitted = owner.isActive
        return admitted && page == capturedPage && state.value.playback === owner && owner.state.value.token == token && !owner.state.value.closed
    }
    public fun adjacent(offset: Int, admitted: MonitorPlaybackItemToken): Boolean {
        if (!isCurrent(admitted)) return false
        val owner = state.value.playback ?: return false
        val active = owner.state.value.active ?: return false
        val playlist = owner.state.value.playlist
        val index = playlist.indexOfFirst { it.asset.id == active.asset.id }
        val target = playlist.getOrNull(index + offset) ?: return false
        return open(target, playlist, library.actionToken)
    }
    public fun synchronizePlayback(cacheOriginal: Boolean, operations: MonitorOperatorPlaybackOperations<P, L>,
        cacheTiming: MonitorPlaybackStartTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_READINESS): Unit {
        val owner = state.value.playback ?: return
        val record = owner.state.value.active ?: return
        if (!isCurrent(owner.state.value.token)) return
        val token = owner.state.value.token; val capturedPage = page
        readRating(operations.rating)
        if (page != capturedPage || state.value.playback !== owner || !isCurrent(token)) return
        val mayDownload = operations.access?.invoke(record)?.download == true || operations.access == null
        if (page != capturedPage || state.value.playback !== owner || !isCurrent(token)) return
        owner.state.value.look?.let { look ->
            val resolution = owner.state.value.lookResolution
            if (resolution != null && adoptedLook != resolution && operations.adoptLook != null) {
                adoptedLook = resolution; operations.adoptLook.invoke(record, look)
            }
            if (page != capturedPage || state.value.playback !== owner || !isCurrent(token)) return
        }
        val cache = operations.cacheOriginal ?: return
        val mayCache = if (cacheTiming == MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION)
            owner.state.value.nativeItemInstalled else owner.state.value.ready
        val id = record.asset.id
        if (!cacheOriginal || !mayDownload || !mayCache || cacheRequest == token ||
            library.state.value.entries[id]?.original != null) return
        cacheRequest = token
        if (originalTasks[id]?.isActive == true) return
        val source = library.actionToken; val generation = library.cache.directory.generation
        // The library's lifetime, not the page's: an app may build this model per player page.
        val job = library.lifetimeScope.launch(start = CoroutineStart.LAZY) {
            val self = coroutineContext[Job]
            try {
                if (!library.isCurrent(source) || library.cache.directory.generation != generation || !isActive) return@launch
                try { cache(record) }
                catch (error: CancellationException) { throw error }
                // The library reports a failed download in its own note; the clip stays as it was.
                catch (_: Exception) { return@launch }
                if (page != capturedPage || state.value.playback !== owner || !isCurrent(token) ||
                    !library.isCurrent(source) || library.cache.directory.generation != generation || !isActive) return@launch
                owner.refreshTransfer()
            } finally { if (originalTasks[id] === self) originalTasks.remove(id) }
        }
        originalTasks[id] = job; job.start()
    }
    private fun ratingRequest(): MonitorMediaPlaybackRatingRequest<P>? {
        val owner = state.value.playback ?: return null
        val record = owner.state.value.active ?: return null
        val token = owner.state.value.token
        if (!isCurrent(token)) return null
        val capturedPage = page; val sourceToken = library.actionToken
        val generation = library.cache.directory.generation
        val source = recordAdmission?.invoke(record)
        if (page != capturedPage || state.value.playback !== owner || !isCurrent(token) ||
            !library.isCurrent(sourceToken) || library.cache.directory.generation != generation) return null
        val admission = MonitorPlaybackAdmission {
            if (page != capturedPage || state.value.playback !== owner || !isCurrent(token) ||
                !library.isCurrent(sourceToken) || library.cache.directory.generation != generation) false
            else {
                val current = source?.isCurrent?.invoke() ?: (library.record(record.asset.id) != null)
                current && page == capturedPage && state.value.playback === owner && isCurrent(token) &&
                    library.isCurrent(sourceToken) && library.cache.directory.generation == generation
            }
        }
        if (!admission.isCurrent()) return null
        return MonitorMediaPlaybackRatingRequest(record, token, admission)
    }
    public fun ratingShadeOpen(value: Boolean): Unit {
        mutable.value = state.value.copy(ratingShadeOpen = value)
    }
    public fun readRating(service: MonitorMediaPlaybackRatingService<P>?): Unit {
        val revision = ratingRevision
        if (service == null) return
        val request = ratingRequest() ?: return
        if (ratingRevision != revision || ratingRead == request.item) return
        val scheduler = requireNotNull(scope) { "Playback rating requires its presentation coroutine scope" }
        ratingRead = request.item
        val id = UUID.randomUUID()
        val job = scheduler.launch(start = CoroutineStart.LAZY) {
            try {
                if (!isActive || !admitsRating(revision, request)) return@launch
                val value = service.read(request)
                if (!isActive || !admitsRating(revision, request)) return@launch
                confirmedRating = value; mutable.value = state.value.copy(ratingStars = value)
            } finally { ratingTasks.remove(id) }
        }
        ratingTasks[id] = job; job.start()
    }
    public fun setRating(target: Int, service: MonitorMediaPlaybackRatingService<P>): Unit {
        val previousRevision = ratingRevision
        if (target != 0 && target !in service.levels) return
        val request = ratingRequest() ?: return
        if (ratingRevision != previousRevision) return
        val scheduler = requireNotNull(scope) { "Playback rating requires its presentation coroutine scope" }
        ratingRevision = UUID.randomUUID(); val revision = ratingRevision; val id = UUID.randomUUID()
        mutable.value = state.value.copy(ratingStars = target, ratingPending = true)
        if (!admitsRating(revision, request)) return
        val job = scheduler.launch(start = CoroutineStart.LAZY) {
            try {
                if (!isActive || !admitsRating(revision, request)) return@launch
                val result = service.commit(target, request)
                if (!isActive || !admitsRating(revision, request)) return@launch
                when (result) {
                    is MonitorMediaPictureRatingResult.Confirmed -> {
                        confirmedRating = result.value; mutable.value = state.value.copy(ratingStars = result.value)
                        if (admitsRating(revision, request)) dismissRatingNotice()
                    }
                    is MonitorMediaPictureRatingResult.Refused -> {
                        mutable.value = state.value.copy(ratingStars = confirmedRating)
                        if (admitsRating(revision, request) && result.message != null)
                            showRatingNotice(result.message, request, revision, service.noticeMilliseconds)
                    }
                    MonitorMediaPictureRatingResult.Unavailable -> {
                        mutable.value = state.value.copy(ratingStars = confirmedRating)
                        if (admitsRating(revision, request) && service.unavailableMessage != null)
                            showRatingNotice(service.unavailableMessage, request, revision, service.noticeMilliseconds)
                    }
                }
            } finally {
                ratingTasks.remove(id)
                if (ratingRevision == revision) mutable.value = state.value.copy(ratingPending = false)
            }
        }
        ratingTasks[id] = job; job.start()
    }
    public fun dismissRatingNotice(): Unit {
        val revision = ratingRevision
        val previous = ratingNoticeID?.let(ratingTasks::remove)
        ratingNoticeID = null; previous?.cancel()
        if (ratingRevision != revision || ratingNoticeID != null) return
        mutable.value = state.value.copy(ratingNotice = null)
    }
    private fun showRatingNotice(message: String, request: MonitorMediaPlaybackRatingRequest<P>,
        revision: UUID, duration: Long): Unit {
        if (!admitsRating(revision, request)) return
        dismissRatingNotice()
        if (!admitsRating(revision, request)) return
        val scheduler = requireNotNull(scope) { "Playback rating requires its presentation coroutine scope" }
        val id = UUID.randomUUID(); ratingNoticeID = id
        mutable.value = state.value.copy(ratingNotice = message)
        if (ratingNoticeID != id || !admitsRating(revision, request) || ratingNoticeID != id) return
        val job = scheduler.launch(start = CoroutineStart.LAZY) {
            try {
                sleep(duration)
                if (!isActive || ratingNoticeID != id || !admitsRating(revision, request) || ratingNoticeID != id) return@launch
                ratingNoticeID = null; mutable.value = state.value.copy(ratingNotice = null)
            } finally { ratingTasks.remove(id) }
        }
        ratingTasks[id] = job; job.start()
    }
    private fun admitsRating(revision: UUID, request: MonitorMediaPlaybackRatingRequest<P>): Boolean {
        if (ratingRevision != revision) return false
        val current = request.isCurrent
        return current && ratingRevision == revision
    }
    /** Captures displayed consequences/admission without entering source IO. */
    public fun captureDeletion(admitted: MonitorPlaybackItemToken,
        operations: MonitorOperatorPlaybackOperations<P, L>): MonitorPlaybackDeletionConfirmation? {
        if (enteredDeletion != null || !isCurrent(admitted)) return null
        val owner = state.value.playback ?: return null
        val record = owner.state.value.active ?: return null
        val capture = operations.captureDeletion ?: return null
        val capturedPage = page; val generation = library.cache.directory.generation; val source = library.actionToken
        if (operations.access != null) {
            if (operations.access.invoke(record).delete != true) return null
        } else if (record.asset.deletable != true) return null
        if (page != capturedPage || state.value.playback !== owner || !isCurrent(admitted)) return null
        cancelPendingDeletion()
        val revision = deletionRevision
        val request = capture(record) ?: return null
        if (deletionRevision != revision || page != capturedPage || state.value.playback !== owner || !isCurrent(admitted) ||
            !library.isCurrent(source) || library.cache.directory.generation != generation || !request.authority.isCurrent ||
            request.authority.directory !== library.cache.directory || deletionRevision != revision || !library.isCurrent(source) || page != capturedPage ||
            state.value.playback !== owner || !isCurrent(admitted) || library.cache.directory.generation != generation) {
            request.authority.retire(); return null
        }
        val index = owner.state.value.playlist.indexOfFirst { it.asset.id == record.asset.id }.coerceAtLeast(0)
        val survivors = owner.state.value.playlist.filter { it.asset.id != record.asset.id }
        pendingDeletion = CapturedDeletion(request, record, owner, admitted, capturedPage, generation, source,
            survivors, survivors.getOrNull(index.coerceAtMost(survivors.size - 1))?.asset?.id)
        return request.confirmation
    }
    public fun isDeletionCurrent(admitted: UUID): Boolean {
        val captured = pendingDeletion?.takeIf { it.request.confirmation.id == admitted } ?: return false
        if (page != captured.page || state.value.playback !== captured.owner || !isCurrent(captured.token) ||
            library.cache.directory.generation != captured.generation || !captured.request.authority.isCurrent) return false
        return pendingDeletion?.request?.confirmation?.id == admitted && page == captured.page &&
            state.value.playback === captured.owner && isCurrent(captured.token) &&
            library.cache.directory.generation == captured.generation
    }
    /** Cancel revokes only the displayed request and performs no native IO. */
    public fun cancelDeletion(admitted: UUID): Unit {
        if (pendingDeletion?.request?.confirmation?.id == admitted) cancelPendingDeletion()
    }
    private fun cancelPendingDeletion(): Unit {
        deletionRevision = UUID.randomUUID()
        val outgoing = pendingDeletion; pendingDeletion = null; outgoing?.request?.authority?.retire()
    }
    /** Only this consumed authority's completion may return through its planned relist. */
    public fun confirmDeletion(admitted: UUID): Unit {
        val captured = pendingDeletion?.takeIf { it.request.confirmation.id == admitted } ?: return
        pendingDeletion = null
        if (page != captured.page || state.value.playback !== captured.owner || !isCurrent(captured.token) ||
            !captured.request.authority.isCurrent || library.cache.directory.generation != captured.generation ||
            page != captured.page || state.value.playback !== captured.owner || !isCurrent(captured.token)) {
            captured.request.authority.retire(); return
        }
        val scheduler = requireNotNull(scope) { "Playback IO requires its presentation scope" }
        val previous = deleteTask; deleteTask = null; previous?.cancel()
        enteredDeletion?.authority?.retire(); enteredDeletion = captured.request
        val job = scheduler.launch(start = CoroutineStart.LAZY) {
            try {
                if (!isActive || page != captured.page || state.value.playback !== captured.owner ||
                    !isCurrent(captured.token) || !captured.request.authority.isCurrent ||
                    page != captured.page || state.value.playback !== captured.owner || !isCurrent(captured.token)) return@launch
                captured.request.perform()
                if (!isActive || page != captured.page || state.value.playback !== captured.owner ||
                    library.cache.directory.generation != captured.generation) return@launch
                val completion = captured.request.authority.completion
                if (completion == null || completion.claim != captured.request.authority.id || !completion.isCurrent ||
                    !library.isCurrent(completion.admission) || page != captured.page ||
                    state.value.playback !== captured.owner || library.cache.directory.generation != captured.generation) {
                    val current = captured.owner.state.value
                    if (isActive && page == captured.page && state.value.playback === captured.owner &&
                        library.cache.directory.generation == captured.generation && library.isCurrent(captured.source) &&
                        captured.request.authority.isCurrent && current.closed && current.active?.asset?.id == captured.record.asset.id &&
                        current.token == captured.token.copy(revision = captured.token.revision + 1) &&
                        page == captured.page && state.value.playback === captured.owner) {
                        val retained = library.record(captured.record.asset.id)
                        if (retained != null) {
                            enteredDeletion = null
                            open(retained, current.playlist.mapNotNull { library.record(it.asset.id) }, captured.source)
                        }
                    }
                    return@launch
                }
                val removed = library.record(captured.record.asset.id) == null
                val current = captured.owner.state.value
                val removedReturn = MonitorPlaybackRemovalAdmission.accepts(if (removed) captured.record.asset.id else null,
                    captured.record.asset.id, captured.token, current.token, current.active?.asset?.id, current.closed,
                    true, true, true)
                val retainedReturn = !removed && current.closed && current.active?.asset?.id == captured.record.asset.id &&
                    current.token == captured.token.copy(revision = captured.token.revision + 1)
                if (!removedReturn && !retainedReturn) return@launch
                enteredDeletion = null
                val retained = if (!removed) library.record(captured.record.asset.id) else null
                val preferred = captured.survivors.indexOfFirst { it.asset.id == captured.successor }.coerceAtLeast(0)
                val successor = captured.survivors.drop(preferred).firstNotNullOfOrNull { library.record(it.asset.id) }
                    ?: captured.survivors.take(preferred).asReversed().firstNotNullOfOrNull { library.record(it.asset.id) }
                if (retained != null) open(retained, current.playlist.mapNotNull { library.record(it.asset.id) }, completion.admission)
                else if (successor != null) open(successor, captured.survivors.mapNotNull { library.record(it.asset.id) }, completion.admission)
                else closePlayback()
            } finally {
                if (enteredDeletion?.confirmation?.id == admitted) {
                    enteredDeletion = null; deleteTask = null; captured.request.authority.retire()
                }
            }
        }
        deleteTask = job; job.start()
    }
    public fun deleteCurrent(admitted: MonitorPlaybackItemToken, operations: MonitorOperatorPlaybackOperations<P, L>): Unit {
        if (!isCurrent(admitted)) return
        val owner = state.value.playback ?: return
        val dying = owner.state.value.active ?: return
        val delete = operations.delete ?: return
        val scheduler = requireNotNull(scope) { "Playback IO requires its presentation coroutine scope" }
        val capturedPage = page; val source = library.actionToken; val generation = library.cache.directory.generation
        if (operations.access != null && (operations.access.invoke(dying).delete != true ||
            page != capturedPage || state.value.playback !== owner || !isCurrent(admitted) ||
            !library.isCurrent(source) || library.cache.directory.generation != generation)) return
        val index = owner.state.value.playlist.indexOfFirst { it.asset.id == dying.asset.id }.coerceAtLeast(0)
        val survivors = owner.state.value.playlist.filter { it.asset.id != dying.asset.id }
        val successor = survivors.getOrNull(index.coerceAtMost(survivors.size - 1))
        val previous = deleteTask; deleteTask = null; previous?.cancel()
        if (page != capturedPage || state.value.playback !== owner || !isCurrent(admitted)) return
        val job = scheduler.launch(start = CoroutineStart.LAZY) {
            if (page != capturedPage || state.value.playback !== owner || !library.isCurrent(source) ||
                library.cache.directory.generation != generation || !isCurrent(admitted) || !isActive) return@launch
            val removed = delete(dying)
            val current = owner.state.value
            if (!isActive || !MonitorPlaybackRemovalAdmission.accepts(if (removed) dying.asset.id else null,
                    dying.asset.id, admitted, current.token, current.active?.asset?.id, current.closed,
                    page == capturedPage && state.value.playback === owner, library.isCurrent(source),
                    library.cache.directory.generation == generation) || library.record(dying.asset.id) != null) return@launch
            val next = successor?.let { library.record(it.asset.id) }
            if (next != null) open(next, survivors, source) else closePlayback()
        }
        deleteTask = job; job.start()
    }
    private fun retireWork(): Unit {
        cancelPendingDeletion()
        enteredDeletion?.authority?.retire(); enteredDeletion = null
        val previousDelete = deleteTask
        val previousRating = ratingTasks.values.toList()
        ratingTasks.clear(); ratingRevision = UUID.randomUUID(); ratingRead = null; ratingNoticeID = null
        confirmedRating = null
        deleteTask = null; cacheRequest = null; adoptedLook = null
        previousDelete?.cancel()
        previousRating.forEach { it.cancel() }
        mutable.value = state.value.copy(ratingStars = null, ratingPending = false, ratingNotice = null)
    }
    public fun closePlayback(): Unit {
        retirePlayback()
    }
    private fun retirePlayback(): Boolean {
        val previous = state.value.playback
        page = UUID.randomUUID(); transition = UUID.randomUUID()
        val capturedPage = page; val captured = transition
        retireWork()
        if (transition != captured || page != capturedPage || state.value.playback !== previous) {
            if (state.value.playback !== previous) previous?.close()
            return false
        }
        mutable.value = state.value.copy(playback = null, playerVisible = false, deliveryPresented = false)
        if (transition != captured || page != capturedPage || state.value.playback != null) { previous?.close(); return false }
        previous?.close()
        return transition == captured && page == capturedPage && state.value.playback == null
    }

    public fun synchronize(cover: ShellModel.Cover?): Unit {
        if (cover == ShellModel.Cover.MEDIA) showGallery() else closeGallery()
    }
}
