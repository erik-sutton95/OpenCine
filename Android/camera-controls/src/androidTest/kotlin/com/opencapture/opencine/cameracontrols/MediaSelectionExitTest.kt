package com.opencapture.opencine.cameracontrols

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.monitorui.MonitorMediaSelectionCopy
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.*
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/**
 * SIMULATED clips in the actual shared Media page over a real library model. The selection bar offers
 * one Close that leaves selection mode, the page itself offers Back (not a second close), and the bar
 * fits, untruncated, in both orientations. With the
 * instrumentation argument `mediaSelectionSnapshots=true`, each orientation is captured to
 * `/data/local/tmp/media-selection/<orientation>.png` on the device, for review.
 */
/** Keeps its content across rotation (androidTest manifest: configChanges). */
class MediaSelectionTestActivity : ComponentActivity()

@RunWith(AndroidJUnit4::class)
class MediaSelectionExitTest {
    @Test fun closeLeavesSelectionModeWithNothingSelected() {
        withCatalog(landscape = true) { fixture, scenario ->
            scenario.onActivity { fixture.library.select(setOf(MediaAssetID("SIMULATED-02"))) }
            val exit = awaitExit()
            assertFullTarget(Rect().also(exit::getBoundsInScreen))
            // TalkBack's activation.
            assertTrue(exit.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            assertLeftSelection(fixture, scenario)
        }
    }

    @Test fun aTouchJustOutsideTheDrawnCloseStillLeavesSelection() {
        withCatalog(landscape = false) { fixture, scenario ->
            scenario.onActivity { fixture.library.select(setOf(MediaAssetID("SIMULATED-02"))) }
            val bounds = Rect().also(awaitExit()::getBoundsInScreen)
            // Without the full target, left + 1 dp would land inside the drawn chip and prove nothing.
            assertFullTarget(bounds)
            // The outer 1 dp of the 48 dp target lies beyond the drawn 44 dp chip, in the bar's padding.
            tap(bounds.left + dp(1f), bounds.exactCenterY())
            assertLeftSelection(fixture, scenario)
        }
    }

    private fun assertFullTarget(bounds: Rect) =
        assertTrue("Close is a 48 dp target: $bounds", bounds.width() >= dp(48f) - 1 && bounds.height() >= dp(48f) - 1)

    private fun awaitExit(): AccessibilityNodeInfo {
        val label = awaitNode("Close") { it.contentDescription?.toString() == MonitorMediaSelectionCopy.EXIT }
        // One control: the described node is the clickable one, or its direct parent.
        val exit = if (label.isClickable) label else checkNotNull(label.parent) { "The close is one clickable control" }
        assertTrue("Close is a button", exit.isClickable)
        assertEquals(MonitorMediaSelectionCopy.EXIT_TAG, tag(exit))
        return exit
    }

    private fun assertLeftSelection(fixture: Fixture, scenario: ActivityScenario<MediaSelectionTestActivity>) {
        var left = false
        val end = SystemClock.uptimeMillis() + 5_000
        while (!left && SystemClock.uptimeMillis() < end) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            scenario.onActivity {
                val state = fixture.library.state.value
                left = !state.selecting && state.selectedIDs.isEmpty()
            }
            if (!left) SystemClock.sleep(32)
        }
        assertTrue("Close must clear the selection and leave selection mode", left)
        assertTrue("The selection bar must close", awaitGone { tag(it) == MonitorMediaSelectionCopy.EXIT_TAG })
    }

    private fun dp(value: Float): Float =
        value * InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density

    private fun tap(x: Float, y: Float) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val down = SystemClock.uptimeMillis()
        for ((action, time) in listOf(MotionEvent.ACTION_DOWN to down, MotionEvent.ACTION_UP to down + 50)) {
            val event = MotionEvent.obtain(down, time, action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            assertTrue(automation.injectInputEvent(event, true))
            event.recycle()
        }
    }

    @Test fun theBarFitsUntruncatedInPortraitAndLandscape() {
        for (landscape in listOf(false, true)) withCatalog(landscape) { fixture, scenario ->
            scenario.onActivity { fixture.library.select(setOf(MediaAssetID("SIMULATED-02"))) }
            val back = awaitNode("Back") { tag(it) == "monitor.page.back" }
            assertEquals("The page's own control is Back, not a second close", "Back",
                (back.contentDescription ?: (0 until back.childCount).firstNotNullOfOrNull { back.getChild(it)?.contentDescription })?.toString())
            val exit = awaitNode("Close") { tag(it) == MonitorMediaSelectionCopy.EXIT_TAG }
            val count = awaitNode("count") { it.text?.toString() == "1 selected" }
            val actions = listOf("Select all", selectionShareDescription(1), selectionDeleteDescription(1, true))
                .map { label -> awaitNode(label) { it.contentDescription?.toString() == label } }
            val screen = Rect().also { bounds ->
                InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.getBoundsInScreen(bounds)
            }
            val frames = (listOf(exit, count) + actions).map { node -> Rect().also(node::getBoundsInScreen) }
            // Compose widens a small control's node to its touch bounds, so the 34 dp action circles
            // (unchanged) may share an edge band; close, count and the actions must not overlap.
            val leading = frames.take(3)
            val name = if (landscape) "landscape" else "portrait"
            snapshot(name)
            frames.forEachIndexed { index, frame ->
                assertTrue("$name: element $index is cut off: $frame", screen.contains(frame))
            }
            leading.forEachIndexed { index, frame ->
                for (other in leading.drop(index + 1))
                    assertFalse("$name: selection bar elements overlap: $frames", Rect.intersects(frame, other))
            }
            assertTrue("$name: Close leads the count", frames[0].right <= frames[1].left)
            assertTrue("$name: the actions follow the count", frames[1].right <= frames[2].left)
        }
    }

    private fun withCatalog(landscape: Boolean,
        body: (Fixture, ActivityScenario<MediaSelectionTestActivity>) -> Unit) {
        ActivityScenario.launch(MediaSelectionTestActivity::class.java).use { scenario ->
            lateinit var fixture: Fixture
            scenario.onActivity { activity ->
                fixture = Fixture()
                activity.setContent { fixture.catalog() }
                // The activity handles its own rotation (manifest), so the content stays mounted.
                activity.requestedOrientation = if (landscape) ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                    else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
            try {
                val expected = if (landscape) Configuration.ORIENTATION_LANDSCAPE else Configuration.ORIENTATION_PORTRAIT
                var turned = false
                val end = SystemClock.uptimeMillis() + 10_000
                while (!turned && SystemClock.uptimeMillis() < end) {
                    InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                    scenario.onActivity { turned = it.resources.configuration.orientation == expected }
                    if (!turned) SystemClock.sleep(100)
                }
                assertTrue("The activity must settle in the requested orientation", turned)
                body(fixture, scenario)
            } finally { scenario.onActivity { fixture.scope.cancel(); fixture.root.deleteRecursively() } }
        }
    }

    private class Fixture {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val root: File = Files.createTempDirectory("SIMULATED-selection-").toFile()
        val records = (1..8).map { index ->
            val id = "SIMULATED-%02d".format(index)
            MonitorMediaRecord(
                MediaAsset(MediaAssetID(id), filename = "$id.MOV", kind = MediaAssetKind.VIDEO,
                    representations = listOf(MediaRepresentation(MediaRepresentationID("$id-original"),
                        MediaRepresentationRole.ORIGINAL, 1)), deletable = true),
                id, MonitorMediaCacheAddress(null, mapOf(MediaRepresentationID("$id-original") to "$id.MOV"), id),
                facts = MonitorMediaFilterFacts(format = "4K", dateKey = "20261029", orderKey = id))
        }
        val codec = object : MonitorMediaCatalogCodec<String> {
            override fun decode(bytes: ByteArray) = records
            override fun encode(records: List<MonitorMediaRecord<String>>) = "SIMULATED".toByteArray()
            override fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<String> =
                throw MediaServiceException(MediaServiceFailure.UNSUPPORTED)
        }
        val favorites = object : MonitorMediaFavoritesStore {
            override fun favorites(): Set<String> = emptySet()
            override fun saveFavorites(keys: Set<String>) = Unit
        }
        val library = MonitorMediaLibraryModel(
            MonitorMediaCache(MonitorMediaCacheDirectory(root).also { it.write("SIMULATED".toByteArray(), "index.json") },
                codec, MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")),
            favorites, scope = scope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialRecords = records)

        init {
            library.begin()
            library.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS)
        }

        @androidx.compose.runtime.Composable fun catalog() {
            MonitorOperatorCatalogScreen(library, "SIMULATED", sourceAvailable = true,
                operations = MonitorMediaGalleryOperations(download = {}, delete = {}),
                facts = { MonitorMediaGalleryFileFacts("4K · 25p", "00:12") }, begin = {}, refresh = {},
                close = {}, open = {}, share = { _, _ -> },
                thumbnail = { Box(Modifier.fillMaxSize().background(Color(0xFF3A4652))) })
        }
    }

    private fun tag(node: AccessibilityNodeInfo): String? {
        val key = "androidx.compose.ui.semantics.testTag"
        if (key in node.availableExtraData) node.refreshWithExtraData(key, Bundle())
        return node.extras.getCharSequence(key)?.toString()
    }

    private fun awaitNode(what: String, matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
        val end = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < end) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            findNode { it.isVisibleToUser && matches(it) }?.let { return it }
            SystemClock.sleep(32)
        }
        val seen = mutableListOf<String>()
        findNode { node ->
            if (node.isVisibleToUser) seen += "${node.className}|${node.text}|${node.contentDescription}|${tag(node)}|${node.isClickable}"
            false
        }
        fail("The selection bar must show: $what; saw $seen"); throw AssertionError()
    }

    private fun awaitGone(matches: (AccessibilityNodeInfo) -> Boolean): Boolean {
        val end = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < end) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            if (findNode { it.isVisibleToUser && matches(it) } == null) return true
            SystemClock.sleep(32)
        }
        return false
    }

    private fun findNode(matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val pending = ArrayDeque<AccessibilityNodeInfo>()
        InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.let(pending::add)
        var walked = 0
        while (pending.isNotEmpty() && walked++ < 5_000) {
            val node = pending.removeFirst()
            if (matches(node)) return node
            for (i in 0 until node.childCount) node.getChild(i)?.let(pending::add)
        }
        return null
    }

    private fun snapshot(name: String) {
        if (InstrumentationRegistry.getArguments().getString("mediaSelectionSnapshots") != "true") return
        SystemClock.sleep(300)
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        // The shell user's directory outlives the test package, which the runner uninstalls.
        for (command in listOf("mkdir -p $SNAPSHOTS", "screencap -p $SNAPSHOTS/$name.png"))
            ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(command)).use { it.readBytes() }
    }

    private companion object {
        const val SNAPSHOTS = "/data/local/tmp/media-selection"
    }
}
