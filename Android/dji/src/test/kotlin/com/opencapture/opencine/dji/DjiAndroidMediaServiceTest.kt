package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlin.test.*
import com.opencapture.opencine.vocabulary.MediaFile

/** Actual producer/parser plus manual clock. No Android Looper, native SDK or wall-clock sleep. */
class DjiAndroidMediaServiceTest {
    private fun fixture() = javaClass.classLoader!!.getResourceAsStream("dji-media/nano-manifest.bin")!!.readBytes()
    private fun frame(set: Int, command: Int, payload: ByteArray) = DumlFrame(0, 0, 0, 0, set, command, payload)
    private fun chunk(counter: Int, subtype: Int, bytes: ByteArray = byteArrayOf()) = frame(
        MediaCommands.SET_GENERAL, MediaCommands.CMD_MEDIA_CHUNK,
        byteArrayOf(0x4A, subtype.toByte(), 0, 0, counter.toByte(), 0, 0, 0, 0, 0) + bytes)

    private inner class Peer(val scope: CoroutineScope, val manifest: ByteArray = fixture()) : DjiAndroidMediaPort {
        var identity = DjiAndroidMediaIdentity(CameraSessionID(), ControlEpoch(1), "actual-camera")
        var queryAvailable = true; var galleryOpen = false; var playback = false; var factsKnown = true
        var answer = true; var enterAccepted = true; var freshPicture = false
        var enters = 0; var exits = 0; var enables = 0; var returns = 0; var now = 0L
        var returnCurrent = true
        var receiveEpoch = 1L; var endpointClosed = false; var statusFrames = 0
        var slot = DjiAndroidMediaIngressSlot()
        var delayHook: (suspend (Long) -> Unit)? = null
        var writeHook: (() -> Unit)? = null
        val writes = mutableListOf<Pair<Int, ByteArray>>()
        val browseChanges = mutableListOf<Boolean>(); val wire = mutableListOf<Boolean>()
        val service = DjiAndroidMediaService(identity.session, this,
            DjiAndroidMediaTiming({ now }) { ms -> now += ms; delayHook?.invoke(ms) }, slot)
        override val mediaFacts get() = if (factsKnown) DjiAndroidMediaFacts(identity, queryAvailable, galleryOpen, playback) else null
        override fun mediaBrowseChanged(active: Boolean, source: DjiAndroidMediaIdentity) {
            browseChanges.add(active)
            if (active) returnCurrent = false else returnCurrent = true
        }
        override fun setMediaWireHeld(held: Boolean, source: DjiAndroidMediaIdentity) { wire.add(held) }
        fun deliver(frame: DumlFrame): Boolean {
            val admitted = slot.capture() != null
            DjiAndroidMediaReceiveBatch.capture(listOf(frame), slot, receiveEpoch)
                .deliver({ receiveEpoch }, { endpointClosed }) { statusFrames += 1 }
            return admitted
        }
        override fun enterMediaPlayback(source: DjiAndroidMediaIdentity) {
            enters += 1
            if (enterAccepted) {
                playback = true
                deliver(frame(MediaCommands.SET_CAMERA, MediaCommands.CMD_PLAYBACK, byteArrayOf(0)))
            }
        }
        override fun writeMedia(set: Int, command: Int, payload: ByteArray, source: DjiAndroidMediaIdentity) {
            assertEquals(identity, source)
            writes.add(command to payload.copyOf())
            writeHook?.invoke()
            if (!answer || payload.size != MediaListCommand.listTemplate.size) return
            val counter = payload[4].toInt() and 0xff
            deliver(chunk(counter, 4))
            if (counter == MediaListCommand.SD_COUNTER && manifest.isNotEmpty()) deliver(chunk(counter, 1, manifest))
            deliver(chunk(counter, 3))
        }
        override fun claimMediaReturn(source: DjiAndroidMediaIdentity, operation: suspend (DjiAndroidMediaReturnAuthority) -> Unit) =
            scope.async(start = CoroutineStart.UNDISPATCHED) {
                returns += 1
                operation(DjiAndroidMediaReturnAuthority(
                    isCurrent = { returnCurrent && identity.sameConnection(source) },
                    inPlayback = { playback }, pictureFresh = { freshPicture },
                    writeExit = {
                        exits += 1; playback = false
                        deliver(frame(MediaCommands.SET_CAMERA, MediaCommands.CMD_PLAYBACK, byteArrayOf(0)))
                    }, enableLiveView = { enables += 1; freshPicture = true; true },
                    completed = { assertEquals(MediaLiveResumeRunner.Result.RESTORED, it) }))
            }
    }

    @Test fun catalogMutationUsesOnlyTheCapturedSourceHandlesAndOriginalWireBytes() = runTest {
        val peer = Peer(this)
        val browse = peer.service.openBrowse()
        val delta = browse.catalog().next()!!
        val asset = delta.upserts.first { peer.service.mediaCatalogRecord(it.id, browse.binding)?.file?.isDeletable == true }
        val file = peer.service.mediaCatalogRecord(asset.id, browse.binding)!!.file
        val start = peer.writes.size
        val favorite = assertNotNull(peer.service.submitFavorite(asset.id, true, browse.binding))
        val deletion = assertNotNull(peer.service.submitDeletion(asset.id, browse.binding))
        assertContentEquals(MediaCommands.favoritePayload(file.favoriteHandle, true, 1), peer.writes[start].second)
        assertEquals(MediaCommands.CMD_MEDIA_FAVORITE, peer.writes[start].first)
        assertContentEquals(MediaCommands.deletePayload(file.handle, 2), peer.writes[start + 1].second)
        assertEquals(MediaCommands.CMD_MEDIA_DELETE, peer.writes[start + 1].first)
        assertTrue(peer.service.isCurrent(favorite)); assertTrue(peer.service.isCurrent(deletion))
        assertNotNull(peer.service.mediaCatalogRecord(asset.id, browse.binding), "A write is not a camera deletion acknowledgement")
        peer.service.retire()
    }
    @Test fun mutationsRejectUnknownAssetsRetiredBrowsesAndAReplacementConnectionBeforeWriting() = runTest {
        val peer = Peer(this)
        val browse = peer.service.openBrowse()
        val asset = browse.catalog().next()!!.upserts.first()
        val before = peer.writes.size
        assertNull(peer.service.submitFavorite(MediaAssetID("unknown"), true, browse.binding))
        assertNull(peer.service.submitDeletion(MediaAssetID("unknown"), browse.binding))
        peer.identity = peer.identity.copy(epoch = ControlEpoch(2))
        assertNull(peer.service.submitFavorite(asset.id, true, browse.binding))
        assertNull(peer.service.submitDeletion(asset.id, browse.binding))
        assertEquals(before, peer.writes.size)
        peer.service.retire()
        assertNull(peer.service.submitDeletion(asset.id, browse.binding))
    }
    @Test fun reentrantRetirementAfterAWriteCannotAuthorizeOptimisticLocalDeletion() = runTest {
        val peer = Peer(this)
        val browse = peer.service.openBrowse()
        val asset = browse.catalog().next()!!.upserts.first { peer.service.mediaCatalogRecord(it.id, browse.binding)?.file?.isDeletable == true }
        val before = peer.writes.size
        peer.writeHook = { peer.service.retire() }
        assertNull(peer.service.submitDeletion(asset.id, browse.binding))
        assertEquals(before + 1, peer.writes.size)
        assertNull(peer.service.submitFavorite(asset.id, false, browse.binding))
        assertEquals(before + 1, peer.writes.size)
    }
    @Test fun submissionExpiresWhenTheSameCameraReconnectsOrBrowseCloses() = runTest {
        val peer = Peer(this)
        val browse = peer.service.openBrowse()
        val asset = browse.catalog().next()!!.upserts.first { peer.service.mediaCatalogRecord(it.id, browse.binding)?.file?.favoriteHandle != 0L }
        val submission = assertNotNull(peer.service.submitFavorite(asset.id, false, browse.binding))
        assertTrue(peer.service.isCurrent(submission))
        peer.identity = peer.identity.copy(epoch = ControlEpoch(2))
        assertFalse(peer.service.isCurrent(submission))
        peer.identity = submission.source
        browse.close()
        assertFalse(peer.service.isCurrent(submission))
        peer.service.retire()
    }

    @Test fun actualManifestCatalogRetainsSourceRecordsAndWireQueries() = runTest {
        val peer = Peer(this)
        val browse = peer.service.openBrowse()
        val delta = browse.catalog().next()!!
        assertTrue(delta.reset)
        assertTrue(delta.upserts.isNotEmpty())
        assertNull(delta.volumes)
        assertNull(browse.thumbnails); assertNull(browse.transfers); assertNull(browse.deletion)
        val assembler = MediaChunkAssembler()
        assembler.ingest(chunk(1, 1, fixture()))
        val actual = MediaManifest.decodeStores(assembler)
        assertEquals(actual.map(DjiAndroidMediaAssets::asset), delta.upserts)
        delta.upserts.zip(actual).forEach { (asset, file) ->
            assertEquals(file, peer.service.mediaCatalogRecord(asset.id, browse.binding)?.file)
        }
        assertContentEquals(MediaListCommand.listPayload(1, MediaListCommand.NEWEST_SD), peer.writes.first().second)
        assertTrue(peer.writes.any { it.second.contentEquals(MediaListCommand.triggerPayload) })
        assertTrue(peer.writes.any { it.second.contentEquals(MediaListCommand.listPayload(2, MediaListCommand.NEWEST_INTERNAL)) })
        peer.service.retire()
    }
    @Test fun unknownNoResponseIsUnavailableRatherThanEmptyReset() = runTest {
        val peer = Peer(this); peer.answer = false
        val browse = peer.service.openBrowse()
        val error = assertFailsWith<MediaServiceException> { browse.catalog().next() }
        assertEquals(MediaServiceFailure.UNAVAILABLE, error.failure)
        assertEquals(2, peer.writes.count { it.second.size == MediaListCommand.listTemplate.size && it.second[4] == 1.toByte() })
        assertNull(peer.slot.capture())
        peer.service.retire()
    }
    @Test fun explicitEmptyStoreResponsePublishesKnownEmptyCatalog() = runTest {
        val peer = Peer(this, byteArrayOf())
        val browse = peer.service.openBrowse()
        val delta = browse.catalog().next()!!
        assertTrue(delta.reset); assertTrue(delta.complete); assertTrue(delta.upserts.isEmpty())
        peer.service.retire()
    }
    @Test fun cameraGalleryRefusesEntryAndQueryButCloseKeepsRealReturnPolicy() = runTest {
        val peer = Peer(this); peer.galleryOpen = true; peer.playback = true
        val browse = peer.service.openBrowse()
        assertNull(browse.catalog().next())
        // PAB-M-14: the gallery says the camera holds its own gallery instead of "No clips".
        assertEquals(true, browse.heldBySource)
        assertEquals(0, peer.enters); assertTrue(peer.writes.isEmpty())
        browse.close(); browse.close()
        assertEquals(1, peer.returns); assertEquals(1, peer.exits); assertEquals(1, peer.enables)
        assertEquals(listOf(true, false), peer.browseChanges)
    }
    @Test fun failedEntryRetainsNewestOnlyListingAndOriginalThreeAttemptTiming() = runTest {
        val peer = Peer(this); peer.enterAccepted = false
        val browse = peer.service.openBrowse()
        assertEquals(3, peer.enters); assertEquals(3_120L, peer.now)
        assertEquals(listOf(true, false), peer.wire)
        val cursor = browse.catalog()
        assertTrue(cursor.next()!!.complete)
        assertNull(cursor.next())
        assertEquals(1, peer.writes.count { it.second.size == MediaListCommand.listTemplate.size && it.second[4] == 1.toByte() })
        peer.service.retire()
    }
    @Test fun rawIngressCapturedBeforeQueueCannotEnterSuccessorCursor() = runTest {
        val peer = Peer(this)
        val browse = peer.service.openBrowse()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var captured: DjiAndroidMediaIngress? = null
        peer.delayHook = { if (!entered.isCompleted) { captured = peer.slot.capture(); entered.complete(Unit); release.await() } }
        val oldCursor = browse.catalog(); val old = async { runCatching { oldCursor.next() } }
        entered.await(); val ticket = captured!!
        oldCursor.close()
        val successor = browse.catalog()
        peer.delayHook = null
        assertFalse(peer.service.ingest(chunk(1, 1, fixture()), ticket))
        assertTrue(successor.next()!!.upserts.isNotEmpty())
        release.complete(Unit); old.await()
        assertNull(peer.slot.capture())
        peer.service.retire()
    }
    @Test fun endpointReplacementRetiresCatalogButMissingDriverSameSessionCloseStillReturns() = runTest {
        val peer = Peer(this)
        val browse = peer.service.openBrowse()
        val old = browse.catalog()
        peer.queryAvailable = false
        peer.identity = peer.identity.copy(epoch = ControlEpoch(2))
        peer.slot = DjiAndroidMediaIngressSlot(); peer.service.attachIngress(peer.slot)
        assertEquals(MediaServiceFailure.RETIRED, assertFailsWith<MediaServiceException> { old.next() }.failure)
        browse.close()
        assertEquals(1, peer.returns); assertEquals(1, peer.enables)
        assertEquals(listOf(true, false), peer.browseChanges)
    }
    @Test fun localRetirementSendsNoReturnOrCommandsAndOldBindingCannotReadRecords() = runTest {
        val peer = Peer(this); val browse = peer.service.openBrowse()
        val asset = browse.catalog().next()!!.upserts.first()
        val count = peer.writes.size
        peer.service.retire(); browse.close()
        assertEquals(0, peer.returns); assertEquals(count, peer.writes.size)
        assertNull(peer.service.mediaCatalogRecord(asset.id, browse.binding))
        assertEquals(MediaServiceFailure.RETIRED, assertFailsWith<MediaServiceException> { browse.catalog() }.failure)
    }
    @Test fun querySuspensionIntoDifferentCameraCannotPublishOrCommandSuccessor() = runTest {
        val peer = Peer(this); val browse = peer.service.openBrowse()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        peer.delayHook = { if (!entered.isCompleted) { entered.complete(Unit); release.await() } }
        val old = async { runCatching { browse.catalog().next() } }
        entered.await(); val count = peer.writes.size
        peer.identity = peer.identity.copy(cameraID = "successor-camera")
        release.complete(Unit)
        assertEquals(MediaServiceFailure.RETIRED, (old.await().exceptionOrNull() as MediaServiceException).failure)
        assertEquals(count, peer.writes.size)
        browse.close(); assertEquals(0, peer.returns)
    }
    @Test fun recycledRoutingKeyMintsDifferentContentIDWithoutGuessingUnknownFacts() {
        val first = MediaManifest.decode(fixture()).first()
        val a = DjiAndroidMediaAssets.asset(first)
        val b = DjiAndroidMediaAssets.asset(first.copy(sizeBytes = first.sizeBytes + 1))
        assertNotEquals(a.id, b.id)
        assertEquals(MediaListCommand.pageKey(first), MediaListCommand.pageKey(first.copy(sizeBytes = first.sizeBytes + 1)))
        val unknown = DjiAndroidMediaAssets.asset(MediaFile("unknown.bin", ""))
        assertNull(unknown.kind); assertNull(unknown.durationSeconds); assertNull(unknown.pixelSize)
        assertNull(unknown.frameRate); assertNull(unknown.capturedAt)
        assertNull(unknown.representations.single().byteCount)
    }
    @Test fun assetIsDeletableExactlyWhenItsFileHasAnOwnHandle() {
        val file = MediaFile("DCIM/DJI_001/DJI_20260912120000_0001_D.MP4", "", handle = 7)
        assertEquals(true, DjiAndroidMediaAssets.asset(file).deletable)
        assertEquals(false, DjiAndroidMediaAssets.asset(file.copy(handleShared = true)).deletable)
        assertEquals(false, DjiAndroidMediaAssets.asset(file.copy(handle = 0)).deletable)
    }

    @Test fun capturedReceiverNeverLooksUpSuccessorAfterQueueingAndRetiresOnlyItsTicket() {
        val slot = DjiAndroidMediaIngressSlot()
        val source = DjiAndroidMediaIdentity(CameraSessionID(), ControlEpoch(1), "SIMULATED-camera")
        val binding = MediaBrowseBinding(source.session, source.epoch)
        val first = DjiAndroidMediaIngress(source, binding, java.util.UUID.randomUUID(), false)
        val second = first.copy(exchange = java.util.UUID.randomUUID())
        var oldReceiver = 0; var successorReceiver = 0; var tileStatus = 0
        slot.publish(first) { _, ticket -> assertEquals(first, ticket); oldReceiver += 1; true }
        val queued = DjiAndroidMediaReceiveBatch.capture(listOf(chunk(1, 4)), slot, 7)
        slot.publish(second) { _, ticket -> assertEquals(second, ticket); successorReceiver += 1; true }
        slot.retire(first)
        queued.deliver({ 7 }, { false }) { tileStatus += 1 }
        assertEquals(1, tileStatus); assertEquals(0, oldReceiver); assertEquals(0, successorReceiver)
        assertEquals(second, slot.capture())
        DjiAndroidMediaReceiveBatch.capture(listOf(chunk(1, 4)), slot, 7)
            .deliver({ 7 }, { false }) { tileStatus += 1 }
        assertEquals(2, tileStatus); assertEquals(1, successorReceiver)
        slot.retire(second); assertNull(slot.capture())
    }
    @Test fun realReceiveBoundaryRejectsQueuedEndpointEpochAndCloseBeforeStatusOrMedia() {
        val slot = DjiAndroidMediaIngressSlot()
        val source = DjiAndroidMediaIdentity(CameraSessionID(), ControlEpoch(1), "SIMULATED-camera")
        val ticket = DjiAndroidMediaIngress(source, MediaBrowseBinding(source.session, source.epoch), java.util.UUID.randomUUID(), false)
        var statuses = 0; var media = 0
        slot.publish(ticket) { _, _ -> media += 1; true }
        val queued = DjiAndroidMediaReceiveBatch.capture(listOf(chunk(1, 4)), slot, 3)
        queued.deliver({ 4 }, { false }) { statuses += 1 }
        queued.deliver({ 3 }, { true }) { statuses += 1 }
        assertEquals(0, statuses); assertEquals(0, media)
        queued.deliver({ 3 }, { false }) { statuses += 1 }
        assertEquals(1, statuses); assertEquals(1, media)
    }
    @Test fun tileStatusOwnerCanReplaceEndpointWithoutQueuedMediaEnteringSuccessor() {
        val slot = DjiAndroidMediaIngressSlot()
        val source = DjiAndroidMediaIdentity(CameraSessionID(), ControlEpoch(1), "SIMULATED-camera")
        val ticket = DjiAndroidMediaIngress(source, MediaBrowseBinding(source.session, source.epoch), java.util.UUID.randomUUID(), false)
        var epoch = 9L; var statuses = 0; var media = 0
        slot.publish(ticket) { _, _ -> media += 1; true }
        val queued = DjiAndroidMediaReceiveBatch.capture(listOf(chunk(1, 4), chunk(1, 3)), slot, epoch)
        queued.deliver({ epoch }, { false }) { statuses += 1; epoch += 1 }
        assertEquals(1, statuses); assertEquals(0, media)
    }
    @Test fun actualCatalogRepliesNeedNoOwnedSessionCreatorCallbackOnBorrowedDriver() = runTest {
        val peer = Peer(this)
        // Only the per-endpoint receive boundary is installed. There is no onMediaFrame callback.
        val browse = peer.service.openBrowse()
        val delta = browse.catalog().next()!!
        assertTrue(delta.upserts.isNotEmpty())
        assertTrue(peer.statusFrames > 0)
        assertEquals(1, peer.enters)
        browse.close()
        assertEquals(1, peer.returns); assertEquals(1, peer.enables)
    }
    @Test fun borrowedSourceRetirementKeepsTileStatusDeliveryAndSendsNoReturn() = runTest {
        val peer = Peer(this)
        val browse = peer.service.openBrowse()
        val reached = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        peer.delayHook = { if (!reached.isCompleted) { reached.complete(Unit); release.await() } }
        val listing = async { runCatching { browse.catalog().next() } }
        reached.await()
        val queued = DjiAndroidMediaReceiveBatch.capture(listOf(chunk(1, 1, fixture())), peer.slot, peer.receiveEpoch)
        val count = peer.writes.size
        peer.service.retire()
        var tileStatuses = 0
        queued.deliver({ peer.receiveEpoch }, { peer.endpointClosed }) { tileStatuses += 1 }
        assertEquals(1, tileStatuses)
        release.complete(Unit); listing.await(); browse.close()
        assertEquals(0, peer.returns); assertEquals(count, peer.writes.size)
        assertNull(peer.slot.capture())
    }
    /** Same production cover lease and predicate as native session; no fabricated LIVE readiness. */
    @Test fun offlineCoverRetiresOldNativePictureReturnWithoutQueryAdmission() = runTest {
        val peer = Peer(this)
        var generation = 7L; var browsing = false; var pendingReturn = true
        val oldReturnOwner = generation
        val waiting = CompletableDeferred<Unit>(); var reachedGate = false; var resumedOldReturn = false
        val oldReturn = async(start = CoroutineStart.UNDISPATCHED) {
            reachedGate = true
            waiting.await()
            if (MediaLiveResume.isCurrentPictureOwner(oldReturnOwner, generation, browsing)) resumedOldReturn = true
        }
        assertTrue(reachedGate)
        peer.queryAvailable = false
        // Actual native claim retires its existing producer then invokes these exact mark/owns facts.
        peer.service.retire()
        val cover = DjiAndroidMediaGalleryCover.claim(
            mark = { generation += 1; browsing = true; pendingReturn = false; generation },
            owns = { it == generation && browsing },
            release = { generation += 1; browsing = false; pendingReturn = false })
        assertFalse(MediaLiveResume.isCurrentPictureOwner(oldReturnOwner, generation, browsing))
        assertFalse(pendingReturn)
        waiting.complete(Unit); oldReturn.await()
        assertFalse(resumedOldReturn)
        assertEquals(0, peer.enters); assertEquals(0, peer.returns); assertTrue(peer.writes.isEmpty())
        assertFailsWith<MediaServiceException> { peer.service.openBrowse() }
        assertTrue(browsing)
        cover.close(); assertFalse(browsing)
        val closedGeneration = generation; cover.close(); assertEquals(closedGeneration, generation)
    }
    @Test fun lateGalleryCoverCloseCannotRetireSuccessorBrowseReturnOrCover() = runTest {
        var generation = 0L; var browsing = false; var releaseCount = 0
        fun claim() = DjiAndroidMediaGalleryCover.claim(
            mark = { generation += 1; browsing = true; generation },
            owns = { it == generation && browsing },
            release = { generation += 1; browsing = false; releaseCount += 1 })
        val old = claim()
        val successor = claim()
        old.close(); assertTrue(browsing); assertEquals(0, releaseCount)
        successor.close(); assertFalse(browsing); assertEquals(1, releaseCount)
        val outgoing = claim()
        // Actual browse open and matching close increment native generation independently.
        generation += 1; browsing = true
        outgoing.close(); assertTrue(browsing); assertEquals(1, releaseCount)
        generation += 1; browsing = false
        val returnOwner = generation
        assertTrue(MediaLiveResume.isCurrentPictureOwner(returnOwner, generation, browsing))
        outgoing.close()
        assertTrue(MediaLiveResume.isCurrentPictureOwner(returnOwner, generation, browsing))
        assertEquals(1, releaseCount)
    }

    private suspend fun coverReturnAfterAvailabilityChange(scope: CoroutineScope, scenario: Int) {
        val peer = Peer(scope); peer.queryAvailable = false
        if (scenario == 3) peer.factsKnown = false
        val capturedSource = peer.mediaFacts?.identity
        val capturedSession = peer.identity.session
        var generation = 0L; var browsing = false; var live = false
        var releaseCount = 0; var returned: kotlinx.coroutines.Deferred<Unit>? = null
        peer.service.retire()
        val cover = DjiAndroidMediaGalleryCover.claim(
            mark = { generation += 1; browsing = true; generation },
            owns = { owner ->
                val currentSource = peer.mediaFacts?.identity
                val sameConnection = if (capturedSource == null) currentSource == null else currentSource?.sameConnection(capturedSource) == true
                capturedSession == peer.identity.session && sameConnection && generation == owner && browsing
            },
            release = {
                releaseCount += 1; generation += 1; browsing = false
                val canReturn = capturedSource != null && peer.mediaFacts?.identity?.sameConnection(capturedSource) == true && live
                peer.returnCurrent = canReturn
                if (canReturn && capturedSource != null) returned = peer.service.returnFromGalleryCover(capturedSource)
                else peer.wire.add(false)
            })
        assertEquals(0, peer.enters); assertEquals(0, peer.returns); assertTrue(peer.writes.isEmpty())
        when (scenario) {
            0 -> {
                live = true; peer.queryAvailable = true
                // Same native connection, new control epoch/endpoint after driver repair.
                peer.identity = peer.identity.copy(epoch = ControlEpoch(2))
                peer.slot = DjiAndroidMediaIngressSlot(); peer.service.attachIngress(peer.slot)
            }
            2 -> { live = true; peer.identity = peer.identity.copy(cameraID = "successor-camera") }
            3 -> { live = true; peer.factsKnown = true }
            4 -> { live = true; peer.queryAvailable = true }
        }
        val opened = if (scenario == 4) peer.service.openBrowse() else null
        if (opened != null) generation += 1 // Exact native mediaBrowseChanged mark supersedes cover.
        val beforeCloseGeneration = generation
        cover.close()
        returned?.await()
        when (scenario) {
            0 -> {
                assertFalse(browsing); assertEquals(1, releaseCount); assertEquals(1, peer.returns)
                assertEquals(1, peer.exits); assertEquals(1, peer.enables)
                assertEquals(0, peer.enters); assertTrue(peer.writes.isEmpty())
            }
            1 -> { assertFalse(browsing); assertEquals(1, releaseCount); assertEquals(0, peer.returns); assertEquals(listOf(false), peer.wire) }
            2, 3 -> { assertTrue(browsing); assertEquals(beforeCloseGeneration, generation); assertEquals(0, releaseCount); assertEquals(0, peer.returns); assertTrue(peer.wire.isEmpty()) }
            4 -> {
                assertTrue(browsing); assertEquals(0, releaseCount); assertEquals(0, peer.returns)
                opened!!.close(); assertEquals(1, peer.returns)
            }
        }
        cover.close(); assertEquals(if (scenario <= 1) 1 else 0, releaseCount)
        peer.service.retire()
    }
    @Test fun sameConnectionRepairsToLiveBeforeCachedCoverCloseRunsOriginalReturn() = runTest { coverReturnAfterAvailabilityChange(this, 0) }
    @Test fun cachedCoverStillOfflineRetiresOnlyItsOwnPresentation() = runTest { coverReturnAfterAvailabilityChange(this, 1) }
    @Test fun changedConnectionRejectsOldCoverEvenWhenNativeGenerationMatches() = runTest { coverReturnAfterAvailabilityChange(this, 2) }
    @Test fun unknownCapturedConnectionCannotClaimLaterConnectedCamera() = runTest { coverReturnAfterAvailabilityChange(this, 3) }
    @Test fun openedBrowseOwnsReturnAndOldCoverCannotDoubleReturn() = runTest { coverReturnAfterAvailabilityChange(this, 4) }

}
