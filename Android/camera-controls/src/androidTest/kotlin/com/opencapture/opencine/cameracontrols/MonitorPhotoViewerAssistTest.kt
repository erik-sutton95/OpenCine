package com.opencapture.opencine.cameracontrols

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.*
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Owner findings 2026-10-31 (iPad hardware pass, Android twin): the photo viewer shows the playback
 * view assist bar and its option inspector, and a vertical photo zooms past its 9:16 frame to the
 * screen edge like clip playback (#299). The real shared photo page over a SIMULATED tall still
 * (red, white rim); the SIMULATED still look paints the whole still green, so the window pixels say
 * whether the page shows the still through the picture assists. Each run saves the full screen as
 * `photo-<toolbar|zoom>-<orientation>.png` in the app's external files for the owner's review.
 */
@RunWith(AndroidJUnit4::class)
class MonitorPhotoViewerAssistTest {
    @Test(timeout = 120_000) fun portraitBarTogglesAPictureAssistAndOpensItsInspector() = assertToolbar(landscape = false)

    @Test(timeout = 120_000) fun landscapeBarTogglesAPictureAssistAndOpensItsInspector() = assertToolbar(landscape = true)

    @Test(timeout = 120_000) fun tallPhotoInPortraitZoomsPastItsLetterbox() = assertZoom(landscape = false)

    @Test(timeout = 120_000) fun tallPhotoInLandscapeZoomsPastItsPillarbox() = assertZoom(landscape = true)

    @Test(timeout = 120_000) fun withoutAStillLookThePictureAssistsAreNotOffered() {
        val fixture = Fixture(landscape = false, look = false)
        fixture.launch { scenario ->
            fixture.await("the still is drawn") { red(capture(scenario).pixel(fixture.center())) }
            val expand = fixture.awaitNode("the shared bar is shown") { it.contentDescription?.toString() == "Show view assists" }
            press(expand, long = false)
            fixture.awaitNode("the open bar offers the geometry tools") {
                it.contentDescription?.toString()?.startsWith("Guides,") == true
            }
            assertTrue(findNode { it.contentDescription?.toString()?.startsWith("Peaking,") == true } == null)
        }
    }

    private fun assertToolbar(landscape: Boolean) {
        val fixture = Fixture(landscape)
        fixture.launch { scenario ->
            val orientation = if (landscape) "landscape" else "portrait"
            fixture.await("the still is drawn") { red(capture(scenario).pixel(fixture.center())) }
            assertFalse(fixture.assist.isPlaybackVisible(MonitorAssistTool.PEAK))
            val peak = fixture.awaitNode("the bar offers peaking") { it.contentDescription?.toString() == "Peaking, off" }
            press(peak, long = false)
            fixture.await("peaking turns on for stills and clips") { fixture.assist.isPlaybackVisible(MonitorAssistTool.PEAK) }
            fixture.await("the page shows the still through its look") { green(capture(scenario).pixel(fixture.center())) }
            val on = fixture.awaitNode("the chip reads on") { it.contentDescription?.toString() == "Peaking, on" }
            press(on, long = true)
            fixture.awaitNode("the shared inspector opens on peaking") {
                it.isVisibleToUser && it.contentDescription?.toString() == "Close ${MonitorAssistTool.PEAK.chipLabel}"
            }
            assertTrue(fixture.assist.configureTool == MonitorAssistTool.PEAK)
            evidence("photo-toolbar-$orientation")
        }
    }

    private fun assertZoom(landscape: Boolean) {
        val fixture = Fixture(landscape)
        fixture.launch { scenario ->
            val orientation = if (landscape) "landscape" else "portrait"
            fixture.await("the still is drawn") { red(capture(scenario).pixel(fixture.center())) }
            val feed = fixture.feed()
            val outside = fixture.letterbox(feed)
            assertTrue("At 1x the letterbox beside the frame shows the canvas", dark(capture(scenario).pixel(outside)))
            val span = min(feed.width(), feed.height())
            pinch(fixture.screen(fixture.center()), span * .25f, span * .75f)
            fixture.await("the zoomed still covers the letterbox beside its frame") {
                reddish(capture(scenario).pixel(outside))
            }
            evidence("photo-zoom-$orientation")
        }
    }

    private class Fixture(private val landscape: Boolean, private val look: Boolean = true) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val root = Files.createTempDirectory("SIMULATED-photo-assist-").toFile()
        val record = MonitorMediaRecord(
            MediaAsset(MediaAssetID("SIMULATED-tall"), filename = "SIMULATED-tall.jpg",
                kind = MediaAssetKind.PHOTO, representations = emptyList()),
            "tall-payload", MonitorMediaCacheAddress("tall-thumb", emptyMap(), "tall-cache"))
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
            MonitorMediaCache(MonitorMediaCacheDirectory(root).also { it.write("SIMULATED".toByteArray(), "index.json") },
                codec, MonitorMediaOriginalEligibility.ExactSize, "index.json", listOf("index.json")),
            favorites, scope = scope, cacheScanning = MonitorMediaCacheScanning.IMMEDIATE, initialRecords = listOf(record))
        val assist = MonitorAssistState()
        val still: Bitmap = Bitmap.createBitmap(900, 1600, Bitmap.Config.ARGB_8888).also { bitmap ->
            Canvas(bitmap).apply {
                drawColor(android.graphics.Color.WHITE)
                drawRect(12f, 12f, 888f, 1588f, Paint().apply { color = android.graphics.Color.RED })
            }
        }
        @Volatile var canvasOrigin = Offset.Zero
        @Volatile var canvasWidth = 0f
        @Volatile var canvasHeight = 0f
        @Volatile var windowOrigin = Offset.Zero

        init { library.begin(); library.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS) }

        fun launch(body: (ActivityScenario<GalleryOpeningTestActivity>) -> Unit) {
            ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
                scenario.moveToState(Lifecycle.State.RESUMED)
                val wanted = if (landscape) Configuration.ORIENTATION_LANDSCAPE else Configuration.ORIENTATION_PORTRAIT
                scenario.onActivity {
                    it.requestedOrientation = if (landscape) ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                        else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                }
                await("the test window turns ${if (landscape) "landscape" else "portrait"}") {
                    var turned = false
                    scenario.onActivity { turned = it.resources.configuration.orientation == wanted && it.hasWindowFocus() }
                    turned
                }
                scenario.onActivity { activity ->
                    val location = IntArray(2)
                    activity.window.decorView.getLocationOnScreen(location)
                    windowOrigin = Offset(location[0].toFloat(), location[1].toFloat())
                    activity.setContent {
                        Box(Modifier.fillMaxSize().onGloballyPositioned {
                            canvasOrigin = it.positionInWindow()
                            canvasWidth = it.size.width.toFloat(); canvasHeight = it.size.height.toFloat()
                        }) {
                            MonitorOperatorPhotoScreen(library, record, assist,
                                MonitorMediaPictureLoaders<String, Bitmap>(cached = { still }),
                                MonitorMediaGalleryOperations(), close = {},
                                stillLook = if (look) MonitorStillLook { picture, plan ->
                                    if (!plan.peaking) null else Bitmap.createBitmap(picture.width, picture.height,
                                        Bitmap.Config.ARGB_8888).also { it.eraseColor(android.graphics.Color.GREEN) }
                                } else null)
                        }
                    }
                }
                try { body(scenario) } finally { scope.cancel(); root.deleteRecursively() }
            }
        }

        /** The still's 1x frame in window pixels: the tall still fitted in the page. */
        fun feed(): android.graphics.RectF {
            val aspect = still.width.toFloat() / still.height
            val width = min(canvasWidth, canvasHeight * aspect); val height = width / aspect
            val left = canvasOrigin.x + (canvasWidth - width) / 2f; val top = canvasOrigin.y + (canvasHeight - height) / 2f
            return android.graphics.RectF(left, top, left + width, top + height)
        }

        fun center(): Offset = feed().let { Offset(it.centerX(), it.centerY()) }

        /** Beside the frame on its letterboxed side, clear of the header, bar and rating. */
        fun letterbox(feed: android.graphics.RectF): Offset = if (feed.left - canvasOrigin.x > 1f) {
            Offset(feed.right + (canvasOrigin.x + canvasWidth - feed.right) / 2f, feed.centerY())
        } else {
            Offset(feed.left + feed.width() * .75f, feed.top - min(feed.top - canvasOrigin.y, 60f) / 2f)
        }

        fun screen(point: Offset): Offset = point + windowOrigin

        fun await(what: String, condition: () -> Boolean): Boolean {
            val deadline = SystemClock.uptimeMillis() + 15_000
            while (SystemClock.uptimeMillis() < deadline) {
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                if (condition()) return true
                SystemClock.sleep(32)
            }
            assertTrue("Timed out waiting until $what", condition())
            return true
        }

        fun awaitNode(what: String, matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
            var node: AccessibilityNodeInfo? = null
            val deadline = SystemClock.uptimeMillis() + 15_000
            while (node == null && SystemClock.uptimeMillis() < deadline) {
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                node = findNode(matches)
                if (node == null) SystemClock.sleep(32)
            }
            val seen = mutableListOf<String>()
            if (node == null) findNode { info ->
                (info.contentDescription ?: info.text)?.let { seen += it.toString() }; false
            }
            val windows = InstrumentationRegistry.getInstrumentation().uiAutomation.windows.map { "${it.type}:${it.title}:${it.root != null}" }
            assertTrue("Timed out waiting until $what; the window shows $seen in $windows", node != null)
            return checkNotNull(node)
        }
    }

    private class Window(private val bitmap: Bitmap) {
        fun pixel(point: Offset): Int = bitmap.getPixel(
            point.x.roundToInt().coerceIn(0, bitmap.width - 1), point.y.roundToInt().coerceIn(0, bitmap.height - 1))
    }

    private fun channels(color: Int) =
        Triple(android.graphics.Color.red(color), android.graphics.Color.green(color), android.graphics.Color.blue(color))

    private fun red(color: Int) = channels(color).let { (r, g, b) -> r > 200 && g < 60 && b < 60 }

    /** Red under the page's darkening scrim. */
    private fun reddish(color: Int) = channels(color).let { (r, g, b) -> r > 90 && r > g + 60 && r > b + 60 }

    private fun green(color: Int) = channels(color).let { (r, g, b) -> g > 200 && r < 60 && b < 60 }

    private fun dark(color: Int) = channels(color).let { (r, g, b) -> r < 60 && g < 60 && b < 60 }

    /** The activity window: the page's own pixels. */
    private fun capture(scenario: ActivityScenario<GalleryOpeningTestActivity>): Window {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        val latch = CountDownLatch(1)
        var image: Bitmap? = null
        var status = -1
        scenario.onActivity { activity ->
            val decor = activity.window.decorView
            val bitmap = Bitmap.createBitmap(decor.width, decor.height, Bitmap.Config.ARGB_8888)
            image = bitmap
            // Test-only window readback of actual HWUI output. Production never copies the picture.
            PixelCopy.request(activity.window, bitmap, { result -> status = result; latch.countDown() },
                Handler(Looper.getMainLooper()))
        }
        assertTrue("window capture timed out", latch.await(5, TimeUnit.SECONDS))
        assertTrue(status == PixelCopy.SUCCESS)
        return Window(checkNotNull(image))
    }

    /** The whole screen once two captures in a row agree (no rotation, zoom or panel animation in flight). */
    private fun evidence(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.uptimeMillis() + 8_000
        var previous: Bitmap? = null
        var shot = instrumentation.uiAutomation.takeScreenshot() ?: return
        while (SystemClock.uptimeMillis() < deadline && previous?.sameAs(shot) != true) {
            SystemClock.sleep(150)
            previous = shot
            shot = instrumentation.uiAutomation.takeScreenshot() ?: return
        }
        File(instrumentation.targetContext.getExternalFilesDir(null), "$name.png").outputStream().use {
            shot.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    private var lastEventTime = 0L

    private fun nextEventTime(): Long {
        val now = SystemClock.uptimeMillis()
        lastEventTime = if (now > lastEventTime) now else lastEventTime + 1L
        return lastEventTime
    }

    /** A finger on the node's centre: a tap, or held past the long-press timeout. */
    private fun press(node: AccessibilityNodeInfo, long: Boolean) {
        val bounds = android.graphics.Rect().also(node::getBoundsInScreen)
        val point = Offset(bounds.exactCenterX(), bounds.exactCenterY())
        if (!long && node.isClickable && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return
        if (long && node.isLongClickable && node.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)) return
        val down = nextEventTime()
        inject(MotionEvent.ACTION_DOWN, listOf(point), down)
        if (long) SystemClock.sleep(android.view.ViewConfiguration.getLongPressTimeout() + 300L)
        // A tap that toggles the bar re-lays its plate; the outcome, not the injection, is checked.
        inject(MotionEvent.ACTION_UP, listOf(point), down, required = false)
    }

    /** Two fingers on a horizontal line through [center], spreading from [fromSpan] to [toSpan]. */
    private fun pinch(center: Offset, fromSpan: Float, toSpan: Float, steps: Int = 16) {
        fun pair(span: Float) = listOf(center - Offset(span / 2f, 0f), center + Offset(span / 2f, 0f))
        val down = nextEventTime()
        inject(MotionEvent.ACTION_DOWN, pair(fromSpan).take(1), down)
        inject(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), pair(fromSpan), down)
        for (step in 1..steps) inject(MotionEvent.ACTION_MOVE, pair(fromSpan + (toSpan - fromSpan) * step / steps), down)
        inject(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), pair(toSpan), down)
        inject(MotionEvent.ACTION_UP, pair(toSpan).take(1), down)
    }

    private fun inject(action: Int, points: List<Offset>, down: Long, required: Boolean = true) {
        val properties = Array(points.size) { index ->
            MotionEvent.PointerProperties().apply { id = index; toolType = MotionEvent.TOOL_TYPE_FINGER }
        }
        val coords = Array(points.size) { index ->
            MotionEvent.PointerCoords().apply { x = points[index].x; y = points[index].y; pressure = 1f; size = 1f }
        }
        val event = MotionEvent.obtain(down, if (action == MotionEvent.ACTION_DOWN) down else nextEventTime(),
            action, points.size, properties, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
        try {
            val injected = InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(event, true)
            assertTrue("injectInputEvent $action", injected || !required)
        } finally { event.recycle() }
    }
}

private fun findNode(matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
    val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
    val pending = ArrayDeque<AccessibilityNodeInfo>()
    // The assist bar's plate is its own popup window, beside the page's.
    automation.serviceInfo = automation.serviceInfo.apply {
        flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
    }
    automation.windows.mapNotNull { it.root }.forEach(pending::add)
    automation.rootInActiveWindow?.let(pending::add)
    var walked = 0
    while (pending.isNotEmpty() && walked++ < 8_000) {
        val node = pending.removeFirst()
        if (matches(node)) return node
        for (i in 0 until node.childCount) node.getChild(i)?.let(pending::add)
    }
    return null
}
