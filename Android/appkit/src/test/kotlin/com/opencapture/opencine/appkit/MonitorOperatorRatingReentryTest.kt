package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import java.net.URI
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.*
import kotlin.time.Duration

private class RatingReentryCodec(val record: MonitorMediaRecord<String>) : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray) = listOf(record)
    override fun encode(records: List<MonitorMediaRecord<String>>) = byteArrayOf(1)
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}
private class RatingReentryFavorites : MonitorMediaFavoritesStore {
    override fun favorites() = emptySet<String>()
    override fun saveFavorites(keys: Set<String>) {}
}
private class RatingReentryPort : MonitorPlaybackPort {
    override var onEvent: ((MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Unit)? = null
    override fun retireItem(token: MonitorPlaybackItemToken) {}
    override suspend fun prepare(item: MonitorPlaybackItem, token: MonitorPlaybackItemToken,
        readyTimeout: Duration?): MonitorPlaybackMetadata {
        onEvent?.invoke(token, MonitorPlaybackEvent.ItemInstalled)
        return MonitorPlaybackMetadata(duration = 8.0)
    }
    override fun play(rate: Double, token: MonitorPlaybackItemToken) {}
    override fun pause(token: MonitorPlaybackItemToken) {}
    override suspend fun seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) = true
    override fun setMuted(muted: Boolean, token: MonitorPlaybackItemToken) {}
    override fun close(token: MonitorPlaybackItemToken) {}
}
private class RatingReentryFixture(scope: CoroutineScope) {
    val root = Files.createTempDirectory("opencine-rating-reentry-").toFile()
    val record = MonitorMediaRecord(MediaAsset(MediaAssetID("A"), filename = "A.mov", kind = MediaAssetKind.VIDEO,
        representations = emptyList(), deletable = true), "A", MonitorMediaCacheAddress(null, emptyMap(), "A"))
    val directory = MonitorMediaCacheDirectory(root).also { it.write(byteArrayOf(1), "index.json") }
    val library = MonitorMediaLibraryModel(MonitorMediaCache(directory, RatingReentryCodec(record),
        MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")),
        RatingReentryFavorites(), scope = scope).also {
        it.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS); it.begin()
    }
    val successor = CompletableDeferred<Unit>()
    var successorEntered = false
    val clocks = mutableListOf<CompletableDeferred<Unit>>()
    var reads = 0
    val writes = mutableListOf<Int>()
    var completion: MonitorMediaPictureRatingResult = MonitorMediaPictureRatingResult.Refused("Outgoing refusal")
    var afterCommit: (() -> Unit)? = null
    var onPredicate: (() -> Boolean)? = null
    val service = MonitorMediaPlaybackRatingService<String>(listOf(1, 2, 3, 4), read = { reads += 1; 2 },
        commit = { target, _ ->
            writes += target
            when (target) {
                1 -> MonitorMediaPictureRatingResult.Refused("Existing notice")
                4 -> {
                    successorEntered = true
                    withContext(NonCancellable) { successor.await() }
                    MonitorMediaPictureRatingResult.Confirmed(4)
                }
                else -> { afterCommit?.invoke(); completion }
            }
        }, unavailableMessage = "Outgoing unavailable")
    val model = MonitorOperatorMediaModel<String, String>(library, scope, recordAdmission = {
        MonitorPlaybackAdmission { onPredicate?.invoke() ?: true }
    }, sleep = { duration ->
        assertEquals(4_000L, duration)
        val gate = CompletableDeferred<Unit>(); clocks += gate
        withContext(NonCancellable) { gate.await() }
    }, makePlayback = { owner ->
        MonitorMediaPlaybackModel<String, String>(owner, RatingReentryPort(), scope, candidates = {
            listOf(MonitorPlaybackCandidate.Cached(MonitorPlaybackItem(URI("file:/${it.payload}.mov"), "video/mp4", it.payload)))
        })
    })
    fun open() = model.open(record, listOf(record), library.actionToken)
    fun close() {
        onPredicate = null; afterCommit = null
        model.closePlayback(); library.close()
        successor.complete(Unit); clocks.forEach { it.complete(Unit) }; root.deleteRecursively()
    }
    fun replaceRating(condition: () -> Boolean = { true }, reply: Boolean) {
        onPredicate = {
            if (!condition()) true else {
                onPredicate = null
                model.setRating(4, service)
                reply
            }
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorOperatorRatingReentryTest {
    @Test fun predicateReplacementDuringRequestCannotStartOldRating() = runTest {
        for (reply in listOf(false, true)) {
            val f = RatingReentryFixture(backgroundScope)
            try {
                assertTrue(f.open()); val token = assertNotNull(f.model.state.value.playback).state.value.token
                f.replaceRating(reply = reply); f.model.setRating(3, f.service); runCurrent()
                assertTrue(f.successorEntered)
                assertEquals(listOf(4), f.writes); assertEquals(4, f.model.state.value.ratingStars)
                assertTrue(f.model.state.value.ratingPending); assertTrue(f.clocks.isEmpty())
                assertEquals(token, f.model.state.value.playback?.state?.value?.token)
                f.successor.complete(Unit); runCurrent()
                assertFalse(f.model.state.value.ratingPending); assertEquals(4, f.model.state.value.ratingStars)
            } finally { f.close() }
        }
    }
    @Test fun predicateReplacementDuringReadRequestCannotPublishOldRating() = runTest {
        for (reply in listOf(false, true)) {
            val f = RatingReentryFixture(backgroundScope)
            try {
                assertTrue(f.open()); f.replaceRating(reply = reply); f.model.readRating(f.service); runCurrent()
                assertTrue(f.successorEntered); assertEquals(0, f.reads); assertEquals(listOf(4), f.writes)
                assertEquals(4, f.model.state.value.ratingStars); assertTrue(f.model.state.value.ratingPending)
            } finally { f.close() }
        }
    }
    @Test fun predicateReplacementDuringCompletionPreservesSameItemSuccessor() = runTest {
        val outcomes = listOf(MonitorMediaPictureRatingResult.Confirmed(2),
            MonitorMediaPictureRatingResult.Refused("Outgoing refusal"), MonitorMediaPictureRatingResult.Unavailable)
        for (outcome in outcomes) for (reply in listOf(false, true)) {
            val f = RatingReentryFixture(backgroundScope)
            try {
                assertTrue(f.open()); f.model.readRating(f.service); runCurrent(); assertEquals(2, f.model.state.value.ratingStars)
                f.model.setRating(1, f.service); runCurrent(); assertEquals(1, f.clocks.size)
                val token = assertNotNull(f.model.state.value.playback).state.value.token
                f.completion = outcome
                f.afterCommit = { f.replaceRating(condition = { f.model.state.value.ratingStars == 2 }, reply = reply) }
                f.model.setRating(3, f.service); runCurrent()
                assertTrue(f.successorEntered); assertEquals(listOf(1, 3, 4), f.writes)
                assertEquals(token, f.model.state.value.playback?.state?.value?.token)
                assertEquals(4, f.model.state.value.ratingStars); assertTrue(f.model.state.value.ratingPending)
                assertEquals("Existing notice", f.model.state.value.ratingNotice); assertEquals(1, f.clocks.size)
                f.successor.complete(Unit); runCurrent()
                assertFalse(f.model.state.value.ratingPending); assertEquals(4, f.model.state.value.ratingStars)
                assertNull(f.model.state.value.ratingNotice)
            } finally { f.close() }
        }
    }
    @Test fun predicateReplacementDuringNoticeCreationCannotPublishOldNotice() = runTest {
        for (reply in listOf(false, true)) {
            val f = RatingReentryFixture(backgroundScope)
            try {
                assertTrue(f.open()); f.model.readRating(f.service); runCurrent()
                f.model.setRating(1, f.service); runCurrent(); assertEquals(1, f.clocks.size)
                f.afterCommit = { f.replaceRating(condition = { f.model.state.value.ratingNotice == null }, reply = reply) }
                f.model.setRating(3, f.service); runCurrent()
                assertTrue(f.successorEntered); assertEquals(4, f.model.state.value.ratingStars)
                assertTrue(f.model.state.value.ratingPending); assertNull(f.model.state.value.ratingNotice)
                assertEquals(1, f.clocks.size)
            } finally { f.close() }
        }
    }
    @Test fun predicateReplacementDuringNoticeExpiryCannotClearSuccessor() = runTest {
        for (reply in listOf(false, true)) {
            val f = RatingReentryFixture(backgroundScope)
            try {
                assertTrue(f.open()); f.model.readRating(f.service); runCurrent()
                f.model.setRating(1, f.service); runCurrent(); assertEquals(1, f.clocks.size)
                f.replaceRating(reply = reply); f.clocks[0].complete(Unit); runCurrent()
                assertTrue(f.successorEntered); assertEquals("Existing notice", f.model.state.value.ratingNotice)
                assertEquals(4, f.model.state.value.ratingStars); assertTrue(f.model.state.value.ratingPending)
                assertEquals(1, f.clocks.size); assertEquals(listOf(1, 4), f.writes)
            } finally { f.close() }
        }
    }
    @Test fun noticePublicationReplacementCannotScheduleOldExpiry() = runTest {
        val f = RatingReentryFixture(backgroundScope)
        try {
            assertTrue(f.open()); f.model.readRating(f.service); runCurrent()
            f.model.setRating(1, f.service); runCurrent(); assertEquals(1, f.clocks.size)
            var publicationArmed = false
            val observer = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
                f.model.state.collect { state ->
                    if (publicationArmed && state.ratingNotice == "Outgoing refusal") {
                        publicationArmed = false; f.model.setRating(4, f.service)
                    }
                }
            }
            publicationArmed = true; f.model.setRating(3, f.service); runCurrent(); observer.cancel()
            assertTrue(f.successorEntered); assertEquals("Outgoing refusal", f.model.state.value.ratingNotice)
            assertEquals(4, f.model.state.value.ratingStars); assertTrue(f.model.state.value.ratingPending)
            assertEquals(1, f.clocks.size); assertEquals(listOf(1, 3, 4), f.writes)
        } finally { f.close() }
    }
    @Test fun currentRatingAndManualNoticeExpiryKeepOriginalBehavior() = runTest {
        val f = RatingReentryFixture(backgroundScope)
        try {
            assertTrue(f.open()); f.model.readRating(f.service); runCurrent()
            f.model.setRating(1, f.service); runCurrent(); assertEquals(1, f.clocks.size)
            assertEquals("Existing notice", f.model.state.value.ratingNotice)
            f.clocks[0].complete(Unit); runCurrent(); assertNull(f.model.state.value.ratingNotice)
            f.completion = MonitorMediaPictureRatingResult.Confirmed(3)
            f.model.setRating(3, f.service); runCurrent()
            assertFalse(f.model.state.value.ratingPending); assertEquals(3, f.model.state.value.ratingStars)
            assertNull(f.model.state.value.ratingNotice); assertEquals(listOf(1, 3), f.writes)
        } finally { f.close() }
    }
}
