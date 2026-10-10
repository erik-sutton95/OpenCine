package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.media.*
import java.net.URI
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

// SIMULATED: manual-clock source reentry through the actual shared playback owner.
private class SourceReentryCodec(val records: List<MonitorMediaRecord<String>>) : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray) = records
    override fun encode(records: List<MonitorMediaRecord<String>>) = byteArrayOf(1)
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}
private class SourceReentryFavorites : MonitorMediaFavoritesStore {
    override fun favorites() = emptySet<String>()
    override fun saveFavorites(keys: Set<String>) {}
}
private class SourceReentryPort : MonitorPlaybackPort {
    override var onEvent: ((MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Unit)? = null
    val prepared = mutableListOf<MonitorPlaybackItemToken>()
    val closed = mutableListOf<MonitorPlaybackItemToken>()
    override fun retireItem(token: MonitorPlaybackItemToken) {}
    override suspend fun prepare(item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
        readyTimeout: Duration?): MonitorPlaybackMetadata {
        prepared += token
        onEvent?.invoke(token, MonitorPlaybackEvent.ItemInstalled)
        return MonitorPlaybackMetadata(duration = 8.0, conform = MonitorConformPreview.Source(captureRate = 60.0))
    }
    override fun play(rate: Double, token: MonitorPlaybackItemToken) {}
    override fun pause(token: MonitorPlaybackItemToken) {}
    override suspend fun seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) = true
    override fun setMuted(muted: Boolean, token: MonitorPlaybackItemToken) {}
    override fun close(token: MonitorPlaybackItemToken) { closed += token }
}

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class MonitorPlaybackSourcePredicateReentryTest {
    private class Fixture(scope: CoroutineScope) {
        val root = Files.createTempDirectory("opencine-playback-source-reentry-").toFile()
        val records = listOf("A", "B").map { id -> MonitorMediaRecord(
            MediaAsset(MediaAssetID(id), filename = "$id.mov", kind = MediaAssetKind.VIDEO,
                representations = emptyList(), deletable = true), id,
            MonitorMediaCacheAddress(null, emptyMap(), id)) }
        val directory = MonitorMediaCacheDirectory(root).also { it.write(byteArrayOf(1), "index.json") }
        val library = MonitorMediaLibraryModel(MonitorMediaCache(directory, SourceReentryCodec(records),
            MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")),
            SourceReentryFavorites(), scope = scope).also {
            it.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS); it.begin()
        }
        val port = SourceReentryPort()
        var instant = MonotonicInstant(100.seconds)
        var predicate: ((String) -> Boolean)? = null
        var replacementArmed = false
        var replacementReply = true
        var replacementCalls = 0
        var refusalCalls = 0
        val model = MonitorMediaPlaybackModel<String, String>(library, port, scope,
            candidates = { listOf(MonitorPlaybackCandidate.Cached(MonitorPlaybackItem(
                URI("file:/${it.payload}.mov"), "video/mp4", it.payload))) }, now = { instant }).also { owner ->
            owner.setItemAdmission { record -> MonitorPlaybackAdmission { predicate?.invoke(record.payload) ?: true } }
        }
        fun loadFirst() { model.load(records[0], records, play = false) }
        fun armReplacement(returning: Boolean) {
            replacementArmed = true; replacementReply = returning
            predicate = { payload ->
                if (payload == "A" && replacementArmed) {
                    replacementArmed = false; replacementCalls += 1
                    model.load(records[1], records, play = false)
                    replacementReply
                } else true
            }
        }
        fun close() { model.close(); library.close(); root.deleteRecursively() }
    }

    @Test fun predicateReplacementRejectsFalseAndTrueNativePosition() = runTest {
        for (reply in listOf(false, true)) {
            val f = Fixture(backgroundScope)
            try {
                f.loadFirst(); runCurrent(); assertTrue(f.model.state.value.ready)
                val old = f.model.state.value.token
                f.armReplacement(reply); f.port.onEvent?.invoke(old, MonitorPlaybackEvent.Position(42.0))
                val next = f.model.state.value
                assertEquals(1, f.replacementCalls); assertNotEquals(old, next.token); assertEquals("B", next.active?.payload)
                assertEquals(0.0, next.position); assertFalse(next.closed); assertTrue(f.port.closed.isEmpty())
                runCurrent(); assertTrue(f.model.state.value.ready)
                f.port.onEvent?.invoke(old, MonitorPlaybackEvent.Position(55.0))
                assertEquals(0.0, f.model.state.value.position); assertTrue(f.library.state.value.browsing)
            } finally { f.close() }
        }
    }

    @Test fun predicateReplacementRejectsFalseAndTrueNativeFailure() = runTest {
        for (reply in listOf(false, true)) {
            val f = Fixture(backgroundScope)
            try {
                f.loadFirst(); runCurrent(); assertTrue(f.model.state.value.ready)
                val old = f.model.state.value.token
                f.armReplacement(reply); f.port.onEvent?.invoke(old, MonitorPlaybackEvent.Failed("retired item"))
                val next = f.model.state.value
                assertNotEquals(old, next.token); assertEquals("B", next.active?.payload)
                assertNull(next.error); assertTrue(next.loading); assertFalse(next.closed); assertTrue(f.port.closed.isEmpty())
                runCurrent(); assertNull(f.model.state.value.error); assertTrue(f.model.state.value.ready)
            } finally { f.close() }
        }
    }

    @Test fun predicateReplacementCannotApplyOldLoopMutation() = runTest {
        for (reply in listOf(false, true)) {
            val f = Fixture(backgroundScope)
            try {
                f.loadFirst(); runCurrent(); assertTrue(f.model.state.value.ready)
                val old = f.model.state.value.token
                f.armReplacement(reply); f.model.setLooping(true)
                val next = f.model.state.value
                assertNotEquals(old, next.token); assertEquals("B", next.active?.payload)
                assertFalse(next.looping); assertFalse(next.closed); assertTrue(f.port.closed.isEmpty())
            } finally { f.close() }
        }
    }

    @Test fun predicateReplacementCannotApplyOldMutedMutation() = runTest {
        for (reply in listOf(false, true)) {
            val f = Fixture(backgroundScope)
            try {
                f.loadFirst(); runCurrent(); assertTrue(f.model.state.value.ready)
                val old = f.model.state.value.token
                f.armReplacement(reply); f.model.setMuted(true)
                val next = f.model.state.value
                assertNotEquals(old, next.token); assertEquals("B", next.active?.payload)
                assertFalse(next.muted); assertFalse(next.closed); assertTrue(f.port.closed.isEmpty())
            } finally { f.close() }
        }
    }

    @Test fun refusalDoesNotReevaluateIntoAndCloseSuccessor() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.loadFirst(); runCurrent(); assertTrue(f.model.state.value.ready)
            val old = f.model.state.value.token
            f.predicate = { payload ->
                if (payload != "A") true else {
                    f.refusalCalls += 1
                    when (f.refusalCalls) {
                        1 -> false
                        2 -> { f.model.load(f.records[1], f.records, play = false); false }
                        else -> true
                    }
                }
            }
            f.model.setLooping(true)
            val next = f.model.state.value
            assertEquals(1, f.refusalCalls); assertEquals("A", next.active?.payload); assertTrue(next.closed)
            assertFalse(next.looping); assertEquals(old.owner, next.token.owner); assertEquals(old.revision + 1, next.token.revision)
            assertEquals(listOf(next.token), f.port.closed); assertEquals(listOf(old), f.port.prepared)
            assertTrue(f.library.state.value.browsing)
        } finally { f.close() }
    }

    @Test fun sameCurrentPredicateAllowsPositionAndLoop() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.loadFirst(); runCurrent(); assertTrue(f.model.state.value.ready)
            val token = f.model.state.value.token
            f.predicate = { true }; f.port.onEvent?.invoke(token, MonitorPlaybackEvent.Position(3.0)); f.model.setLooping(true)
            val next = f.model.state.value
            assertEquals(3.0, next.position); assertTrue(next.looping); assertEquals(token, next.token)
            assertFalse(next.closed); assertTrue(f.port.closed.isEmpty())
        } finally { f.close() }
    }

    @Test fun sameCurrentRefusalClosesOnlyCapturedOwner() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.loadFirst(); runCurrent(); assertTrue(f.model.state.value.ready)
            val old = f.model.state.value.token
            f.predicate = { false }; f.port.onEvent?.invoke(old, MonitorPlaybackEvent.Position(4.0))
            val next = f.model.state.value
            assertTrue(next.closed); assertEquals(0.0, next.position); assertEquals("A", next.active?.payload)
            assertEquals(old.owner, next.token.owner); assertEquals(old.revision + 1, next.token.revision)
            assertEquals(listOf(next.token), f.port.closed); assertTrue(f.library.state.value.browsing)
        } finally { f.close() }
    }
}
