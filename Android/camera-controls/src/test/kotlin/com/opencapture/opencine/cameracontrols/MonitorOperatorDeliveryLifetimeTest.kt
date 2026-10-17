@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.*
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import kotlin.test.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class DeliveryTestCodec(val records: List<MonitorMediaRecord<String>>) : MonitorMediaCatalogCodec<String> {
    override fun decode(bytes: ByteArray) = records
    override fun encode(records: List<MonitorMediaRecord<String>>) = byteArrayOf(1)
    override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
        throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
}
private class DeliveryTestFavorites : MonitorMediaFavoritesStore {
    override fun favorites() = emptySet<String>()
    override fun saveFavorites(keys: Set<String>) {}
}

/** SIMULATED gallery and file ports; the actual source admission and app-scoped run owner. */
class MonitorOperatorDeliveryLifetimeTest {
    private class Fixture(scope: CoroutineScope) {
        val root: File = Files.createTempDirectory("opencine-delivery-lifetime-").toFile()
        val records = listOf("A", "B").map { id -> MonitorMediaRecord(
            MediaAsset(MediaAssetID(id), filename = "$id.mov", kind = MediaAssetKind.VIDEO,
                representations = emptyList(), deletable = true), id,
            MonitorMediaCacheAddress(null, emptyMap(), id)) }
        val directory = MonitorMediaCacheDirectory(root).also { it.write(byteArrayOf(1), "index.json") }
        val library = MonitorMediaLibraryModel(MonitorMediaCache(directory, DeliveryTestCodec(records),
            MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")),
            DeliveryTestFavorites(), scope = scope).also {
            it.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS); it.begin()
        }
        val exported = CompletableDeferred<Unit>()
        val source = MonitorOriginalDeliverySource(library, record = { id: String -> library.record(MediaAssetID(id)) },
            fileFacts = { MonitorDeliveryFileFacts("$it.mov", 1) }, connected = { true },
            originals = MonitorDeliveryOriginalService({ true }, {}, { null }),
            exporter = MonitorDeliveryExportService { id, _ -> exported.await(); File(root, "$id.mov") })
        fun close() { library.close(); root.deleteRecursively() }
    }

    @Test fun selectionAdmissionOutlivesTheGalleryBrowseButNotItsCache() = runTest {
        val f = Fixture(backgroundScope)
        try {
            runCurrent()
            val admission = assertNotNull(f.source.admission(listOf("A")))
            assertTrue(admission.isCurrent())
            f.library.close() // The media screen is dismissed.
            assertTrue(admission.isCurrent())
            f.directory.clear(preserving = emptyList()) // Settings cleared the cache.
            assertFalse(admission.isCurrent())
        } finally { f.close() }
    }

    @Test fun deliveryBegunInTheGalleryCompletesAfterItIsDismissedAndShowsItsToast() = runTest {
        val f = Fixture(backgroundScope)
        try {
            runCurrent()
            val coordinator = MonitorDeliveryCoordinator(backgroundScope)
            val saved = mutableListOf<String>()
            val selection = MonitorOperatorDeliverySelection<String, Unit, Unit, Unit, Unit, Unit>(listOf("A", "B"),
                facts = { f.source.selection(listOf("A", "B")) }, admission = assertNotNull(f.source.admission(listOf("A", "B"))),
                source = f.source.source(), photos = MonitorDeliveryPhotosService { file -> saved += file.name; true })
            val request = MonitorDeliveryPreparedRequest<Unit, Unit, Unit, Unit, Unit>(MonitorDeliveryDestination.NATIVE_SHARE,
                null, MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS, null)
            assertNotNull(selection.begin(coordinator, request)); runCurrent()
            assertTrue(coordinator.lifetime.state.value.running)
            f.library.close() // The media screen is dismissed while the run exports.
            f.exported.complete(Unit); runCurrent()
            assertFalse(coordinator.lifetime.state.value.running)
            assertEquals(listOf("A.mov", "B.mov"), saved)
            assertEquals("Saved 2 clips to Photos", coordinator.lifetime.state.value.toast)
            coordinator.close()
        } finally { f.close() }
    }

    @Test fun shareRunCarriesTheIncludedMetadataToTheRootChooser() = runTest {
        val f = Fixture(backgroundScope)
        try {
            runCurrent()
            val coordinator = MonitorDeliveryCoordinator(backgroundScope)
            val selection = MonitorOperatorDeliverySelection<String, Unit, Unit, Unit, Unit, Unit>(listOf("A"),
                facts = { f.source.selection(listOf("A")) }, admission = assertNotNull(f.source.admission(listOf("A"))),
                source = f.source.source { "A.mov · SIMULATED" }, photos = null)
            selection.begin(coordinator, MonitorDeliveryPreparedRequest(MonitorDeliveryDestination.NATIVE_SHARE,
                null, MonitorDeliveryPostExportAction.SYSTEM_SHARE, null))
            f.exported.complete(Unit); runCurrent()
            val share = assertNotNull(coordinator.lifetime.state.value.share)
            assertEquals(listOf("A.mov"), share.payload.urls.map { it.name })
            assertEquals("A.mov · SIMULATED", share.payload.metadataText)
            coordinator.close()
        } finally { f.close() }
    }

    @Test fun nativeShareAcceptedAfterAHopRestoresTheRouteBeforeTheChooser() = runTest {
        val f = Fixture(backgroundScope)
        try {
            runCurrent()
            val coordinator = MonitorDeliveryCoordinator(backgroundScope)
            val rejoin = CompletableDeferred<Unit>()
            val restored = mutableListOf<String>()
            val internet = MonitorDeliveryInternetService(needsHop = { false }, begin = { "unused" }, owns = { it == "route" },
                wait = { true }, restoreEntered = { lease -> rejoin.await(); restored += lease }, restore = { restored += "dismissed $it" })
            val service = MonitorDeliveryRemoteService<Unit, Unit, String>(MonitorDeliveryRemotePresentation("SIMULATED", "Uploading"),
                observe = { MonitorDeliveryRemoteFacts(true, true, false, null, null) },
                load = { error("unused") }, create = { _, _ -> error("unused") }, persist = { _, _ -> },
                internet = internet, transfer = { it }, skipsUploaded = false)
            val selection = MonitorOperatorDeliverySelection<String, Unit, Unit, Unit, Unit, String>(listOf("A"),
                facts = { f.source.selection(listOf("A")) }, admission = assertNotNull(f.source.admission(listOf("A"))),
                source = f.source.source(), photos = null,
                remote = MonitorOperatorDeliveryRemote(service) { null })
            f.exported.complete(Unit)
            selection.begin(coordinator, MonitorDeliveryPreparedRequest(MonitorDeliveryDestination.NATIVE_SHARE,
                null, MonitorDeliveryPostExportAction.SYSTEM_SHARE, "route")); runCurrent()
            // The chooser waits for the camera route the popup left on.
            assertEquals(null, coordinator.lifetime.state.value.share)
            assertTrue(coordinator.lifetime.state.value.running)
            rejoin.complete(Unit); runCurrent()
            assertEquals(listOf("route"), restored)
            assertNotNull(coordinator.lifetime.state.value.share)
            coordinator.close()
            // A request the closed coordinator refuses hands its route straight back.
            assertEquals(null, selection.begin(coordinator, MonitorDeliveryPreparedRequest(MonitorDeliveryDestination.NATIVE_SHARE,
                null, MonitorDeliveryPostExportAction.SYSTEM_SHARE, "route")))
            assertEquals(listOf("route", "dismissed route"), restored)
        } finally { f.close() }
    }
}
