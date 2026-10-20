package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.coroutines.flow.collect
import java.net.URI
import java.nio.file.Files
import kotlin.test.*
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

private class PlaybackTestPort : MonitorPlaybackPort {
    override var onEvent: ((MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Unit)? = null
    data class Preparation(val token: MonitorPlaybackItemToken, val result: CompletableDeferred<MonitorPlaybackMetadata>)
    data class Seek(val token: MonitorPlaybackItemToken, val target: Double, val tolerance: Double, val result: CompletableDeferred<Boolean>)
    val preparations = mutableListOf<Preparation>()
    val seeks = mutableListOf<Seek>()
    val played = mutableListOf<MonitorPlaybackItemToken>()
    val retired = mutableListOf<MonitorPlaybackItemToken>()
    var closes = 0
    var onPause: (() -> Unit)? = null
    var emitsInstallation = false
    var onRetire: ((MonitorPlaybackItemToken) -> Unit)? = null
    var onSeekReturn: ((MonitorPlaybackItemToken) -> Unit)? = null
    override fun retireItem(token: MonitorPlaybackItemToken) { retired += token; onRetire?.invoke(token) }
    override suspend fun prepare(item: MonitorPlaybackItem, token: MonitorPlaybackItemToken, readyTimeout: Duration?): MonitorPlaybackMetadata {
        val waiter = CompletableDeferred<MonitorPlaybackMetadata>(); preparations += Preparation(token, waiter)
        if (emitsInstallation) onEvent?.invoke(token, MonitorPlaybackEvent.ItemInstalled)
        return withContext(NonCancellable) { waiter.await() }
    }
    fun release(index: Int, facts: MonitorPlaybackMetadata = MonitorPlaybackMetadata(duration = 100.0, conform = MonitorConformPreview.Source(captureRate = 120.0))) { preparations[index].result.complete(facts) }
    override fun play(rate: Double, token: MonitorPlaybackItemToken) { played += token }
    override fun pause(token: MonitorPlaybackItemToken) { onPause?.invoke() }
    override suspend fun seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken): Boolean {
        val waiter = CompletableDeferred<Boolean>(); seeks += Seek(token, seconds, tolerance, waiter)
        val completed = withContext(NonCancellable) { waiter.await() }
        onSeekReturn?.invoke(token)
        return completed
    }
    fun finishSeek(index: Int, completed: Boolean = true) { seeks[index].result.complete(completed) }
    override fun setMuted(muted: Boolean, token: MonitorPlaybackItemToken) {}
    override fun close(token: MonitorPlaybackItemToken) { if (retired.lastOrNull()?.owner == token.owner) { closes += 1; onEvent = null } }
}
private class PlaybackTestCodec(val records: List<MonitorMediaRecord<String>>) : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray) = records
    override fun encode(records: List<MonitorMediaRecord<String>>) = byteArrayOf()
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> = error("unused")
}
private class PlaybackTestFavorites : MonitorMediaFavoritesStore {
    override fun favorites() = emptySet<String>()
    override fun saveFavorites(keys: Set<String>) {}
}
private class PlaybackLookResolver {
    val pending = mutableListOf<CompletableDeferred<MonitorPlaybackLook<String>?>>()
    suspend fun resolve(): MonitorPlaybackLook<String>? {
        val waiter = CompletableDeferred<MonitorPlaybackLook<String>?>().also { pending += it }
        return withContext(NonCancellable) { waiter.await() }
    }
    fun release(index: Int, source: String) { pending[index].complete(MonitorPlaybackLook(MonitorTransfer.ILOG, source)) }
}
private class PlaybackByteTransfer {
    val pending = mutableListOf<CompletableDeferred<Unit>>()
    suspend fun transfer(sink: MediaByteSink): MediaTransferReceipt {
        val byte = (pending.size * 2 + 1).toByte()
        sink.write(byteArrayOf(byte))
        val waiter = CompletableDeferred<Unit>(); pending += waiter
        withContext(NonCancellable) { waiter.await() }
        sink.write(byteArrayOf((byte + 1).toByte()))
        return MediaTransferReceipt(2, 2)
    }
    fun release(index: Int) { pending[index].complete(Unit) }
}
private class PlaybackEmptyCursor : MediaCatalogCursor {
    override suspend fun next(): MediaCatalogDelta? = null
    override fun close() {}
}
private class PlaybackBrowse : CameraMediaBrowse {
    override val binding = MediaBrowseBinding(com.opencapture.opencine.core.CameraSessionID(), com.opencapture.opencine.core.ControlEpoch(1))
    override val thumbnails: CameraMediaThumbnailService? = null
    override val transfers: CameraMediaTransferService? = null
    override val deletion: CameraMediaDeleteService? = null
    override suspend fun catalog(): MediaCatalogCursor = PlaybackEmptyCursor()
    override suspend fun close() {}
}
private class PlaybackService : CameraMediaService {
    val browse = PlaybackBrowse()
    override val sessionID get() = browse.binding.session
    override suspend fun openBrowse(): CameraMediaBrowse = browse
}
private class PlaybackTestClock { var instant = MonotonicInstant(100.seconds) }
private class PlaybackResumeProbe {
    var observing = false
    var observations = 0
    var reentered = false
    var atObservation: ((Int) -> Unit)? = null
    fun current(): Boolean {
        if (observing) { observations += 1; atObservation?.invoke(observations) }
        return true
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaPlaybackModelTest {
    private fun record(id: String) = MonitorMediaRecord(MediaAsset(MediaAssetID(id), filename = "$id.mov", kind = MediaAssetKind.VIDEO,
        durationSeconds = 100.0, frameRate = 120.0, representations = emptyList()), id,
        MonitorMediaCacheAddress("$id.jpg", emptyMap(), id))
    private data class Fixture(val root: java.io.File, val library: MonitorMediaLibraryModel<String>, val port: PlaybackTestPort,
        val model: MonitorMediaPlaybackModel<String, String>) {
        suspend fun close() { model.close(); library.dispose(); root.deleteRecursively() }
    }
    private fun fixture(scope: CoroutineScope, clock: PlaybackTestClock = PlaybackTestClock(), native: PlaybackTestPort? = null,
        lookTiming: MonitorPlaybackLookTiming = MonitorPlaybackLookTiming.AFTER_NATIVE_READINESS,
        startTiming: MonitorPlaybackStartTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_READINESS,
        records: List<MonitorMediaRecord<String>> = emptyList(), service: CameraMediaService? = null,
        seekEndClearance: Double = 0.05,
        sceneLossPolicy: MonitorPlaybackSceneLossPolicy? = null,
        candidate: ((MonitorMediaRecord<String>) -> List<MonitorPlaybackCandidate>)? = null,
        resolveLook: suspend (MonitorMediaRecord<String>, MonitorPlaybackItem) -> MonitorPlaybackLook<String>? = { _, _ -> null }): Fixture {
        val root = Files.createTempDirectory("opencine-playback-").toFile()
        val cache = MonitorMediaCache(MonitorMediaCacheDirectory(root), PlaybackTestCodec(records), MonitorMediaOriginalEligibility.ExactSize,
            "index.json", listOf("index.json"))
        cache.directory.write("[]".toByteArray(), "index.json")
        val library = MonitorMediaLibraryModel(cache, PlaybackTestFavorites(), service = service, scope = scope); library.begin()
        val port = native ?: PlaybackTestPort()
        val candidates = candidate ?: { listOf(MonitorPlaybackCandidate.Cached(MonitorPlaybackItem(URI("file:/${it.payload}.mov"), "video/mp4", it.payload))) }
        val model = if (sceneLossPolicy == null)
            MonitorMediaPlaybackModel<String, String>(library, port, scope, lookTiming = lookTiming, startTiming = startTiming,
                candidates = candidates, resolveLook = resolveLook, now = { clock.instant },
                seekEndClearance = seekEndClearance)
        else MonitorMediaPlaybackModel<String, String>(library, port, scope, lookTiming = lookTiming, startTiming = startTiming,
            candidates = candidates, resolveLook = resolveLook, now = { clock.instant }, seekEndClearance = seekEndClearance,
            sceneLossPolicy = sceneLossPolicy)
        return Fixture(root, library, port, model)
    }
    private fun resumeProbe(model: MonitorMediaPlaybackModel<String, String>, port: PlaybackTestPort): PlaybackResumeProbe {
        val probe = PlaybackResumeProbe()
        model.setItemAdmission { MonitorPlaybackAdmission { probe.current() } }
        port.onSeekReturn = { probe.observing = true }
        return probe
    }

    @Test fun pendingLoopSeekCompletionCannotOverrideOperatorPause() = runTest {
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION)
        val model = fixture.model; val port = fixture.port; val probe = resumeProbe(model, port)
        try {
            val row = record("loop"); model.load(row, listOf(row)); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token; assertTrue(model.state.value.ready); assertEquals(listOf(item), port.played)
            model.setLooping(true); port.onEvent?.invoke(item, MonitorPlaybackEvent.Ended); runCurrent()
            assertEquals(1, port.seeks.size); model.setPlaying(false)
            assertFalse(model.state.value.playRequested); assertEquals(1, port.seeks.size)
            port.finishSeek(0); runCurrent(); assertTrue(probe.observations > 0)
            assertFalse(model.state.value.playRequested); assertEquals(listOf(item), port.played)
            assertEquals(item, port.seeks[0].token); assertEquals(0.0, port.seeks[0].target); assertEquals(0.0, port.seeks[0].tolerance)
            assertTrue(model.state.value.ready); assertEquals(item, model.state.value.token); assertEquals(0, port.closes)
            assertTrue(fixture.library.state.value.browsing)
        } finally { fixture.close() }
    }

    @Test fun pendingRestartSeekCompletionCannotOverrideRepeatedPause() = runTest {
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION)
        val model = fixture.model; val port = fixture.port; val probe = resumeProbe(model, port)
        try {
            val row = record("restart"); model.load(row, listOf(row), play = false); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token; assertTrue(model.state.value.ready)
            model.restart(); runCurrent(); assertEquals(1, port.seeks.size)
            model.setPlaying(false); assertFalse(model.state.value.playRequested)
            port.finishSeek(0); runCurrent(); assertTrue(probe.observations > 0)
            assertFalse(model.state.value.playRequested); assertTrue(port.played.isEmpty())
            assertTrue(model.state.value.ready); assertEquals(item, model.state.value.token)
            assertEquals(item, port.seeks[0].token); assertEquals(0, port.closes)
        } finally { fixture.close() }
    }

    @Test fun explicitRestartWhilePausedStillResumesPlayback() = runTest {
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION)
        val model = fixture.model; val port = fixture.port; val probe = resumeProbe(model, port)
        try {
            val row = record("restart"); model.load(row, listOf(row), play = false); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token; assertTrue(model.state.value.ready)
            model.restart(); runCurrent(); assertEquals(1, port.seeks.size)
            port.finishSeek(0); runCurrent(); assertTrue(probe.observations > 0)
            assertTrue(model.state.value.playRequested); assertEquals(listOf(item), port.played); assertEquals(item, model.state.value.token)
            assertEquals(0.0, port.seeks[0].target); assertEquals(0.0, port.seeks[0].tolerance); assertEquals(0, port.closes)
        } finally { fixture.close() }
    }

    @Test fun unrelatedPublicationDoesNotInvalidatePendingRestart() = runTest {
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION)
        val model = fixture.model; val port = fixture.port; val probe = resumeProbe(model, port)
        try {
            val row = record("restart"); model.load(row, listOf(row), play = false); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token
            model.restart(); runCurrent(); assertEquals(1, port.seeks.size)
            model.setMuted(true); port.onEvent?.invoke(item, MonitorPlaybackEvent.Playing(false))
            port.onEvent?.invoke(item, MonitorPlaybackEvent.Position(42.0))
            port.finishSeek(0); runCurrent(); assertTrue(probe.observations > 0)
            assertTrue(model.state.value.playRequested); assertEquals(listOf(item), port.played); assertTrue(model.state.value.muted)
            assertEquals(42.0, model.state.value.position); assertEquals(false, model.state.value.reportedPlaying)
            assertEquals(item, model.state.value.token)
        } finally { fixture.close() }
    }

    @Test fun lateLoopEndAfterPauseCannotRequestPlayback() = runTest {
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION)
        val model = fixture.model; val port = fixture.port; val probe = resumeProbe(model, port)
        try {
            val row = record("loop"); model.load(row, listOf(row)); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token
            model.setLooping(true); model.setPlaying(false); port.onEvent?.invoke(item, MonitorPlaybackEvent.Ended); runCurrent()
            assertEquals(1, port.seeks.size); port.finishSeek(0); runCurrent(); assertTrue(probe.observations > 0)
            assertFalse(model.state.value.playRequested); assertTrue(model.state.value.looping); assertEquals(listOf(item), port.played)
            assertEquals(0.0, port.seeks[0].target); assertEquals(item, port.seeks[0].token); assertEquals(item, model.state.value.token)
        } finally { fixture.close() }
    }

    @Test fun restartAdmissionPauseCannotBeOverriddenByCompletion() = runTest {
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION)
        val model = fixture.model; val port = fixture.port; val probe = resumeProbe(model, port)
        try {
            val row = record("restart"); model.load(row, listOf(row), play = false); runCurrent(); port.release(0); runCurrent()
            probe.atObservation = {
                probe.atObservation = null; probe.reentered = true; model.setPlaying(false)
            }
            probe.observing = true; model.restart(); probe.observing = false; probe.observations = 0
            assertTrue(probe.reentered); runCurrent(); assertEquals(1, port.seeks.size)
            port.finishSeek(0); runCurrent(); assertTrue(probe.observations > 0)
            assertFalse(model.state.value.playRequested); assertTrue(port.played.isEmpty()); assertTrue(model.state.value.ready)
        } finally { fixture.close() }
    }

    @Test fun resumeAdmissionPauseCannotStartNativeTransport() = runTest {
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION)
        val model = fixture.model; val port = fixture.port; val probe = resumeProbe(model, port)
        try {
            val row = record("restart"); model.load(row, listOf(row), play = false); runCurrent(); port.release(0); runCurrent()
            model.restart(); runCurrent(); assertEquals(1, port.seeks.size)
            probe.atObservation = {
                if (model.state.value.playRequested) {
                    probe.atObservation = null; probe.reentered = true; model.setPlaying(false)
                }
            }
            port.finishSeek(0); runCurrent(); assertTrue(probe.observations > 0)
            assertTrue(probe.reentered); assertFalse(model.state.value.playRequested); assertTrue(port.played.isEmpty())
        } finally { fixture.close() }
    }

    @Test fun clearRequestSceneLossDuringResumeAdmissionCannotStartNativeTransport() = runTest {
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION,
            sceneLossPolicy = MonitorPlaybackSceneLossPolicy.CLEAR_REQUEST)
        val model = fixture.model; val port = fixture.port; val probe = resumeProbe(model, port)
        try {
            val row = record("restart"); model.load(row, listOf(row), play = false); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token
            model.restart(); runCurrent(); assertEquals(1, port.seeks.size)
            probe.atObservation = {
                if (model.state.value.playRequested) {
                    probe.atObservation = null; probe.reentered = true
                    model.setSceneActive(false); model.setSceneActive(true)
                }
            }
            port.finishSeek(0); runCurrent(); assertTrue(probe.observations > 0)
            assertTrue(probe.reentered); assertFalse(model.state.value.playRequested); assertTrue(port.played.isEmpty())
            assertTrue(model.state.value.ready); assertEquals(item, model.state.value.token); assertEquals(0, port.closes)
            assertTrue(fixture.library.state.value.browsing)
        } finally { fixture.close() }
    }

    @Test fun interruptedScrubDeferredResumeCannotOverrideLaterPause() = runTest {
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION)
        val model = fixture.model; val port = fixture.port; val probe = resumeProbe(model, port)
        try {
            val row = record("scrub"); model.load(row, listOf(row)); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token; assertNotNull(model.beginScrub())
            model.cancelScrub(true); model.setPlaying(false); probe.observing = true
            runCurrent(); assertTrue(probe.observations > 0)
            assertFalse(model.state.value.scrubbing); assertFalse(model.state.value.playRequested); assertEquals(listOf(item), port.played)
            assertEquals(item, model.state.value.token); assertTrue(port.seeks.isEmpty()); assertEquals(0, port.closes)
            assertTrue(fixture.library.state.value.browsing)
        } finally { fixture.close() }
    }

    @Test fun replacementRejectsLateReadyAndTimeFromPreviousItem() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B")
            model.load(a, listOf(a, b)); runCurrent(); val old = model.state.value.token
            model.load(b, listOf(a, b)); runCurrent(); val current = model.state.value.token
            port.release(1); runCurrent(); assertTrue(model.state.value.ready)
            port.onEvent?.invoke(current, MonitorPlaybackEvent.Position(42.0)); port.release(0); runCurrent()
            port.onEvent?.invoke(old, MonitorPlaybackEvent.Position(7.0)); port.onEvent?.invoke(old, MonitorPlaybackEvent.Ended)
            assertEquals("B", model.state.value.active?.payload); assertEquals(42.0, model.state.value.position)
            assertTrue(model.state.value.playRequested); assertFalse(model.state.value.reachedEnd); assertEquals(listOf(current), port.played)
        } finally { fixture.close() }
    }
    @Test fun retiredFinalSeekCannotResumeReplacement() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B")
            model.load(a, listOf(a, b)); runCurrent(); port.release(0); runCurrent()
            val token = assertNotNull(model.beginScrub()); model.updateScrub(25.0, token); runCurrent()
            port.finishSeek(0); model.commitScrub(token); runCurrent()
            model.load(b, listOf(a, b), play = false); runCurrent(); port.release(1); runCurrent()
            port.finishSeek(1); runCurrent()
            assertFalse(model.state.value.playRequested); assertEquals(listOf(token.item), port.played); assertEquals("B", model.state.value.active?.payload)
        } finally { fixture.close() }
    }
    @Test fun scrubThrottleUsesManualClockAndFinalExactSeek() = runTest {
        val clock = PlaybackTestClock(); val fixture = fixture(backgroundScope, clock); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent(); port.release(0); runCurrent()
            val token = assertNotNull(model.beginScrub())
            model.updateScrub(10.0, token); runCurrent(); port.finishSeek(0)
            clock.instant += 74.milliseconds; model.updateScrub(20.0, token); runCurrent()
            assertEquals(1, port.seeks.size); assertEquals(20.0, model.state.value.scrubPosition)
            clock.instant += 1.milliseconds; model.updateScrub(30.0, token); runCurrent(); port.finishSeek(1)
            model.commitScrub(token); runCurrent()
            assertEquals(listOf(0.1, 0.1, 0.0), port.seeks.map { it.tolerance }); assertEquals(listOf(10.0, 30.0, 30.0), port.seeks.map { it.target })
            port.finishSeek(2); runCurrent()
        } finally { fixture.close() }
    }
    @Test fun coverAndSceneLossKeepNativeOwnerWithoutResumingInterruptedScrub() = runTest {
        val fixture = fixture(backgroundScope, sceneLossPolicy = MonitorPlaybackSceneLossPolicy.PRESERVE_REQUEST)
        val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent(); port.release(0); runCurrent()
            val token = model.state.value.token; model.beginScrub(); model.cancelScrub(true); model.setSceneActive(false); runCurrent()
            assertEquals(listOf(token), port.played)
            model.setPresentationActive(false); model.setSceneActive(true)
            assertEquals(token, model.state.value.token); assertEquals(0, port.closes); assertTrue(fixture.library.state.value.browsing)
            model.setPresentationActive(true); assertEquals(listOf(token, token), port.played); assertTrue(model.state.value.ready)
        } finally { fixture.close() }
    }
    @Test fun defaultSceneLossLeavesPlaybackPausedOnForegroundReturn() = runTest {
        val fixture = fixture(backgroundScope)
        val model = fixture.model; val port = fixture.port
        try {
            val row = record("scene-default")
            model.load(row, listOf(row)); runCurrent(); port.release(0); runCurrent()
            assertTrue(model.state.value.ready); assertEquals(1, port.played.size)
            model.setSceneActive(false); runCurrent()
            assertFalse(model.state.value.playRequested)
            model.setSceneActive(true); runCurrent()
            assertFalse(model.state.value.playRequested)
            assertEquals(1, port.played.size, "Returning from the background must not restart playback")
            model.setPlaying(true); runCurrent()
            assertEquals(2, port.played.size)
        } finally { fixture.close() }
    }
    @Test fun firstToggleAfterSceneLossResumesWhenNativeNeverReportedThePause() = runTest {
        val fixture = fixture(backgroundScope)
        val model = fixture.model; val port = fixture.port
        try {
            val row = record("scene-toggle")
            model.load(row, listOf(row)); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token
            port.onEvent?.invoke(item, MonitorPlaybackEvent.Playing(true))
            model.setSceneActive(false); model.setSceneActive(true); runCurrent()
            assertFalse(model.state.value.canPause, "A cleared request reads paused until native reports again")
            model.togglePlaying(); runCurrent()
            assertTrue(model.state.value.playRequested); assertEquals(listOf(item, item), port.played)
        } finally { fixture.close() }
    }
    @Test fun sameItemObserverDuringSceneLossCannotSkipTheNativePause() = runTest {
        val fixture = fixture(backgroundScope)
        val model = fixture.model; val port = fixture.port
        try {
            val row = record("scene-observer")
            model.load(row, listOf(row)); runCurrent(); port.release(0); runCurrent()
            var pauses = 0; port.onPause = { pauses += 1 }; var looped = false
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                model.state.collect { if (!looped && !it.playRequested) { looped = true; model.setLooping(true) } }
            }
            model.setSceneActive(false)
            assertTrue(looped); assertTrue(model.state.value.looping); assertFalse(model.state.value.playRequested)
            assertEquals(1, pauses, "Losing the scene must still pause the native player")
        } finally { fixture.close() }
    }
    @Test fun closeRejectsLateReadyAndLeavesBorrowedGalleryOpen() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent()
            model.close(); model.close(); port.release(0); runCurrent()
            assertTrue(model.state.value.closed); assertFalse(model.state.value.ready); assertTrue(port.played.isEmpty())
            assertEquals(1, port.closes); assertTrue(fixture.library.state.value.browsing)
        } finally { fixture.close() }
    }
    @Test fun replacementRejectsLateResolvedLook() = runTest {
        val resolver = PlaybackLookResolver(); val fixture = fixture(backgroundScope, resolveLook = { _, _ -> resolver.resolve() })
        val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B")
            model.load(a, listOf(a, b)); runCurrent(); port.release(0); runCurrent()
            model.load(b, listOf(a, b)); runCurrent(); port.release(1); runCurrent()
            resolver.release(1, "B"); runCurrent(); resolver.release(0, "A"); runCurrent()
            assertEquals("B", model.state.value.look?.source); assertEquals("B", model.state.value.active?.payload)
        } finally { fixture.close() }
    }
    @Test fun newerLookRequestRetiresOlderResolutionOnSameItem() = runTest {
        val resolver = PlaybackLookResolver(); val fixture = fixture(backgroundScope, resolveLook = { _, _ -> resolver.resolve() })
        val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent(); port.release(0); runCurrent()
            val token = model.state.value.token; model.refreshTransfer(); runCurrent()
            resolver.release(1, "current"); runCurrent(); resolver.release(0, "old"); runCurrent()
            assertEquals(token, model.state.value.token); assertEquals("current", model.state.value.look?.source)
        } finally { fixture.close() }
    }

    @Test fun offlineLibraryReplacementRejectsPendingLoadWithoutClosingSuccessorPlayer() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        var successorFixture: Fixture? = null
        try {
            val a = record("A"); val b = record("B"); model.load(a, listOf(a)); runCurrent()
            val oldLifetime = fixture.library.state.value.lifetimeToken; fixture.library.bind(null)
            assertNotEquals(oldLifetime, fixture.library.state.value.lifetimeToken); assertTrue(fixture.library.state.value.browsing); assertNull(fixture.library.binding)
            val successor = fixture(backgroundScope, native = port).also { successorFixture = it }.model
            successor.load(b, listOf(b)); runCurrent(); assertTrue(model.state.value.closed)
            port.release(1); runCurrent(); assertTrue(successor.state.value.ready)
            val current = successor.state.value.token
            port.release(0); model.setPlaying(true); port.onEvent?.invoke(current, MonitorPlaybackEvent.Position(33.0)); runCurrent()
            assertFalse(model.state.value.ready); assertEquals(33.0, successor.state.value.position); assertEquals("B", successor.state.value.active?.payload)
            assertEquals(0, port.closes); assertEquals(listOf(current), port.played)
        } finally { fixture.close(); successorFixture?.close() }
    }
    @Test fun offlineLibraryReopenRejectsPendingLook() = runTest {
        val resolver = PlaybackLookResolver(); val fixture = fixture(backgroundScope, resolveLook = { _, _ -> resolver.resolve() })
        val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent(); port.release(0); runCurrent()
            val oldLifetime = fixture.library.state.value.lifetimeToken; fixture.library.close(); fixture.library.begin()
            assertNotEquals(oldLifetime, fixture.library.state.value.lifetimeToken); runCurrent(); assertTrue(model.state.value.closed)
            resolver.release(0, "retired"); runCurrent()
            assertNull(model.state.value.look); assertEquals(1, port.closes); assertTrue(fixture.library.state.value.browsing)
        } finally { fixture.close() }
    }
    @Test fun offlineLibraryReplacementRejectsPendingFinalSeekAndNativeEvents() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent(); port.release(0); runCurrent()
            val token = assertNotNull(model.beginScrub()); model.updateScrub(24.0, token); runCurrent(); port.finishSeek(0)
            model.commitScrub(token); runCurrent(); val nativeEvent = port.onEvent
            fixture.library.bind(null); model.setPlaying(true); model.setMuted(true)
            nativeEvent?.invoke(token.item, MonitorPlaybackEvent.Position(81.0)); nativeEvent?.invoke(token.item, MonitorPlaybackEvent.Ended)
            runCurrent(); assertTrue(model.state.value.closed); port.finishSeek(1); runCurrent()
            assertEquals(24.0, model.state.value.position); assertFalse(model.state.value.reachedEnd); assertFalse(model.state.value.muted)
            assertEquals(listOf(token.item), port.played); assertTrue(fixture.library.state.value.browsing)
        } finally { fixture.close() }
    }

    @Test fun nativePlayingReportControlsToggleAndScrubWithoutBecomingIntent() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B"); model.load(a, listOf(a, b)); runCurrent(); port.release(0); runCurrent()
            val token = model.state.value.token; port.onEvent?.invoke(token, MonitorPlaybackEvent.Playing(false))
            assertTrue(model.state.value.playRequested); assertEquals(false, model.state.value.reportedPlaying)
            model.togglePlaying(); assertEquals(listOf(token, token), port.played)
            val scrub = assertNotNull(model.beginScrub()); model.updateScrub(20.0, scrub); runCurrent()
            port.finishSeek(0); model.commitScrub(scrub); runCurrent(); port.finishSeek(1); runCurrent()
            assertEquals(listOf(token, token), port.played)
            model.load(b, listOf(a, b)); runCurrent(); port.release(1); runCurrent()
            port.onEvent?.invoke(token, MonitorPlaybackEvent.Playing(true)); assertNull(model.state.value.reportedPlaying)
            port.onEvent?.invoke(model.state.value.token, MonitorPlaybackEvent.Playing(false))
            port.onEvent?.invoke(model.state.value.token, MonitorPlaybackEvent.Playing(null))
            assertNull(model.state.value.reportedPlaying); assertTrue(model.state.value.playRequested)
        } finally { fixture.close() }
    }
    @Test fun observableReadyRetirementCannotStartNativePlayback() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent()
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                model.state.collect { if (it.ready) fixture.library.bind(null) }
            }
            port.release(0); runCurrent()
            assertTrue(model.state.value.closed); assertFalse(model.state.value.ready)
            assertTrue(port.played.isEmpty()); assertTrue(fixture.library.state.value.browsing)
        } finally { fixture.close() }
    }

    @Test fun metadataBeforeNativePreparationRejectsRetiredSourceBeforeDecode() = runTest {
        val resolver = PlaybackLookResolver()
        val fixture = fixture(backgroundScope, lookTiming = MonitorPlaybackLookTiming.BEFORE_NATIVE_PREPARATION,
            resolveLook = { _, _ -> resolver.resolve() })
        val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B"); model.load(a, listOf(a, b)); runCurrent()
            assertEquals(1, resolver.pending.size); assertTrue(port.preparations.isEmpty())
            model.goToAdjacent(1); runCurrent(); assertEquals(2, resolver.pending.size)
            resolver.release(0, "retired"); runCurrent(); assertTrue(port.preparations.isEmpty())
            resolver.release(1, "B"); runCurrent(); assertEquals(1, port.preparations.size)
            assertEquals("B", model.state.value.look?.source); assertFalse(model.state.value.ready)
            assertEquals("B", model.state.value.active?.payload); assertEquals(model.state.value.token, port.preparations[0].token)
            port.release(0); runCurrent(); assertTrue(model.state.value.ready)
            assertEquals(2, resolver.pending.size); assertEquals(listOf(model.state.value.token), port.played)
        } finally { fixture.close() }
    }

    @Test fun replacementAbortsOnlyItsOwnStreamingWriteAndKeepsSuccessorBytes() = runTest {
        val transfer = PlaybackByteTransfer(); val a = record("A"); val b = record("B")
        val fixture = fixture(backgroundScope, records = listOf(a, b), service = PlaybackService(), candidate = { record ->
            listOf(MonitorPlaybackCandidate.Download("shared.mov", "video/mp4", record.payload,
                MediaRepresentationRole.PROXY, transfer::transfer))
        })
        val model = fixture.model; val port = fixture.port
        try {
            runCurrent(); assertNotNull(fixture.library.binding)
            model.load(a, listOf(a, b)); runCurrent(); assertEquals(1, transfer.pending.size)
            model.goToAdjacent(1); runCurrent(); assertEquals(2, transfer.pending.size)
            transfer.release(0); runCurrent(); assertTrue(port.preparations.isEmpty())
            transfer.release(1); runCurrent(); assertEquals(1, port.preparations.size)
            assertContentEquals(byteArrayOf(3, 4), fixture.library.cache.directory.read("shared.mov"))
            port.release(0); runCurrent(); assertTrue(model.state.value.ready)
            assertEquals("B", model.state.value.item?.sourceKey); assertEquals("B", model.state.value.active?.payload)
            assertEquals(listOf(model.state.value.token), port.played)
        } finally { fixture.close() }
    }

    @Test fun relativeSeekKeepsNativeTransportWithoutInventingResumeFromIntent() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent(); port.release(0); runCurrent()
            val token = model.state.value.token
            port.onEvent?.invoke(token, MonitorPlaybackEvent.Playing(false))
            port.onEvent?.invoke(token, MonitorPlaybackEvent.Position(25.0))
            model.seekBy(15.0); runCurrent()
            assertEquals(40.0, port.seeks.single().target); assertEquals(0.0, port.seeks.single().tolerance)
            port.finishSeek(0); runCurrent()
            assertEquals(listOf(token), port.played); assertTrue(model.state.value.playRequested)
            assertEquals(false, model.state.value.reportedPlaying)
        } finally { fixture.close() }
    }

    @Test fun nativePauseReplacementCannotStartScrubOnSuccessor() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B"); model.load(a, listOf(a, b)); runCurrent(); port.release(0); runCurrent()
            port.onPause = { port.onPause = null; model.load(b, listOf(a, b), play = false) }
            assertNull(model.beginScrub()); assertEquals("B", model.state.value.active?.payload)
            assertFalse(model.state.value.scrubbing)
            runCurrent(); port.release(1); runCurrent()
            assertTrue(model.state.value.ready); assertFalse(model.state.value.scrubbing)
            assertFalse(model.state.value.playRequested); assertEquals(1, port.played.size)
        } finally { fixture.close() }
    }

    @Test fun nativeInstallationAndReadinessKeepTheirDistinctTransportTiming() = runTest {
        val port = PlaybackTestPort().also { it.emitsInstallation = true }
        val fixture = fixture(backgroundScope, native = port)
        var eagerFixture: Fixture? = null
        try {
            val a = record("A"); fixture.model.load(a, listOf(a)); runCurrent()
            assertTrue(fixture.model.state.value.nativeItemInstalled); assertFalse(fixture.model.state.value.ready)
            assertTrue(port.played.isEmpty())
            port.release(0); runCurrent(); assertTrue(fixture.model.state.value.ready)
            assertEquals(listOf(fixture.model.state.value.token), port.played)

            val eagerPort = PlaybackTestPort().also { it.emitsInstallation = true }
            val eager = fixture(backgroundScope, native = eagerPort,
                startTiming = MonitorPlaybackStartTiming.AFTER_NATIVE_ITEM_INSTALLATION).also { eagerFixture = it }.model
            eager.load(a, listOf(a)); runCurrent()
            assertTrue(eager.state.value.nativeItemInstalled); assertFalse(eager.state.value.ready)
            assertEquals(listOf(eager.state.value.token), eagerPort.played)
            eagerPort.release(0); runCurrent(); assertTrue(eager.state.value.ready)
            assertEquals(listOf(eager.state.value.token), eagerPort.played)
        } finally { fixture.close(); eagerFixture?.close() }
    }

    @Test fun observableActiveReplacementKeepsSuccessorSnapshotAndNativeRequest() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B"); var replaced = false
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                model.state.collect {
                    if (!replaced && it.active?.payload == "A") { replaced = true; model.load(b, listOf(b), play = false) }
                }
            }
            model.load(a, listOf(a)); runCurrent()
            assertEquals("B", model.state.value.active?.payload); assertEquals(listOf("B"), model.state.value.playlist.map { it.payload })
            assertFalse(model.state.value.playRequested); assertEquals(1, port.preparations.size)
            assertEquals(model.state.value.token, port.preparations[0].token)
            port.release(0); runCurrent(); assertTrue(model.state.value.ready)
            assertEquals("B", model.state.value.item?.sourceKey); assertTrue(port.played.isEmpty())
        } finally { fixture.close() }
    }

    @Test fun observableReadyReplacementCannotOverwriteSuccessorLoadingSnapshot() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B"); model.load(a, listOf(a)); runCurrent(); var replaced = false
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                model.state.collect {
                    if (!replaced && it.ready && it.active?.payload == "A") { replaced = true; model.load(b, listOf(b), play = false) }
                }
            }
            port.release(0); runCurrent(); assertEquals(2, port.preparations.size)
            assertEquals("B", model.state.value.active?.payload); assertFalse(model.state.value.ready)
            assertTrue(model.state.value.loading); assertEquals("B", model.state.value.item?.sourceKey)
            assertEquals(model.state.value.token, port.preparations[1].token); assertTrue(port.played.isEmpty())
            port.release(1); runCurrent(); assertTrue(model.state.value.ready)
            assertEquals("B", model.state.value.item?.sourceKey); assertFalse(model.state.value.playRequested)
            assertTrue(port.played.isEmpty())
        } finally { fixture.close() }
    }

    @Test fun observablePlayIntentReplacementCannotStartSuccessorTransport() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B"); model.load(a, listOf(a), play = false); runCurrent(); port.release(0); runCurrent()
            var replaced = false
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                model.state.collect {
                    if (!replaced && it.active?.payload == "A" && it.playRequested) { replaced = true; model.load(b, listOf(b), play = false) }
                }
            }
            model.setPlaying(true); runCurrent()
            assertEquals("B", model.state.value.active?.payload); assertFalse(model.state.value.playRequested)
            assertEquals(2, port.preparations.size); port.release(1); runCurrent(); assertTrue(model.state.value.ready)
            assertEquals("B", model.state.value.item?.sourceKey); assertTrue(port.played.isEmpty())
        } finally { fixture.close() }
    }

    @Test fun nativeRetirementReplacementUsesDistinctSuccessorAuthority() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B")
            port.onRetire = { token -> if (token.revision == 1L) { port.onRetire = null; model.load(b, listOf(b), play = false) } }
            model.load(a, listOf(a)); runCurrent()
            assertEquals(2L, model.state.value.token.revision); assertEquals("B", model.state.value.active?.payload)
            assertFalse(model.state.value.playRequested); assertEquals(1, port.preparations.size)
            assertEquals(model.state.value.token, port.preparations[0].token)
            port.release(0); runCurrent(); assertTrue(model.state.value.ready)
            assertEquals("B", model.state.value.item?.sourceKey); assertTrue(port.played.isEmpty())
        } finally { fixture.close() }
    }

    @Test fun metadataAfterReadinessPreservesKnownCaptureRateAndRejectsOldItem() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B"); model.load(a, listOf(a, b)); runCurrent()
            port.release(0, MonitorPlaybackMetadata(duration = 100.0)); runCurrent()
            assertTrue(model.state.value.ready); assertEquals(1, port.played.size)
            val old = model.state.value.token; model.setConformTarget(30.0)
            port.onEvent?.invoke(old, MonitorPlaybackEvent.Metadata(MonitorPlaybackMetadata(duration = 80.0, width = 640.0, height = 360.0)))
            assertTrue(model.state.value.ready); assertEquals(640.0, model.state.value.metadata.width); assertEquals(80.0, model.state.value.duration)
            assertEquals(120.0, model.state.value.metadata.conform.captureRate); assertEquals(30.0, model.state.value.conformTarget); assertEquals(0.25, model.rate)
            model.load(b, listOf(a, b), play = false); val current = model.state.value.token
            port.onEvent?.invoke(old, MonitorPlaybackEvent.Metadata(MonitorPlaybackMetadata(duration = 7.0, width = 7.0, height = 7.0)))
            assertEquals(current, model.state.value.token); assertEquals("B", model.state.value.active?.payload)
            assertFalse(model.state.value.ready); assertEquals(100.0, model.state.value.duration)
            runCurrent(); assertEquals(2, port.preparations.size); port.release(1); runCurrent()
            assertEquals("B", model.state.value.item?.sourceKey); assertNull(model.state.value.metadata.width); assertFalse(model.state.value.playRequested)
        } finally { fixture.close() }
    }

    @Test fun refusedFinalSeekCannotResumePausedNativeTransport() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent(); port.release(0); runCurrent()
            assertTrue(model.state.value.ready); assertEquals(1, port.played.size)
            val edit = model.beginScrub()!!; model.updateScrub(30.0, edit); runCurrent()
            assertEquals(1, port.seeks.size); port.finishSeek(0); model.commitScrub(edit); runCurrent()
            assertEquals(2, port.seeks.size); port.finishSeek(1, completed = false); runCurrent()
            assertEquals(1, port.played.size); assertTrue(model.state.value.ready); assertFalse(model.state.value.scrubbing)
        } finally { fixture.close() }
    }

    @Test fun canceledEditCannotUpdateOrCommitNewEditOnSameItem() = runTest {
        val clock = PlaybackTestClock(); val fixture = fixture(backgroundScope, clock = clock)
        val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent(); port.release(0); runCurrent()
            val old = model.beginScrub()!!; model.cancelScrub(false)
            val current = model.beginScrub()!!; model.updateScrub(40.0, current); runCurrent(); port.finishSeek(0)
            clock.instant += 75.milliseconds
            model.updateScrub(7.0, old); model.commitScrub(old); model.cancelScrub(false, old); runCurrent()
            assertTrue(model.state.value.scrubbing); assertEquals(40.0, model.state.value.scrubPosition); assertEquals(1, port.seeks.size)
            model.updateScrub(55.0, current); runCurrent(); assertEquals(2, port.seeks.size); port.finishSeek(1)
            assertTrue(model.state.value.scrubbing); assertEquals(55.0, model.state.value.scrubPosition)
            model.commitScrub(current); runCurrent(); assertEquals(3, port.seeks.size); port.finishSeek(2)
        } finally { fixture.close() }
    }



    @Test fun outgoingBeginCannotAdoptReplacementEditFromNativePause() = runTest {
        val clock = PlaybackTestClock(); val fixture = fixture(backgroundScope, clock = clock)
        val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); model.load(a, listOf(a)); runCurrent(); port.release(0); runCurrent()
            var retired: MonitorPlaybackScrubToken? = null
            var successor: MonitorPlaybackScrubToken? = null
            port.onPause = {
                port.onPause = null
                retired = model.beginScrub()
                model.cancelScrub(false)
                successor = model.beginScrub()
                successor?.let { model.updateScrub(44.0, it) }
            }
            val outgoing = model.beginScrub()
            val kept = assertNotNull(successor); val old = assertNotNull(retired)
            assertNull(outgoing)
            assertNotEquals(old, kept); assertEquals(old.item, kept.item); assertEquals(model.state.value.token, kept.item)
            assertEquals(kept, model.beginScrub()); assertTrue(model.state.value.scrubbing); assertEquals(44.0, model.state.value.scrubPosition)
            runCurrent(); assertEquals(1, port.seeks.size); port.finishSeek(0)
            clock.instant += 75.milliseconds
            model.updateScrub(55.0, kept); runCurrent(); assertEquals(2, port.seeks.size); port.finishSeek(1)
            assertTrue(model.state.value.scrubbing); assertEquals(55.0, model.state.value.scrubPosition)
            model.commitScrub(kept); runCurrent(); assertEquals(3, port.seeks.size); port.finishSeek(2)
        } finally { fixture.close() }
    }
    @Test fun sourceSeekClearancePreservesStrict250msTailAndDefault50msTail() = runTest {
        for (clearance in listOf(0.25, 0.05)) {
            val fixture = fixture(this, seekEndClearance = clearance)
            try {
                val model = fixture.model; val port = fixture.port; val row = record("tail")
                model.load(row, listOf(row)); runCurrent(); port.release(0, MonitorPlaybackMetadata(duration = 10.0)); runCurrent()
                assertTrue(model.state.value.ready); val token = model.state.value.token
                val cases = if (clearance == 0.25) listOf(-0.1 to true, -0.2 to true, -0.25 to true, -0.251 to false)
                    else listOf(-0.025 to true, -0.05 to true, -0.051 to false)
                cases.forEachIndexed { index, (offset, expected) ->
                    port.onEvent?.invoke(token, MonitorPlaybackEvent.Ended); assertTrue(model.state.value.reachedEnd)
                    model.seekBy(offset); assertEquals(expected, model.state.value.reachedEnd)
                    runCurrent(); assertEquals(index + 1, port.seeks.size); port.finishSeek(index); runCurrent()
                }
            } finally { fixture.close() }
        }
    }

    @Test fun sourceScrubClearanceRetainsTailUntilStrictBoundaryAndRejectsRetiredEdit() = runTest {
        val fixture = fixture(this, seekEndClearance = 0.25)
        try {
            val model = fixture.model; val port = fixture.port; val a = record("tail"); val b = record("next")
            model.load(a, listOf(a, b)); runCurrent(); port.release(0, MonitorPlaybackMetadata(duration = 10.0)); runCurrent()
            port.onEvent?.invoke(model.state.value.token, MonitorPlaybackEvent.Ended)
            val edit = assertNotNull(model.beginScrub())
            model.updateScrub(9.8, edit); assertTrue(model.state.value.reachedEnd)
            model.updateScrub(9.75, edit); assertTrue(model.state.value.reachedEnd)
            model.updateScrub(9.749, edit); assertFalse(model.state.value.reachedEnd)
            runCurrent(); assertEquals(1, port.seeks.size); port.finishSeek(0); runCurrent()
            model.load(b, listOf(a, b)); runCurrent(); port.release(1, MonitorPlaybackMetadata(duration = 10.0)); runCurrent()
            port.onEvent?.invoke(model.state.value.token, MonitorPlaybackEvent.Ended)
            model.updateScrub(0.0, edit)
            assertTrue(model.state.value.reachedEnd); assertEquals(b.asset.id, model.state.value.active?.asset?.id)
            assertFalse(model.state.value.scrubbing)
        } finally { fixture.close() }
    }

    @Test fun clearingSceneRequestCancelsInterruptedScrubWithoutAutomaticResume() = runTest {
        val fixture = fixture(backgroundScope, sceneLossPolicy = MonitorPlaybackSceneLossPolicy.CLEAR_REQUEST)
        val model = fixture.model; val port = fixture.port
        try {
            val row = record("scene")
            model.load(row, listOf(row)); runCurrent(); port.release(0); runCurrent()
            assertTrue(model.state.value.ready); assertEquals(1, port.played.size)
            val item = model.state.value.token; val edit = assertNotNull(model.beginScrub())
            model.updateScrub(30.0, edit); runCurrent(); assertEquals(1, port.seeks.size)
            model.cancelScrub(true); model.setSceneActive(false); port.finishSeek(0); runCurrent()
            model.setSceneActive(true)
            assertTrue(model.state.value.ready); assertEquals(item, model.state.value.token)
            assertFalse(model.state.value.scrubbing); assertFalse(model.state.value.playRequested)
            assertEquals(listOf(item), port.played); assertEquals(0, port.closes)
            assertTrue(fixture.library.state.value.browsing)
            model.setPlaying(true)
            assertTrue(model.state.value.playRequested); assertEquals(listOf(item, item), port.played)
        } finally { fixture.close() }
    }

    @Test fun clearingSceneRequestCannotClearReplacementFromStatePublication() = runTest {
        val fixture = fixture(backgroundScope, sceneLossPolicy = MonitorPlaybackSceneLossPolicy.CLEAR_REQUEST)
        val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B")
            model.load(a, listOf(a, b)); runCurrent(); port.release(0); runCurrent()
            val old = model.state.value.token; var replaced = false
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                model.state.collect {
                    if (!replaced && it.active?.payload == "A" && !it.playRequested) {
                        replaced = true; model.load(b, listOf(a, b), play = true)
                    }
                }
            }
            model.setSceneActive(false)
            assertEquals("B", model.state.value.active?.payload); assertTrue(model.state.value.playRequested)
            assertNotEquals(old, model.state.value.token)
            runCurrent(); assertEquals(2, port.preparations.size); port.release(1); runCurrent()
            val current = model.state.value.token; assertEquals(listOf(old), port.played)
            model.setSceneActive(true)
            assertTrue(model.state.value.playRequested); assertEquals(listOf(old, current), port.played)
            assertFalse(model.state.value.closed)
        } finally { fixture.close() }
    }

    @Test fun outgoingSceneLossCannotBorrowReplacementFromSourcePredicate() = runTest {
        val fixture = fixture(backgroundScope, sceneLossPolicy = MonitorPlaybackSceneLossPolicy.CLEAR_REQUEST)
        val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B"); var replace = false
            model.setItemAdmission { row -> MonitorPlaybackAdmission {
                if (row.payload == "A" && replace) {
                    replace = false; model.load(b, listOf(a, b), play = true)
                }
                true
            } }
            model.load(a, listOf(a, b)); runCurrent(); port.release(0); runCurrent()
            val old = model.state.value.token
            replace = true; model.setSceneActive(false)
            assertEquals("B", model.state.value.active?.payload); assertTrue(model.state.value.playRequested)
            assertNotEquals(old, model.state.value.token)
            runCurrent(); assertEquals(2, port.preparations.size); port.release(1); runCurrent()
            assertTrue(model.state.value.ready); assertEquals(listOf(old, model.state.value.token), port.played)
            assertFalse(model.state.value.closed); assertTrue(fixture.library.state.value.browsing)
        } finally { fixture.close() }
    }

    @Test fun waitingTransportKeepsPauseAvailableWithoutClaimingPlayingOrAdvancingTime() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val row = record("waiting"); model.load(row, listOf(row)); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token; assertTrue(model.state.value.ready); assertEquals(listOf(item), port.played)
            port.onEvent?.invoke(item, MonitorPlaybackEvent.Position(42.0))
            port.onEvent?.invoke(item, MonitorPlaybackEvent.Transport(MonitorPlaybackTransportState.WAITING))
            assertEquals(MonitorPlaybackTransportState.WAITING, model.state.value.reportedTransport)
            assertEquals(false, model.state.value.reportedPlaying); assertTrue(model.state.value.playRequested)
            assertTrue(model.state.value.canPause); assertEquals(42.0, model.state.value.position)
            model.togglePlaying(); assertFalse(model.state.value.playRequested); assertEquals(listOf(item), port.played)
            assertEquals(42.0, model.state.value.position); assertEquals(item, model.state.value.token); assertTrue(model.state.value.ready)
        } finally { fixture.close() }
    }

    @Test fun waitingTransportScrubRetainsRequestedResumeAfterNativeSeek() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val row = record("waiting-scrub"); model.load(row, listOf(row)); runCurrent(); port.release(0); runCurrent()
            val item = model.state.value.token; assertTrue(model.state.value.ready); assertEquals(listOf(item), port.played)
            port.onEvent?.invoke(item, MonitorPlaybackEvent.Transport(MonitorPlaybackTransportState.WAITING))
            val edit = model.beginScrub(); assertNotNull(edit); model.commitScrub(edit!!); runCurrent()
            assertEquals(1, port.seeks.size); port.finishSeek(0); runCurrent()
            assertTrue(model.state.value.playRequested); assertEquals(listOf(item, item), port.played); assertFalse(model.state.value.scrubbing)
        } finally { fixture.close() }
    }

    @Test fun retiredTransportReportCannotChangeSuccessorIntentOrObservation() = runTest {
        val fixture = fixture(backgroundScope); val model = fixture.model; val port = fixture.port
        try {
            val a = record("A"); val b = record("B"); model.load(a, listOf(a, b)); runCurrent(); port.release(0); runCurrent()
            val old = model.state.value.token
            port.onEvent?.invoke(old, MonitorPlaybackEvent.Transport(MonitorPlaybackTransportState.WAITING))
            model.load(b, listOf(a, b), play = false); runCurrent(); port.release(1); runCurrent()
            port.onEvent?.invoke(old, MonitorPlaybackEvent.Transport(MonitorPlaybackTransportState.PLAYING))
            assertNull(model.state.value.reportedTransport); assertNull(model.state.value.reportedPlaying); assertFalse(model.state.value.playRequested)
            port.onEvent?.invoke(model.state.value.token, MonitorPlaybackEvent.Transport(MonitorPlaybackTransportState.PAUSED))
            assertEquals(MonitorPlaybackTransportState.PAUSED, model.state.value.reportedTransport)
            assertEquals(false, model.state.value.reportedPlaying); assertFalse(model.state.value.canPause)
            port.onEvent?.invoke(model.state.value.token, MonitorPlaybackEvent.Transport(null))
            assertNull(model.state.value.reportedTransport); assertNull(model.state.value.reportedPlaying); assertFalse(model.state.value.canPause)
        } finally { fixture.close() }
    }

}
