package com.opencapture.opencine.cameracontrols

import android.graphics.Bitmap
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.file.Files

/** SIMULATED source refusal; real shared gallery, Compose page and accessibility Close. */
class GalleryOpeningTestActivity : ComponentActivity()

@RunWith(AndroidJUnit4::class)
class GalleryOpeningAdmissionTest {
    @Test fun refusedVideoKeepsAVisibleUnavailableCloseAndReturnsToGallery() {
        withGallery(MediaAssetKind.VIDEO) { fixture, scenario ->
            scenario.onActivity { activity -> activity.setContent { fixture.gallery() } }
            awaitText("Media unavailable")
            scenario.onActivity {
                assertSame(fixture.opening, fixture.presented)
                assertSame(fixture.opening.record, fixture.presented!!.record)
                assertSame(fixture.opening.playlist, fixture.presented!!.playlist)
                assertEquals(fixture.opening.admission, fixture.presented!!.admission)
                assertNotNull(fixture.host.presented.value)
                assertEquals(1, fixture.playerFactoryCalls)
            }
            clickClose()
            awaitGallery(fixture, scenario)
        }
    }

    @Test fun refusedPhotoKeepsAVisibleUnavailableCloseAndReturnsToGallery() {
        withGallery(MediaAssetKind.PHOTO) { fixture, scenario ->
            fixture.sourceAvailable = false
            scenario.onActivity { activity -> activity.setContent { fixture.gallery() } }
            awaitText("Media unavailable")
            scenario.onActivity {
                assertSame(fixture.opening, fixture.presented)
                assertSame(fixture.opening.record, fixture.presented!!.record)
                assertEquals(0, fixture.pictureReads)
            }
            clickClose()
            awaitGallery(fixture, scenario)
        }
    }

    @Test fun retiredPhotoOpeningKeepsCloseWithoutReadingTheRetiredSource() = expiredPhoto(replace = false)

    @Test fun replacedPhotoOpeningKeepsItsOriginalTokenAndCannotReadTheSuccessor() = expiredPhoto(replace = true)

    private fun expiredPhoto(replace: Boolean) {
        withGallery(MediaAssetKind.PHOTO) { fixture, scenario ->
            var visible by mutableStateOf(true)
            scenario.onActivity { activity ->
                fixture.library.close()
                if (replace) fixture.library.begin()
                assertFalse(fixture.library.isCurrent(fixture.opening.admission))
                assertNotEquals(fixture.opening.admission, fixture.library.actionToken)
                activity.setContent {
                    if (visible) MonitorOperatorPhotoScreen(fixture.library, fixture.opening.record, fixture.assist,
                        MonitorMediaPictureLoaders<String, Bitmap>(source = { fixture.pictureReads += 1; null }),
                        fixture.operations, close = { fixture.host.close(fixture.opening.id); visible = false },
                        admission = fixture.opening.admission, sourceCurrent = { true })
                    else fixture.gallery()
                }
            }
            awaitText("Media unavailable")
            scenario.onActivity {
                assertEquals(0, fixture.pictureReads)
                assertSame(fixture.opening, fixture.host.presented.value!!.request)
            }
            clickClose()
            awaitGallery(fixture, scenario)
            scenario.onActivity { assertEquals(0, fixture.pictureReads) }
        }
    }

    private fun withGallery(kind: MediaAssetKind,
        body: (Fixture, ActivityScenario<GalleryOpeningTestActivity>) -> Unit) {
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            lateinit var fixture: Fixture
            scenario.onActivity { fixture = Fixture(kind) }
            try { body(fixture, scenario) }
            finally { scenario.onActivity { fixture.scope.cancel(); fixture.root.deleteRecursively() } }
        }
    }

    private class Fixture(kind: MediaAssetKind) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val root = Files.createTempDirectory("SIMULATED-gallery-opening-").toFile()
        val record = MonitorMediaRecord(
            MediaAsset(MediaAssetID("SIMULATED-original"), filename = "SIMULATED-original",
                kind = kind, representations = emptyList()),
            "original-payload", MonitorMediaCacheAddress("original-thumb", emptyMap(), "original-cache"))
        val codec = object : MonitorMediaCatalogCodec<String> {
            override fun decode(bytes: ByteArray) = listOf(record)
            override fun encode(records: List<MonitorMediaRecord<String>>) = "SIMULATED".toByteArray()
            override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
                throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        }
        val favorites = object : MonitorMediaFavoritesStore {
            override fun favorites(): Set<String> = emptySet()
            override fun saveFavorites(keys: Set<String>) = Unit
        }
        val library = MonitorMediaLibraryModel(
            MonitorMediaCache(MonitorMediaCacheDirectory(root).also {
                it.write("SIMULATED".toByteArray(), "index.json")
            }, codec,
                MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")),
            favorites, scope = scope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE,
            initialRecords = listOf(record))
        val operations = MonitorMediaGalleryOperations<String>()
        val opening: MonitorMediaGalleryOpen<String>
        val host = MonitorOperatorMediaHost(library)
        var presented: MonitorMediaGalleryOpen<String>? = null
        var playerFactoryCalls = 0
        var pictureReads = 0
        var sourceAvailable = true
        val player = MonitorOperatorMediaModel<String, Unit>(library, scope = scope,
            makeAdmittedPlayback = { _, _ -> playerFactoryCalls += 1; null })
        val assist = MonitorAssistState()

        init {
            library.begin()
            library.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS)
            val gallery = MonitorMediaGalleryModel(library, scope)
            opening = requireNotNull(gallery.open(record.asset.id, gallery.snapshot(), operations, sourceAvailable = true))
            check(host.open(opening))
        }

        @Composable fun gallery() {
            MonitorOperatorMediaScreen(library, "SIMULATED gallery", true, operations,
                facts = { MonitorMediaGalleryFileFacts("SIMULATED", null, null) }, close = {},
                thumbnail = { Box(Modifier.fillMaxSize()) }, begin = {}, host = host,
                player = { page ->
                    presented = page.request
                    MonitorOperatorPlaybackScreen(player, page.request, assist = null, assists = null,
                        usageStore = null, effects = null, cacheOriginal = false, deliveryPresented = false,
                        operations = MonitorOperatorPlaybackOperations(), source = { MonitorPlaybackSourceValues() },
                        nativeAudio = { null }, close = page::close, share = null,
                        picture = { _, _ -> Box(Modifier.fillMaxSize()) })
                }, photo = { page ->
                    presented = page.request
                    MonitorOperatorPhotoScreen(library, page.request.record, assist,
                        MonitorMediaPictureLoaders<String, Bitmap>(source = { pictureReads += 1; null }),
                        operations, page::close, admission = page.request.admission,
                        sourceCurrent = { sourceAvailable })
                })
        }
    }

    private fun awaitGallery(fixture: Fixture, scenario: ActivityScenario<GalleryOpeningTestActivity>) {
        val end = SystemClock.uptimeMillis() + 5_000
        var closed = false
        while (!closed && SystemClock.uptimeMillis() < end) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            scenario.onActivity { closed = fixture.host.presented.value == null }
            if (!closed) SystemClock.sleep(32)
        }
        assertTrue("The rendered Close must return to the actual gallery host", closed)
        awaitText("SIMULATED gallery")
    }

    private fun awaitText(text: String) {
        val end = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < end) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            if (findNode { it.isVisibleToUser && (it.text?.toString() == text || it.contentDescription?.toString() == text) } != null) return
            SystemClock.sleep(32)
        }
        fail("The actual shared page must visibly show: $text")
    }

    private fun clickClose() {
        val node = findNode { info ->
            val key = "androidx.compose.ui.semantics.testTag"
            if (key in info.availableExtraData) info.refreshWithExtraData(key, Bundle())
            info.isVisibleToUser && info.isClickable &&
                info.extras.getCharSequence(key)?.toString() == "monitor.media.unavailable.close"
        }
        assertNotNull("The unavailable page must expose a visible Close", node)
        assertTrue(node!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
    }

    private fun findNode(matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val pending = ArrayDeque<AccessibilityNodeInfo>()
        automation.rootInActiveWindow?.let(pending::add)
        var walked = 0
        while (pending.isNotEmpty() && walked++ < 5_000) {
            val node = pending.removeFirst()
            if (matches(node)) return node
            for (i in 0 until node.childCount) node.getChild(i)?.let(pending::add)
        }
        return null
    }
}
