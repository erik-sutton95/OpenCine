package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

public sealed interface MonitorPlaybackCandidate {
    public data class Cached(public val item: MonitorPlaybackItem) : MonitorPlaybackCandidate
    /** Captured host IO has actual admission; the shared owner retains cache and item preparation. */
    public data class HostDownload(public val address: String, public val mimeType: String,
        public val sourceKey: String, public val role: MediaRepresentationRole,
        public val admission: MonitorPlaybackAdmission,
        public val didCommit: () -> Unit = {},
        public val transfer: suspend (MediaByteSink) -> MediaTransferReceipt) : MonitorPlaybackCandidate
    public data class Representation(public val id: MediaRepresentationID, public val mimeType: String,
        public val sourceKey: String) : MonitorPlaybackCandidate
    public data class Download(public val address: String, public val mimeType: String,
        public val sourceKey: String, public val role: MediaRepresentationRole,
        public val transfer: suspend (MediaByteSink) -> MediaTransferReceipt) : MonitorPlaybackCandidate
}
/** A captured predicate, not a source observation or permission synthesized by the player. */
public class MonitorPlaybackAdmission(public val isCurrent: () -> Boolean)

public data class MonitorPlaybackLook<L>(public val transfer: MonitorTransfer?, public val source: L)
public data class MonitorMediaPlaybackState<P, L>(
    public val token: MonitorPlaybackItemToken,
    public val active: MonitorMediaRecord<P>? = null, public val playlist: List<MonitorMediaRecord<P>> = emptyList(),
    public val item: MonitorPlaybackItem? = null, public val ready: Boolean = false,
    public val nativeItemInstalled: Boolean = false,
    public val loading: Boolean = false, public val error: String? = null,
    public val playRequested: Boolean = true, public val reportedPlaying: Boolean? = null,
    public val position: Double = 0.0, public val duration: Double? = null,
    public val metadata: MonitorPlaybackMetadata = MonitorPlaybackMetadata(), public val reachedEnd: Boolean = false,
    public val muted: Boolean = false, public val looping: Boolean = false, public val conformTarget: Double? = null,
    public val look: MonitorPlaybackLook<L>? = null, public val lookResolution: UUID? = null, public val scrubbing: Boolean = false,
    public val scrubPosition: Double = 0.0, public val closed: Boolean = false,
    public val reportedTransport: MonitorPlaybackTransportState? = null,
) {
    /** Whether the primary transport action is Pause rather than Play. */
    public val canPause: Boolean get() = if (reportedTransport == MonitorPlaybackTransportState.WAITING)
        playRequested else reportedPlaying ?: playRequested
}
/** Real load/cache/item/scrub owner borrowing its gallery. Native callbacks share one revision. */
public class MonitorMediaPlaybackModel<P, L>(
    private val library: MonitorMediaLibraryModel<P>, public val native: MonitorPlaybackPort, scope: CoroutineScope,
    private val readyTimeout: Duration? = 8.seconds, private val retryNativeFailures: Boolean = true,
    private val lookTiming: MonitorPlaybackLookTiming = MonitorPlaybackLookTiming.AFTER_NATIVE_READINESS,
    private val startTiming: MonitorPlaybackStartTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_READINESS,
    private val candidates: (MonitorMediaRecord<P>) -> List<MonitorPlaybackCandidate>,
    private val resolveLook: suspend (MonitorMediaRecord<P>, MonitorPlaybackItem) -> MonitorPlaybackLook<L>? = { _, _ -> null },
    private val now: () -> MonotonicInstant = { MonotonicInstant.now() },
    seekEndClearance: Double = 0.05,
    private val sceneLossPolicy: MonitorPlaybackSceneLossPolicy = MonitorPlaybackSceneLossPolicy.CLEAR_REQUEST,
) {
    private val seekEndClearance = seekEndClearance.takeIf { it.isFinite() && it >= 0.0 } ?: 0.05
    private val owner = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private val mutable = MutableStateFlow(MonitorMediaPlaybackState<P, L>(MonitorPlaybackItemToken(UUID.randomUUID(), 0)))
    public val state: StateFlow<MonitorMediaPlaybackState<P, L>> = mutable.asStateFlow()
    private val libraryLifetime = library.state.value.lifetimeToken
    private var loadTask: Job? = null
    private var lookTask: Job? = null
    private var lookRevision = UUID.randomUUID()
    private var seekTask: Job? = null
    private var playRequestRevision = 0L
    private var writer: MonitorMediaCacheWrite? = null
    private data class Scrub(val token: MonitorPlaybackScrubToken, val resume: Boolean, val origin: Double,
        var lastSeek: MonotonicInstant? = null)
    private var scrub: Scrub? = null
    private var sceneActive = true
    private var presentationActive = true
    private var captureAdmission: ((MonitorMediaRecord<P>) -> MonitorPlaybackAdmission)? = null
    @Volatile private var itemAdmission: MonitorPlaybackAdmission? = null
    init {
        native.retireItem(state.value.token)
        native.onEvent = { token, event -> receive(event, token) }
        owner.launch { library.state.collect {
            if (it.lifetimeToken != libraryLifetime) close()
            else if (itemAdmission != null) admit(state.value.token)
        } }
    }
    private var publication = 0L
    private fun mutate(change: (MonitorMediaPlaybackState<P, L>) -> MonitorMediaPlaybackState<P, L>): Boolean {
        val next = change(mutable.value)
        val committed = ++publication
        mutable.value = next // StateFlow commits before a synchronous collector can replace this item.
        return publication == committed
    }
    /** Configure once before the first item; existing constructors retain their default policy. */
    public fun setItemAdmission(capture: (MonitorMediaRecord<P>) -> MonitorPlaybackAdmission) {
        if (state.value.active == null && !state.value.closed) captureAdmission = capture
    }
    private fun ownsItem(token: MonitorPlaybackItemToken): Boolean = !state.value.closed &&
        state.value.token == token && library.state.value.lifetimeToken == libraryLifetime && library.state.value.browsing
    private fun capturedItemAdmission(token: MonitorPlaybackItemToken): Boolean? {
        if (!ownsItem(token)) return null
        val admission = itemAdmission
        val accepted = admission?.isCurrent?.invoke() ?: true
        // A host predicate can synchronously retire this item or load its successor.
        if (!ownsItem(token)) return null
        return accepted
    }
    private fun current(token: MonitorPlaybackItemToken): Boolean = capturedItemAdmission(token) == true
    private fun admit(token: MonitorPlaybackItemToken): Boolean {
        val accepted = capturedItemAdmission(token) ?: return false
        if (!accepted) close()
        return accepted
    }
    private val index: Int? get() = state.value.active?.let { active -> state.value.playlist.indexOfFirst { it.asset.id == active.asset.id }.takeIf { it >= 0 } }
    public val canGoPrevious: Boolean get() = index?.let { it > 0 } == true
    public val canGoNext: Boolean get() = index?.let { it + 1 < state.value.playlist.size } == true
    public val isActive: Boolean get() = current(state.value.token)
    public val rate: Double get() = state.value.let { value ->
        val capture = value.metadata.conform.captureRate; val target = value.conformTarget
        if (capture == null || target == null) 1.0 else MonitorConformPreview.speed(capture, target)
    }
    public fun load(record: MonitorMediaRecord<P>, playlist: List<MonitorMediaRecord<P>>, play: Boolean = true) {
        val previous = state.value.token
        if (!admit(previous)) return
        retirePending()
        if (!admit(previous)) return
        val admission = captureAdmission?.invoke(record)
        if (!admit(previous)) return
        itemAdmission = admission
        if (admission?.isCurrent?.invoke() == false) { close(); return }
        val token = previous.copy(revision = previous.revision + 1)
        if (!mutate { it.copy(token = token, active = record, playlist = playlist.toList(), item = null,
            ready = false, nativeItemInstalled = false, loading = true, error = null, reachedEnd = false, position = 0.0,
            duration = record.asset.durationSeconds, metadata = MonitorPlaybackMetadata(record.asset.durationSeconds,
                record.asset.pixelSize?.width?.toDouble(), record.asset.pixelSize?.height?.toDouble(),
                MonitorConformPreview.Source(captureRate = record.asset.frameRate)),
            conformTarget = null, look = null, lookResolution = null, reportedPlaying = null, reportedTransport = null, playRequested = play, scrubbing = false) } || !admit(token)) return
        native.retireItem(token)
        if (!admit(token)) return
        val choices = candidates(record).toList()
        val hasHostSource = choices.any { it is MonitorPlaybackCandidate.HostDownload }
        if (!admit(token)) return
        val binding = library.binding; val rootGeneration = library.cache.directory.generation
        val task = owner.launch(start = CoroutineStart.LAZY) {
            for (choice in choices) {
                if (!admit(token) || !isActive) return@launch
                val prepared = try { prepare(choice, record, token, binding, rootGeneration) }
                catch (error: CancellationException) { throw error }
                catch (_: Exception) { if (!admit(token)) return@launch else continue }
                if (!admit(token) || !isActive) return@launch
                try {
                    if (!mutate { it.copy(item = prepared, nativeItemInstalled = false) } || !admit(token) || !isActive) return@launch
                    if (lookTiming == MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION) {
                        val request = lookRevision
                        val value = try { resolveLook(record, prepared) }
                        catch (error: CancellationException) { throw error }
                        catch (_: Exception) { null }
                        if (!admit(token) || lookRevision != request || !isActive) return@launch
                        if (!mutate { it.copy(look = value, lookResolution = if (value == null) null else request) } || !admit(token) || !isActive) return@launch
                    }
                    val facts = native.prepare(prepared, token, readyTimeout)
                    if (!admit(token) || !isActive) return@launch
                    val startAfterReady = startTiming == MonitorPlaybackStartTiming.AFTER_NATIVE_READINESS || !state.value.nativeItemInstalled
                    val conform = if (facts.conform.captureRate == null) facts.conform.copy(captureRate = record.asset.frameRate) else facts.conform
                    loadTask = null
                    if (!mutate { it.copy(item = prepared, metadata = facts.copy(conform = conform), duration = facts.duration ?: record.asset.durationSeconds,
                        nativeItemInstalled = true, ready = true, loading = false, error = null) } || !admit(token) || !isActive) return@launch
                    if (!applyOutput(token)) return@launch
                    if (startAfterReady && state.value.playRequested && sceneActive && presentationActive) native.play(rate, token)
                    if (!admit(token)) return@launch
                    if (lookTiming == MonitorPlaybackLookTiming.AFTER_NATIVE_READINESS) refreshTransfer()
                    return@launch
                } catch (error: CancellationException) { throw error }
                catch (_: Exception) { if (!admit(token) || !isActive) return@launch; if (!retryNativeFailures) break }
            }
            if (!admit(token) || !isActive) return@launch
            loadTask = null
            mutate { it.copy(loading = false, error = it.error ?: if (library.canTransfer || hasHostSource) "Could not open that clip." else "This clip is not cached on the phone.") }
        }
        loadTask = task; task.start()
    }
    private suspend fun prepare(choice: MonitorPlaybackCandidate, record: MonitorMediaRecord<P>, token: MonitorPlaybackItemToken,
        binding: MediaBrowseBinding?, rootGeneration: Long): MonitorPlaybackItem = when (choice) {
        is MonitorPlaybackCandidate.Cached -> choice.item
        is MonitorPlaybackCandidate.Representation -> {
            val representation = record.asset.representations.firstOrNull { it.id == choice.id }
                ?: throw MonitorPlaybackException(MonitorPlaybackFailure.UNAVAILABLE)
            val file = library.cacheRepresentation(choice.id, record.asset.id)
            currentCoroutineContext().ensureActive()
            if (!admit(token)) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
            MonitorPlaybackItem(file.toURI(), choice.mimeType, choice.sourceKey, representation.role)
        }
        is MonitorPlaybackCandidate.HostDownload -> {
            val directory = library.cache.directory
            fun admitted(): Boolean = admit(token) && choice.admission.isCurrent() && directory.generation == rootGeneration
            if (!admitted()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
            directory.existing(choice.address)?.let { MonitorPlaybackItem(it.toURI(), choice.mimeType, choice.sourceKey, choice.role) }
                ?: run {
                    val write = directory.beginWrite(choice.address); writer = write
                    try {
                        val sink = object : MediaByteSink {
                            override suspend fun write(chunk: ByteArray) {
                                currentCoroutineContext().ensureActive()
                                if (!admitted()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
                                write.write(chunk)
                            }
                        }
                        val receipt = choice.transfer(sink)
                        currentCoroutineContext().ensureActive()
                        if (!admitted()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
                        val file = write.commit(receipt); library.refreshLocalCache()
                        if (!admitted()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
                        choice.didCommit()
                        if (!admitted()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
                        MonitorPlaybackItem(file.toURI(), choice.mimeType, choice.sourceKey, choice.role)
                    } finally { write.abort(); if (writer === write) writer = null }
                }
        }
        is MonitorPlaybackCandidate.Download -> {
            val directory = library.cache.directory
            fun admitted(): Boolean = admit(token) && binding != null && library.binding == binding &&
                library.record(record.asset.id) != null &&
                library.state.value.browsing && directory.generation == rootGeneration
            if (!admitted()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
            directory.existing(choice.address)?.let { MonitorPlaybackItem(it.toURI(), choice.mimeType, choice.sourceKey, choice.role) }
                ?: run {
                    val write = directory.beginWrite(choice.address); writer = write
                    try {
                        val sink = object : MediaByteSink {
                            override suspend fun write(chunk: ByteArray) {
                                currentCoroutineContext().ensureActive()
                                if (!admitted()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
                                write.write(chunk)
                            }
                        }
                        val receipt = choice.transfer(sink)
                        currentCoroutineContext().ensureActive()
                        if (!admitted()) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
                        val file = write.commit(receipt); library.refreshLocalCache()
                        MonitorPlaybackItem(file.toURI(), choice.mimeType, choice.sourceKey, choice.role)
                    } finally { write.abort(); if (writer === write) writer = null }
                }
        }
    }
    public fun refreshTransfer() {
        val state = state.value; val active = state.active ?: return; val item = state.item ?: return
        if (!admit(state.token) || !state.ready) return
        lookTask?.cancel(); val request = UUID.randomUUID(); lookRevision = request
        val task = owner.launch(start = CoroutineStart.LAZY) {
            val value = try { resolveLook(active, item) }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { null }
            if (!admit(state.token) || lookRevision != request || !isActive) return@launch
            lookTask = null; mutate { it.copy(look = value, lookResolution = if (value == null) null else request) }
        }
        lookTask = task; task.start()
    }
    private fun receive(event: MonitorPlaybackEvent, token: MonitorPlaybackItemToken) {
        if (!admit(token)) return
        when (event) {
            MonitorPlaybackEvent.ItemInstalled -> {
                if (state.value.nativeItemInstalled || !mutate { it.copy(nativeItemInstalled = true) } || !admit(token) || !applyOutput(token)) return
                if (startTiming == MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION &&
                    state.value.playRequested && sceneActive && presentationActive) native.play(rate, token)
            }
            is MonitorPlaybackEvent.Position -> event.seconds?.takeIf { it.isFinite() && it >= 0 && !state.value.scrubbing }?.let { seconds -> mutate { it.copy(position = seconds) } }
            is MonitorPlaybackEvent.Playing -> mutate { it.copy(reportedPlaying = event.value, reportedTransport = null) }
            is MonitorPlaybackEvent.Transport -> mutate { it.copy(reportedTransport = event.value,
                reportedPlaying = event.value?.let { transport -> transport == MonitorPlaybackTransportState.PLAYING }) }
            is MonitorPlaybackEvent.Metadata -> {
                val before = state.value
                val conform = event.value.conform.let { source ->
                    if (source.captureRate == null) source.copy(captureRate = before.active?.asset?.frameRate) else source
                }
                val invalidTarget = before.conformTarget?.let { it !in MonitorConformPreview.availability(conform).targets } == true
                if (!mutate { it.copy(metadata = event.value.copy(conform = conform), duration = event.value.duration ?: it.duration,
                    conformTarget = if (invalidTarget) null else it.conformTarget) } || !admit(token)) return
                if (invalidTarget) applyOutput(token)
            }
            MonitorPlaybackEvent.Ended -> if (state.value.looping) seek(0.0, state.value.playRequested, token) else mutate { it.copy(reachedEnd = true, playRequested = false, position = it.duration ?: it.position) }
            is MonitorPlaybackEvent.Failed -> mutate { it.copy(error = event.message, loading = false, ready = false) }
        }
    }
    public fun setPlaying(play: Boolean) {
        val token = state.value.token
        playRequestRevision += 1
        setPlaying(play, token, playRequestRevision)
    }
    private fun setPlaying(play: Boolean, token: MonitorPlaybackItemToken, request: Long) {
        if (!admit(token) || request != playRequestRevision ||
            !mutate { it.copy(playRequested = play) } || !admit(token) || request != playRequestRevision) return
        if (state.value.ready && presentationActive && sceneActive) {
            if (play) native.play(rate, token) else native.pause(token)
        }
    }
    public fun togglePlaying() { if (state.value.reachedEnd) restart() else setPlaying(!state.value.canPause) }
    public fun setMuted(value: Boolean) {
        val token = state.value.token
        if (!admit(token) || !mutate { it.copy(muted = value) } || !admit(token)) return
        applyOutput(token)
    }
    public fun setLooping(value: Boolean) { if (admit(state.value.token)) mutate { it.copy(looping = value) } }
    public fun setConformTarget(value: Double?) {
        val token = state.value.token
        if (!admit(token) || value != null && value !in MonitorConformPreview.availability(state.value.metadata.conform).targets) return
        if (!mutate { it.copy(conformTarget = value) } || !admit(token) || !applyOutput(token)) return
        if (state.value.playRequested && state.value.ready && sceneActive && presentationActive) native.play(rate, token)
    }
    private fun applyOutput(token: MonitorPlaybackItemToken): Boolean {
        if (!admit(token)) return false
        native.setMuted(state.value.muted || state.value.conformTarget != null, token)
        return admit(token)
    }
    public fun restart() { seek(0.0, true, state.value.token) }
    public fun seekBy(seconds: Double) { seek(state.value.position + seconds, false, state.value.token) }
    private fun bounded(seconds: Double): Double? = state.value.duration?.takeIf { it.isFinite() && it > 0 && seconds.isFinite() }?.let { seconds.coerceIn(0.0, it) }
    private fun seek(seconds: Double, resume: Boolean, token: MonitorPlaybackItemToken) {
        val request = playRequestRevision
        val target = bounded(seconds) ?: return
        if (!state.value.ready || !admit(token)) return
        seekTask?.cancel(); seekTask = null
        if (!mutate { it.copy(position = target, scrubPosition = target, reachedEnd = it.reachedEnd && target + seekEndClearance >= (it.duration ?: 0.0)) } || !admit(token)) return
        val task = owner.launch(start = CoroutineStart.LAZY) {
            if (!admit(token) || !isActive) return@launch
            val completed = native.seek(target, 0.0, token)
            if (!admit(token) || !isActive) return@launch
            seekTask = null
            if (completed && sceneActive && presentationActive && resume) setPlaying(true, token, request)
        }
        seekTask = task; task.start()
    }
    public fun beginScrub(): MonitorPlaybackScrubToken? {
        val state = state.value
        if (!state.ready || !admit(state.token) || !sceneActive || !presentationActive) return null
        val admitted = scrub?.token ?: MonitorPlaybackScrubToken(state.token)
        if (scrub == null) {
            seekTask?.cancel(); seekTask = null
            scrub = Scrub(admitted, state.canPause, state.position)
            if (!mutate { it.copy(scrubPosition = state.position) } || !admit(state.token) || scrub?.token != admitted) return null
            native.pause(state.token)
        }
        if (!admit(state.token) || scrub?.token != admitted || !mutate { it.copy(scrubbing = true) }) return null
        return admitted.takeIf { admit(it.item) && scrub?.token == it }
    }
    public fun updateScrub(seconds: Double, admitted: MonitorPlaybackScrubToken) {
        val edit = scrub ?: return; val target = bounded(seconds) ?: return
        if (edit.token != admitted || !admit(admitted.item) || !sceneActive || !presentationActive) return
        if (!mutate { it.copy(scrubPosition = target, reachedEnd = it.reachedEnd && target + seekEndClearance >= (it.duration ?: 0.0)) } || !admit(admitted.item) || scrub !== edit) return
        val instant = now()
        if (edit.lastSeek == null || instant - edit.lastSeek!! >= 75.milliseconds) {
            edit.lastSeek = instant; seekTask?.cancel()
            val task = owner.launch(start = CoroutineStart.LAZY) {
                if (admit(admitted.item) && scrub === edit && isActive) native.seek(target, 0.1, admitted.item)
            }
            seekTask = task; task.start()
        }
    }
    public fun updateFrameScrub(delta: Double, width: Double, admitted: MonitorPlaybackScrubToken) {
        val edit = scrub ?: return; val duration = state.value.duration ?: return
        if (edit.token == admitted && width.isFinite() && width > 0) updateScrub(edit.origin + delta / width * duration, admitted)
    }
    public fun commitScrub(admitted: MonitorPlaybackScrubToken) {
        val edit = scrub ?: return
        if (edit.token != admitted || !admit(admitted.item) || !sceneActive || !presentationActive) return
        val target = state.value.scrubPosition; scrub = null
        if (!mutate { it.copy(scrubbing = false) } || !admit(admitted.item)) return
        seek(target, edit.resume, admitted.item)
    }
    public fun cancelScrub(interrupted: Boolean, admitted: MonitorPlaybackScrubToken? = null) {
        if (admitted != null && (scrub?.token != admitted || !admit(admitted.item))) return
        cancelScrub(interrupted, state.value.token)
    }
    private fun cancelScrub(interrupted: Boolean, token: MonitorPlaybackItemToken) {
        val request = playRequestRevision
        if (!admit(token)) return
        val edit = scrub; scrub = null; seekTask?.cancel(); seekTask = null
        if (!mutate { it.copy(scrubbing = false) } || !admit(token) || !interrupted || edit == null || edit.token.item != token || !sceneActive || !presentationActive) return
        val task = owner.launch(start = CoroutineStart.LAZY) {
            yield()
            if (!admit(token) || !isActive || state.value.scrubbing || !sceneActive || !presentationActive) return@launch
            seekTask = null
            if (edit.resume) setPlaying(true, token, request)
        }
        seekTask = task; task.start()
    }
    public fun setPresentationActive(value: Boolean) {
        val token = state.value.token
        if (!admit(token)) return
        presentationActive = value
        if (!value) { cancelScrub(false, token); if (admit(token)) native.pause(token) }
        else if (sceneActive && state.value.playRequested && state.value.ready) native.play(rate, token)
    }
    public fun setSceneActive(value: Boolean) {
        val token = state.value.token
        if (!admit(token)) return
        sceneActive = value
        if (!value) {
            if (sceneLossPolicy == MonitorPlaybackSceneLossPolicy.CLEAR_REQUEST) {
                playRequestRevision += 1
                // The cleared request reads paused before native reports it, so the first toggle on return resumes.
                mutate { it.copy(playRequested = false, reportedPlaying = false, reportedTransport = null) }
                // A same-item observer may publish during that commit; only a successor or a regained scene skips the pause.
                if (!admit(token) || sceneActive) return
            }
            cancelScrub(false, token)
            if (admit(token)) native.pause(token)
        }
        else if (presentationActive && state.value.playRequested && state.value.ready) native.play(rate, token)
    }
    public fun goToAdjacent(offset: Int) {
        val index = index ?: return; val playlist = state.value.playlist
        playlist.getOrNull(index + offset)?.let { load(it, playlist) }
    }
    private fun retirePending() {
        loadTask?.cancel(); loadTask = null; lookTask?.cancel(); lookTask = null; lookRevision = UUID.randomUUID()
        seekTask?.cancel(); seekTask = null; writer?.abort(); writer = null; scrub = null
    }
    public fun close() {
        if (state.value.closed) return
        val token = state.value.token.copy(revision = state.value.token.revision + 1)
        mutate { it.copy(closed = true, token = token, ready = false, nativeItemInstalled = false, loading = false, scrubbing = false) }
        retirePending(); native.close(token); owner.cancel()
    }

}
