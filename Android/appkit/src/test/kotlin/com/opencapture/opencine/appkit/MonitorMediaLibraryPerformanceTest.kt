package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.nio.file.Files
import kotlin.test.*

/**
 * SIMULATED camera card of realistic size: 1500 RAW+JPEG pairs (3000 photos) and 200 clips,
 * listed in 32-object pages like the Nikon cursor. Budgets are operation counts (exact on any
 * machine) plus one generous wall-clock ceiling for the linear selection path. Field report
 * 2026-10-25: a large Nikon card stalled the shared gallery for long periods.
 */
private object PerfCard {
    const val PAIRS = 1500
    const val CLIPS = 200
    const val PAGE = 32
    const val COUNT = PAIRS * 2 + CLIPS
    const val PAGES = (COUNT + PAGE - 1) / PAGE

    fun assets(): List<MediaAsset> = buildList {
        for (index in 0 until PAIRS) {
            val stem = "DSC_%04d".format(index + 1)
            add(asset("$stem.NEF", MediaAssetKind.PHOTO, 48_000_000, index))
            add(asset("$stem.JPG", MediaAssetKind.PHOTO, 12_000_000, index))
        }
        for (index in 0 until CLIPS) add(asset("DSC_%04d.MOV".format(PAIRS + index + 1), MediaAssetKind.VIDEO, 900_000_000, PAIRS + index))
    }

    fun asset(filename: String, kind: MediaAssetKind, bytes: Long, minute: Int) = MediaAsset(
        MediaAssetID("card1/$filename"), volumeID = "slot1", filename = filename, kind = kind,
        capturedAt = 1_790_000_000_000L + minute * 60_000L,
        representations = listOf(MediaRepresentation(MediaRepresentationID("$filename#original"), MediaRepresentationRole.ORIGINAL, bytes)),
        deletable = true)

    fun pages(assets: List<MediaAsset>): MutableList<MediaCatalogDelta> =
        assets.chunked(PAGE).mapIndexed { index, page ->
            MediaCatalogDelta(reset = index == 0, upserts = page, complete = index == PAGES - 1)
        }.toMutableList()
}

private class PerfFavorites : MonitorMediaFavoritesStore {
    override fun favorites() = emptySet<String>()
    override fun saveFavorites(keys: Set<String>) {}
}

private class PerfCodec : MonitorMediaCatalogCodec<String> {
    var saves = 0
    var encodedRecords = 0
    override fun decode(bytes: ByteArray) = emptyList<MonitorMediaRecord<String>>()
    override fun encode(records: List<MonitorMediaRecord<String>>): ByteArray {
        saves += 1; encodedRecords += records.size
        return "[]".toByteArray()
    }
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding) = MonitorMediaRecord(asset, asset.filename,
        MonitorMediaCacheAddress("thumbs/${asset.filename}.jpg", asset.representations.associate { it.id to "files/${asset.filename}" }, asset.filename),
        facts = MonitorMediaFilterFacts(format = asset.filename.substringAfterLast('.'), dateKey = "20261025",
            orderKey = asset.filename, presentationKind = asset.kind))
}

private class PerfCursor(val pages: MutableList<MediaCatalogDelta>) : MediaCatalogCursor {
    override suspend fun next(): MediaCatalogDelta? = if (pages.isEmpty()) null else pages.removeAt(0)
    override fun close() {}
}

private class PerfThumbnails : CameraMediaThumbnailService {
    override suspend fun thumbnail(asset: MediaAssetID) = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xD9.toByte())
}

/** Streams an original in many small chunks, like a camera transfer over Wi-Fi. */
private class PerfTransfer(val chunks: Int) : CameraMediaTransferService {
    override suspend fun transfer(representation: MediaRepresentationID, sink: MediaByteSink): MediaTransferReceipt {
        repeat(chunks) { sink.write(byteArrayOf(1)) }
        return MediaTransferReceipt(chunks.toLong(), chunks.toLong())
    }
}

private class PerfBrowse(val assets: List<MediaAsset>) : CameraMediaBrowse {
    override val binding = MediaBrowseBinding(CameraSessionID(), ControlEpoch(1))
    override val thumbnails: CameraMediaThumbnailService = PerfThumbnails()
    override var transfers: CameraMediaTransferService? = null
    override val deletion: CameraMediaDeleteService? = null
    override val heldBySource: Boolean? = null
    override suspend fun catalog(): MediaCatalogCursor = PerfCursor(PerfCard.pages(assets))
    override suspend fun close() {}
}

private class PerfService(val browse: PerfBrowse) : CameraMediaService {
    override val sessionID get() = browse.binding.session
    override suspend fun openBrowse(): CameraMediaBrowse = browse
}

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMediaLibraryPerformanceTest {
    private class Fixture(val root: java.io.File, val model: MonitorMediaLibraryModel<String>,
        val codec: PerfCodec, val browse: PerfBrowse, val scans: MutableList<Int>)

    /** Background scans are accounted per plan; the snapshot is SIMULATED (no filesystem). */
    private fun fixture(scope: CoroutineScope, assets: List<MediaAsset> = PerfCard.assets(),
        scanning: MonitorMediaCacheScanning = MonitorMediaCacheScanning.BACKGROUND): Fixture {
        val root = Files.createTempDirectory("opencine-media-perf-").toFile()
        val codec = PerfCodec()
        val browse = PerfBrowse(assets)
        val scans = mutableListOf<Int>()
        val cache = MonitorMediaCache(MonitorMediaCacheDirectory(root), codec, MonitorMediaOriginalEligibility.ExactSize,
            "index.json", listOf("index.json"))
        val model = MonitorMediaLibraryModel(cache, PerfFavorites(), PerfService(browse), scope,
            cacheScanning = scanning, initialRecords = emptyList(), sleep = {},
            readSnapshot = { plan ->
                scans += plan.recordIDs.size
                MonitorMediaCacheSnapshot(plan.id, plan.generation, plan.recordIDs.associateWith { MonitorMediaCacheEntry(null, null, null) })
            })
        model.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS)
        return Fixture(root, model, codec, browse, scans)
    }

    private fun report(name: String, value: Any) = println("MEDIA-PERF-ANDROID $name: $value")

    @Test fun listingALargeCardDoesNotCheckpointTheWholeCatalogOnEveryPage() = runTest {
        val owner = Job(); val scope = CoroutineScope(owner + StandardTestDispatcher(testScheduler))
        val fixture = fixture(scope)
        try {
            fixture.model.begin(); advanceUntilIdle()
            assertEquals(PerfCard.COUNT, fixture.model.state.value.records.size)
            report("listing.saves", "${fixture.codec.saves} saves, ${fixture.codec.encodedRecords} records encoded over ${PerfCard.PAGES} pages")
            report("listing.scannedRecords", "${fixture.scans.sum()} in ${fixture.scans.size} scans")
            assertTrue(fixture.codec.saves <= PerfCard.PAGES / 8 + 2,
                "the catalog was checkpointed ${fixture.codec.saves} times over ${PerfCard.PAGES} pages")
            assertTrue(fixture.scans.sum() <= PerfCard.COUNT * 2,
                "listing scanned ${fixture.scans.sum()} cache records for ${PerfCard.COUNT} rows")
        } finally { fixture.model.dispose(); owner.cancel(); fixture.root.deleteRecursively() }
    }

    @Test fun transferProgressTicksDoNotReemitTheCatalogContent() = runTest {
        val owner = Job(); val scope = CoroutineScope(owner + StandardTestDispatcher(testScheduler))
        val small = PerfCard.assets().map { asset ->
            asset.copy(representations = asset.representations.map { it.copy(byteCount = 200) })
        }
        val fixture = fixture(scope, small)
        fixture.browse.transfers = PerfTransfer(200)
        val model = fixture.model
        try {
            model.begin(); advanceUntilIdle()
            var contentEmissions = 0; var tickEmissions = 0
            val collectors = Job()
            backgroundScope.launch(collectors + UnconfinedTestDispatcher(testScheduler)) { model.content.collect { contentEmissions += 1 } }
            backgroundScope.launch(collectors + UnconfinedTestDispatcher(testScheduler)) { model.transferProgress.collect { tickEmissions += 1 } }
            contentEmissions = 0; tickEmissions = 0
            val target = model.state.value.records[1].asset.id
            val transfer = scope.async { model.cacheOriginal(target) }
            advanceUntilIdle(); transfer.await()
            collectors.cancel()
            report("progress.tickEmissions", tickEmissions)
            report("progress.contentEmissions", contentEmissions)
            assertTrue(tickEmissions >= 100, "the progress flow must carry the transfer's ticks ($tickEmissions)")
            assertTrue(contentEmissions <= 6, "200 progress ticks re-emitted the catalog content $contentEmissions times")
        } finally { model.dispose(); owner.cancel(); fixture.root.deleteRecursively() }
    }

    @Test fun displayedRecordsAndCategoriesAreDerivedOncePerChange() = runTest {
        val owner = Job(); val scope = CoroutineScope(owner + StandardTestDispatcher(testScheduler))
        val fixture = fixture(scope)
        val model = fixture.model
        try {
            model.begin(); advanceUntilIdle()
            model.display(sort = MonitorMediaSort.NAME)
            val first = model.displayedRecords
            assertSame(first, model.displayedRecords, "a repeated read must reuse the one derivation")
            assertSame(model.records(MonitorMediaCategoryFilter.PHOTOS), model.records(MonitorMediaCategoryFilter.PHOTOS))
            model.display(sort = MonitorMediaSort.NEWEST)
            assertNotSame(first, model.displayedRecords, "a sort change derives again")
            assertEquals(PerfCard.COUNT, model.displayedRecords.size)
        } finally { model.dispose(); owner.cancel(); fixture.root.deleteRecursively() }
    }

    @Test fun selectAllAndResolveTheWholeCardIsLinear() = runTest {
        val owner = Job(); val scope = CoroutineScope(owner + StandardTestDispatcher(testScheduler))
        val fixture = fixture(scope)
        val model = fixture.model
        try {
            model.begin(); advanceUntilIdle()
            val gallery = MonitorMediaGalleryModel(model, scope)
            fun run(): Int {
                val snapshot = gallery.snapshot()
                gallery.selectAll(snapshot)
                val resolved = gallery.selected(gallery.snapshot()).size
                gallery.select(model.state.value.selectedIDs, gallery.snapshot())
                model.state.value.records.forEach { assertNotNull(model.record(it.asset.id)) }
                return resolved
            }
            run() // warm the JIT
            val started = System.nanoTime()
            val resolved = run()
            val millis = (System.nanoTime() - started) / 1_000_000
            report("selectAll.resolve.ms", millis)
            assertEquals(PerfCard.COUNT, resolved)
            assertTrue(millis < 50, "select all and resolve took $millis ms for ${PerfCard.COUNT} records")
        } finally { model.dispose(); owner.cancel(); fixture.root.deleteRecursively() }
    }

    @Test fun aThumbnailCommitRescansOnlyItsRecord() = runTest {
        val owner = Job(); val scope = CoroutineScope(owner + StandardTestDispatcher(testScheduler))
        val fixture = fixture(scope)
        val model = fixture.model
        try {
            model.begin(); advanceUntilIdle()
            val before = fixture.scans.sum()
            val ids = model.state.value.records.take(40).map { it.asset.id }
            // Thumbnails arrive one at a time, as they do over a camera link.
            ids.forEach { id -> scope.launch { model.ensureThumbnailAndWait(id) }; advanceUntilIdle() }
            val scanned = fixture.scans.sum() - before
            report("thumbnails.40.scannedRecords", scanned)
            assertTrue(scanned <= ids.size * 2, "40 thumbnail commits rescanned $scanned cache records")
        } finally { model.dispose(); owner.cancel(); fixture.root.deleteRecursively() }
    }

    @Test fun immediateScanningRefreshesOnlyTheCommittedRecord() = runTest {
        val owner = Job(); val scope = CoroutineScope(owner + StandardTestDispatcher(testScheduler))
        val fixture = fixture(scope, scanning = MonitorMediaCacheScanning.IMMEDIATE)
        val model = fixture.model
        try {
            model.begin(); advanceUntilIdle()
            val id = model.state.value.records[3].asset.id
            val before = model.state.value.entries
            scope.launch { model.ensureThumbnailAndWait(id) }; advanceUntilIdle()
            val after = model.state.value.entries
            assertNotNull(after[id]?.thumbnail, "the committed thumbnail is visible")
            // Untouched rows keep their exact entry objects: nothing else was rescanned.
            val rescanned = after.count { (key, entry) -> key != id && before[key] !== entry }
            report("immediate.thumbnail.otherRowsRescanned", rescanned)
            assertEquals(0, rescanned, "a thumbnail commit rescanned $rescanned other rows")
        } finally { model.dispose(); owner.cancel(); fixture.root.deleteRecursively() }
    }
}
