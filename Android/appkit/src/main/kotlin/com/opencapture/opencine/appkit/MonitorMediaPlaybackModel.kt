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
    public data class Representation(public val id: MediaRepresentationID, public val mimeType: String,
        public val sourceKey: String) : MonitorPlaybackCandidate
    public data class Download(public val address: String, public val mimeType: String,
        public val sourceKey: String, public val role: MediaRepresentationRole,
        public val transfer: suspend (MediaByteSink) -> MediaTransferReceipt) : MonitorPlaybackCandidate
}
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
    public val look: MonitorPlaybackLook<L>? = null, public val scrubbing: Boolean = false,
    public val scrubPosition: Double = 0.0, public val closed: Boolean = false,
)
/** Real load/cache/item/scrub owner borrowing its gallery. Native callbacks share one revision. */
public class MonitorMediaPlaybackModel<P, L>(
    private val library: MonitorMediaLibraryModel<P>, public val native: MonitorPlaybackPort, scope: CoroutineScope,
    private val readyTimeout: Duration? = 8.seconds, private val retryNativeFailures: Boolean = true,
    private val lookTiming: MonitorPlaybackLookTiming = MonitorPlaybackLookTiming.AFTER_NATIVE_READINESS,
    private val startTiming: MonitorPlaybackStartTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_READINESS,
    private val candidates: (MonitorMediaRecord<P>) -> List<MonitorPlaybackCandidate>,
    private val resolveLook: suspend (MonitorMediaRecord<P>, MonitorPlaybackItem) -> MonitorPlaybackLook<L>? = { _, _ -> null },
    private val now: () -> MonotonicInstant = { MonotonicInstant.now() },
) {
    private val owner = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private val mutable = MutableStateFlow(MonitorMediaPlaybackState<P, L>(MonitorPlaybackItemToken(UUID.randomUUID(), 0)))
    public val state: StateFlow<MonitorMediaPlaybackState<P, L>> = mutable.asStateFlow()
    private val libraryLifetime = library.state.value.lifetimeToken
    private var loadTask: Job? = null
    private var lookTask: Job? = null
    private var lookRevision = UUID.randomUUID()
    private var seekTask: Job? = null
    private var writer: MonitorMediaCacheWrite? = null
    private data class Scrub(val token: MonitorPlaybackScrubToken, val resume: Boolean, val origin: Double,
        var lastSeek: MonotonicInstant? = null)
    private var scrub: Scrub? = null
    private var sceneActive = true
    private var presentationActive = true
    init {
        native.retireItem(state.value.token)
        native.onEvent = { token, event -> receive(event, token) }
        owner.launch { library.state.collect { if (it.lifetimeToken != libraryLifetime) close() } }
    }
    private var publication = 0L
    private fun mutate(change: (MonitorMediaPlaybackState<P, L>) -> MonitorMediaPlaybackState<P, L>): Boolean {
        val next = change(mutable.value)
        val committed = ++publication
        mutable.value = next // StateFlow commits before a synchronous collector can replace this item.
        return publication == committed
    }
    private fun current(token: MonitorPlaybackItemToken): Boolean = !state.value.closed && state.value.token == token && library.state.value.lifetimeToken == libraryLifetime && library.state.value.browsing
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
        if (!current(previous)) return
        retirePending()
        if (!current(previous)) return
        val token = previous.copy(revision = previous.revision + 1)
        if (!mutate { it.copy(token = token, active = record, playlist = playlist.toList(), item = null,
            ready = false, nativeItemInstalled = false, loading = true, error = null, reachedEnd = false, position = 0.0,
            duration = record.asset.durationSeconds, metadata = MonitorPlaybackMetadata(record.asset.durationSeconds,
                record.asset.pixelSize?.width?.toDouble(), record.asset.pixelSize?.height?.toDouble(),
                MonitorConformPreview.Source(captureRate = record.asset.frameRate)),
            conformTarget = null, look = null, reportedPlaying = null, playRequested = play, scrubbing = false) } || !current(token)) return
        native.retireItem(token)
        if (!current(token)) return
        val choices = candidates(record).toList()
        if (!current(token)) return
        val binding = library.binding; val rootGeneration = library.cache.directory.generation
        val task = owner.launch(start = CoroutineStart.LAZY) {
            for (choice in choices) {
                if (!current(token) || !isActive) return@launch
                val prepared = try { prepare(choice, record, token, binding, rootGeneration) }
                catch (error: CancellationException) { throw error }
                catch (_: Exception) { if (!current(token)) return@launch else continue }
                if (!current(token) || !isActive) return@launch
                try {
                    if (!mutate { it.copy(item = prepared, nativeItemInstalled = false) } || !current(token) || !isActive) return@launch
                    if (lookTiming == MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION) {
                        val request = lookRevision
                        val value = try { resolveLook(record, prepared) }
                        catch (error: CancellationException) { throw error }
                        catch (_: Exception) { null }
                        if (!current(token) || lookRevision != request || !isActive) return@launch
                        if (!mutate { it.copy(look = value) } || !current(token) || !isActive) return@launch
                    }
                    val facts = native.prepare(prepared, token, readyTimeout)
                    if (!current(token) || !isActive) return@launch
                    val startAfterReady = startTiming == MonitorPlaybackStartTiming.AFTER_NATIVE_READINESS || !state.value.nativeItemInstalled
                    val conform = if (facts.conform.captureRate == null) facts.conform.copy(captureRate = record.asset.frameRate) else facts.conform
                    loadTask = null
                    if (!mutate { it.copy(item = prepared, metadata = facts.copy(conform = conform), duration = facts.duration ?: record.asset.durationSeconds,
                        nativeItemInstalled = true, ready = true, loading = false, error = null) } || !current(token) || !isActive) return@launch
                    if (!applyOutput(token)) return@launch
                    if (startAfterReady && state.value.playRequested && sceneActive && presentationActive) native.play(rate, token)
                    if (!current(token)) return@launch
                    if (lookTiming == MonitorPlaybackLookTiming.AFTER_NATIVE_READINESS) refreshTransfer()
                    return@launch
                } catch (error: CancellationException) { throw error }
                catch (_: Exception) { if (!current(token) || !isActive) return@launch; if (!retryNativeFailures) break }
            }
            if (!current(token) || !isActive) return@launch
            loadTask = null
            mutate { it.copy(loading = false, error = it.error ?: if (library.canTransfer) "Could not open that clip." else "This clip is not cached on the phone.") }
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
            if (!current(token)) throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
            MonitorPlaybackItem(file.toURI(), choice.mimeType, choice.sourceKey, representation.role)
        }
        is MonitorPlaybackCandidate.Download -> {
            val directory = library.cache.directory
            fun admitted(): Boolean = current(token) && binding != null && library.binding == binding &&
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
        if (!current(state.token) || !state.ready) return
        lookTask?.cancel(); val request = UUID.randomUUID(); lookRevision = request
        val task = owner.launch(start = CoroutineStart.LAZY) {
            val value = try { resolveLook(active, item) }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { null }
            if (!current(state.token) || lookRevision != request || !isActive) return@launch
            lookTask = null; mutate { it.copy(look = value) }
        }
        lookTask = task; task.start()
    }
    private fun receive(event: MonitorPlaybackEvent, token: MonitorPlaybackItemToken) {
        if (!current(token)) return
        when (event) {
            MonitorPlaybackEvent.ItemInstalled -> {
                if (state.value.nativeItemInstalled || !mutate { it.copy(nativeItemInstalled = true) } || !current(token) || !applyOutput(token)) return
                if (startTiming == MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION &&
                    state.value.playRequested && sceneActive && presentationActive) native.play(rate, token)
            }
            is MonitorPlaybackEvent.Position -> event.seconds?.takeIf { it.isFinite() && it >= 0 && !state.value.scrubbing }?.let { seconds -> mutate { it.copy(position = seconds) } }
            is MonitorPlaybackEvent.Playing -> mutate { it.copy(reportedPlaying = event.value) }
            is MonitorPlaybackEvent.Metadata -> {
                val before = state.value
                val conform = event.value.conform.let { source ->
                    if (source.captureRate == null) source.copy(captureRate = before.active?.asset?.frameRate) else source
                }
                val invalidTarget = before.conformTarget?.let { it !in MonitorConformPreview.availability(conform).targets } == true
                if (!mutate { it.copy(metadata = event.value.copy(conform = conform), duration = event.value.duration ?: it.duration,
                    conformTarget = if (invalidTarget) null else it.conformTarget) } || !current(token)) return
                if (invalidTarget) applyOutput(token)
            }
            MonitorPlaybackEvent.Ended -> if (state.value.looping) seek(0.0, true, token) else mutate { it.copy(reachedEnd = true, playRequested = false, position = it.duration ?: it.position) }
            is MonitorPlaybackEvent.Failed -> mutate { it.copy(error = event.message, loading = false, ready = false) }
        }
    }
    public fun setPlaying(play: Boolean) { setPlaying(play, state.value.token) }
    private fun setPlaying(play: Boolean, token: MonitorPlaybackItemToken) {
        if (!current(token) || !mutate { it.copy(playRequested = play) } || !current(token)) return
        if (state.value.ready && presentationActive && sceneActive) {
            if (play) native.play(rate, token) else native.pause(token)
        }
    }
    public fun togglePlaying() { if (state.value.reachedEnd) restart() else setPlaying(!(state.value.reportedPlaying ?: state.value.playRequested)) }
    public fun setMuted(value: Boolean) {
        val token = state.value.token
        if (!current(token) || !mutate { it.copy(muted = value) } || !current(token)) return
        applyOutput(token)
    }
    public fun setLooping(value: Boolean) { if (current(state.value.token)) mutate { it.copy(looping = value) } }
    public fun setConformTarget(value: Double?) {
        val token = state.value.token
        if (!current(token) || value != null && value !in MonitorConformPreview.availability(state.value.metadata.conform).targets) return
        if (!mutate { it.copy(conformTarget = value) } || !current(token) || !applyOutput(token)) return
        if (state.value.playRequested && state.value.ready && sceneActive && presentationActive) native.play(rate, token)
    }
    private fun applyOutput(token: MonitorPlaybackItemToken): Boolean {
        if (!current(token)) return false
        native.setMuted(state.value.muted || state.value.conformTarget != null, token)
        return current(token)
    }
    public fun restart() { seek(0.0, true, state.value.token) }
    public fun seekBy(seconds: Double) { seek(state.value.position + seconds, false, state.value.token) }
    private fun bounded(seconds: Double): Double? = state.value.duration?.takeIf { it.isFinite() && it > 0 && seconds.isFinite() }?.let { seconds.coerceIn(0.0, it) }
    private fun seek(seconds: Double, resume: Boolean, token: MonitorPlaybackItemToken) {
        val target = bounded(seconds) ?: return
        if (!state.value.ready || !current(token)) return
        seekTask?.cancel(); seekTask = null
        if (!mutate { it.copy(position = target, scrubPosition = target, reachedEnd = it.reachedEnd && target + 0.05 >= (it.duration ?: 0.0)) } || !current(token)) return
        val task = owner.launch(start = CoroutineStart.LAZY) {
            if (!current(token) || !isActive) return@launch
            val completed = native.seek(target, 0.0, token)
            if (!current(token) || !isActive) return@launch
            seekTask = null
            if (completed && sceneActive && presentationActive && resume) setPlaying(true, token)
        }
        seekTask = task; task.start()
    }
    public fun beginScrub(): MonitorPlaybackScrubToken? {
        val state = state.value
        if (!state.ready || !current(state.token) || !sceneActive || !presentationActive) return null
        val admitted = scrub?.token ?: MonitorPlaybackScrubToken(state.token)
        if (scrub == null) {
            seekTask?.cancel(); seekTask = null
            scrub = Scrub(admitted, state.reportedPlaying ?: state.playRequested, state.position)
            if (!mutate { it.copy(scrubPosition = state.position) } || !current(state.token) || scrub?.token != admitted) return null
            native.pause(state.token)
        }
        if (!current(state.token) || scrub?.token != admitted || !mutate { it.copy(scrubbing = true) }) return null
        return admitted.takeIf { current(it.item) && scrub?.token == it }
    }
    public fun updateScrub(seconds: Double, admitted: MonitorPlaybackScrubToken) {
        val edit = scrub ?: return; val target = bounded(seconds) ?: return
        if (edit.token != admitted || !current(admitted.item) || !sceneActive || !presentationActive) return
        if (!mutate { it.copy(scrubPosition = target, reachedEnd = it.reachedEnd && target + 0.05 >= (it.duration ?: 0.0)) } || !current(admitted.item) || scrub !== edit) return
        val instant = now()
        if (edit.lastSeek == null || instant - edit.lastSeek!! >= 75.milliseconds) {
            edit.lastSeek = instant; seekTask?.cancel()
            val task = owner.launch(start = CoroutineStart.LAZY) {
                if (current(admitted.item) && scrub === edit && isActive) native.seek(target, 0.1, admitted.item)
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
        if (edit.token != admitted || !current(admitted.item) || !sceneActive || !presentationActive) return
        val target = state.value.scrubPosition; scrub = null
        if (!mutate { it.copy(scrubbing = false) } || !current(admitted.item)) return
        seek(target, edit.resume, admitted.item)
    }
    public fun cancelScrub(interrupted: Boolean, admitted: MonitorPlaybackScrubToken? = null) {
        if (admitted != null && (scrub?.token != admitted || !current(admitted.item))) return
        cancelScrub(interrupted, state.value.token)
    }
    private fun cancelScrub(interrupted: Boolean, token: MonitorPlaybackItemToken) {
        if (!current(token)) return
        val edit = scrub; scrub = null; seekTask?.cancel(); seekTask = null
        if (!mutate { it.copy(scrubbing = false) } || !current(token) || !interrupted || edit == null || edit.token.item != token || !sceneActive || !presentationActive) return
        val task = owner.launch(start = CoroutineStart.LAZY) {
            yield()
            if (!current(token) || !isActive || state.value.scrubbing || !sceneActive || !presentationActive) return@launch
            seekTask = null
            if (edit.resume) setPlaying(true, token)
        }
        seekTask = task; task.start()
    }
    public fun setPresentationActive(value: Boolean) {
        val token = state.value.token
        if (!current(token)) return
        presentationActive = value
        if (!value) { cancelScrub(false, token); if (current(token)) native.pause(token) }
        else if (sceneActive && state.value.playRequested && state.value.ready) native.play(rate, token)
    }
    public fun setSceneActive(value: Boolean) {
        val token = state.value.token
        if (!current(token)) return
        sceneActive = value
        if (!value) { cancelScrub(false, token); if (current(token)) native.pause(token) }
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
