package com.opencapture.monitorui

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.PixelCopy
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.media.MonitorConformPreview
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Owner request 2026-10-28: a zoomed clip fills the playback area instead of staying cropped to its
 * letterboxed 16:9 or 9:16 frame. A real two-finger pinch enters the actual shared playback screen;
 * the SIMULATED picture is red with a white frame edge and applies the published zoom the way the
 * apps' pictures do. Window pixels say what covers the letterbox. Swift twins:
 * MonitorPlaybackZoomRenderingTests (pixels) and MonitorPlaybackPageGeometryTests (bounds).
 * Each run also saves the full screen, chrome included, as `playback-zoom-*.png` evidence.
 */
@RunWith(AndroidJUnit4::class)
class MonitorPlaybackZoomBeyondFrameTest {
    @Test(timeout = 90_000) fun wideClipInPortraitZoomsPastItsLetterbox() = assertZoom("16x9", 16f / 9f, landscape = false)

    @Test(timeout = 90_000) fun wideClipInLandscapeZoomsPastItsPillarbox() = assertZoom("16x9", 16f / 9f, landscape = true)

    @Test(timeout = 90_000) fun tallClipInPortraitZoomsPastItsLetterbox() = assertZoom("9x16", 9f / 16f, landscape = false)

    @Test(timeout = 90_000) fun tallClipInLandscapeZoomsPastItsPillarbox() = assertZoom("9x16", 9f / 16f, landscape = true)

    @Test(timeout = 90_000) fun oneTimesLetterboxIgnoresTapsAndZoomedLetterboxPans() {
        val fixture = Fixture(16f / 9f)
        fixture.launch {
            val fitted = fixture.awaitGeometry().feed
            val outside = fixture.letterbox(fitted)
            tap(fixture.screen(outside))
            tap(fixture.screen(Offset(fitted.x + fitted.width / 2f, fitted.y + fitted.height / 2f)))
            fixture.await("the frame tap reaches the player") { fixture.plays.get() == 1 }
            assertEquals(1, fixture.plays.get(), "At 1x a tap in the letterbox stays outside the picture")

            pinch(fixture.screen(Offset(fitted.x + fitted.width / 2f, fitted.y + fitted.height / 2f)),
                fitted.width * .3f, fitted.width * .6f)
            fixture.await("the pinch zooms the picture") { (fixture.geometry?.zoom?.scale ?: 1f) > 1.8f }
            val before = checkNotNull(fixture.geometry).zoom
            drag(fixture.screen(outside), fixture.screen(outside + Offset(-fitted.width * .2f, 0f)))
            fixture.await("a drag that starts in the letterbox pans the zoomed picture") {
                fixture.geometry?.zoom?.offsetX != before.offsetX
            }
            assertNotEquals(before.offsetX, checkNotNull(fixture.geometry).zoom.offsetX)
        }
    }

    private fun assertZoom(name: String, aspect: Float, landscape: Boolean) {
        val fixture = Fixture(aspect, landscape)
        fixture.launch { scenario ->
            val fitted = fixture.awaitGeometry().feed
            val orientation = if (fixture.canvasWidth > fixture.canvasHeight) "landscape" else "portrait"
            val inside = Offset(fitted.x + fitted.width * .3f, fitted.y + fitted.height * .3f)
            val outside = fixture.letterbox(fitted)
            fixture.await("the picture is drawn") { red(capture(scenario).pixel(inside)) }
            val one = capture(scenario)
            evidence("playback-zoom-$name-$orientation-1x", fixture.screen(inside))

            pinch(fixture.screen(Offset(fitted.x + fitted.width / 2f, fitted.y + fitted.height / 2f)),
                min(fitted.width, fitted.height) * .3f, min(fitted.width, fitted.height) * .6f)
            fixture.await("the pinch zooms the picture") { (fixture.geometry?.zoom?.scale ?: 1f) > 1.8f }
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            evidence("playback-zoom-$name-$orientation-2x", fixture.screen(inside))
            val zoomed = capture(scenario)

            assertTrue(dark(one.pixel(outside)), "At 1x the letterbox beside the frame shows the canvas")
            assertTrue(red(zoomed.pixel(outside)),
                "At ${checkNotNull(fixture.geometry).zoom.scale}x the picture covers the letterbox beside its frame")
        }
    }

    /** One SIMULATED clip on the actual shared playback screen in a full-screen test window. */
    private class Fixture(private val aspect: Float, private val landscape: Boolean = false) {
        val plays = AtomicInteger()
        @Volatile var geometry: MonitorPlaybackPictureGeometry? = null
        @Volatile var origin = Offset.Zero
        val canvasWidth get() = checkNotNull(geometry).canvasWidth
        val canvasHeight get() = checkNotNull(geometry).canvasHeight

        fun launch(body: (ActivityScenario<MonitorTestActivity>) -> Unit) {
            ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                scenario.moveToState(Lifecycle.State.RESUMED)
                val wanted = if (landscape) Configuration.ORIENTATION_LANDSCAPE else Configuration.ORIENTATION_PORTRAIT
                scenario.onActivity { activity ->
                    activity.requestedOrientation = if (landscape) ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                        else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                }
                var turned = false
                await("the test window turns ${if (landscape) "landscape" else "portrait"}") {
                    scenario.onActivity { turned = it.resources.configuration.orientation == wanted && it.hasWindowFocus() }
                    turned
                }
                scenario.onActivity { activity ->
                    activity.setContent {
                        val view = LocalView.current
                        val screen = IntArray(2)
                        view.getLocationOnScreen(screen)
                        origin = Offset(screen[0].toFloat(), screen[1].toFloat())
                        MonitorPlaybackScreen(presentation(), actions(), MonitorPlaybackPageSlots(),
                            picture = { published ->
                                geometry = published
                                Box(Modifier.fillMaxSize().graphicsLayer {
                                    scaleX = published.zoom.scale; scaleY = published.zoom.scale
                                    translationX = published.zoom.offsetX; translationY = published.zoom.offsetY
                                }.background(Color.Red).border(3.dp, Color.White))
                            }, feedAssists = {}, canvasAssists = {}, tools = {}, assistInspector = {})
                    }
                }
                body(scenario)
            }
        }

        fun awaitGeometry(): MonitorPlaybackPictureGeometry {
            await("the playback picture publishes its geometry") { geometry != null }
            return checkNotNull(geometry)
        }

        /** Just outside the frame on its letterboxed side, a quarter of the narrower band away. */
        fun letterbox(feed: MonitorRect): Offset = if (feed.y > 1f) {
            Offset(feed.x + feed.width * .3f, feed.y - min(feed.y, feed.height) / 4f)
        } else {
            Offset(feed.x - min(feed.x, feed.width) / 4f, feed.y + feed.height * .3f)
        }

        fun screen(point: Offset): Offset = point + origin

        fun await(what: String, condition: () -> Boolean) {
            val deadline = SystemClock.uptimeMillis() + 10_000
            while (SystemClock.uptimeMillis() < deadline) {
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                if (condition()) return
                SystemClock.sleep(16)
            }
            assertTrue(condition(), "Timed out waiting until $what")
        }

        private fun presentation() = MonitorPlaybackPresentation(
            item = MonitorPlaybackItemToken(UUID.randomUUID(), 1), title = "SIMULATED ZOOM.MOV",
            subtitle = "", source = null, metadata = emptyList(), aspect = aspect, ready = true, error = null,
            progress = null, position = 1f, duration = 10f, positionLabel = "0:01", durationLabel = "0:10",
            playing = false, reachedEnd = false, scrubbing = false, muted = false, looping = false,
            previous = false, next = false, favorite = false, conform = MonitorConformPreview.Source(),
            conformTarget = null, loopAvailable = false, shareEnabled = false)

        private fun actions() = MonitorPlaybackActions(
            back = {}, play = { _, _ -> plays.incrementAndGet() }, restart = {}, seekBy = { _, _ -> },
            mute = { _, _ -> }, loop = { _, _ -> }, conform = { _, _ -> }, adjacent = { _, _ -> },
            favorite = {}, share = {}, delete = null, beginScrub = { null }, updateScrub = { _, _ -> },
            updateFrameScrub = { _, _, _ -> }, commitScrub = {}, cancelScrub = { _, _ -> })
    }

    private class Window(private val bitmap: Bitmap) {
        fun pixel(point: Offset): Int = bitmap.getPixel(
            point.x.roundToInt().coerceIn(0, bitmap.width - 1), point.y.roundToInt().coerceIn(0, bitmap.height - 1))
    }

    private fun red(color: Int) =
        android.graphics.Color.red(color) > 200 && android.graphics.Color.green(color) < 60 &&
            android.graphics.Color.blue(color) < 60

    private fun dark(color: Int) =
        android.graphics.Color.red(color) < 60 && android.graphics.Color.green(color) < 60 &&
            android.graphics.Color.blue(color) < 60

    /** The activity window only: the picture without the chrome popup above it. */
    private fun capture(scenario: ActivityScenario<MonitorTestActivity>): Window {
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
        assertTrue(latch.await(5, TimeUnit.SECONDS), "window capture timed out")
        assertEquals(PixelCopy.SUCCESS, status)
        return Window(checkNotNull(image))
    }

    /**
     * The whole screen, chrome included, for the owner's review, once the display shows [picture]
     * and two captures in a row agree (no rotation or zoom animation in flight).
     */
    private fun evidence(name: String, picture: Offset) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.uptimeMillis() + 8_000
        var previous: Bitmap? = null
        var shot = instrumentation.uiAutomation.takeScreenshot() ?: return
        while (SystemClock.uptimeMillis() < deadline &&
            !(red(Window(shot).pixel(picture)) && previous?.sameAs(shot) == true)) {
            SystemClock.sleep(100)
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

    private fun tap(point: Offset) {
        val down = nextEventTime()
        inject(MotionEvent.ACTION_DOWN, listOf(point), down)
        inject(MotionEvent.ACTION_UP, listOf(point), down)
    }

    private fun drag(from: Offset, to: Offset, steps: Int = 12) {
        val down = nextEventTime()
        inject(MotionEvent.ACTION_DOWN, listOf(from), down)
        for (step in 1..steps) inject(MotionEvent.ACTION_MOVE, listOf(from + (to - from) * (step / steps.toFloat())), down)
        inject(MotionEvent.ACTION_UP, listOf(to), down)
    }

    /** Two fingers on a horizontal line through [center], spreading from [fromSpan] to [toSpan]. */
    private fun pinch(center: Offset, fromSpan: Float, toSpan: Float, steps: Int = 16) {
        fun pair(span: Float) = listOf(center - Offset(span / 2f, 0f), center + Offset(span / 2f, 0f))
        val down = nextEventTime()
        inject(MotionEvent.ACTION_DOWN, pair(fromSpan).take(1), down)
        inject(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), pair(fromSpan), down)
        for (step in 1..steps) {
            inject(MotionEvent.ACTION_MOVE, pair(fromSpan + (toSpan - fromSpan) * step / steps), down)
        }
        inject(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), pair(toSpan), down)
        inject(MotionEvent.ACTION_UP, pair(toSpan).take(1), down)
    }

    private fun inject(action: Int, points: List<Offset>, down: Long) {
        val properties = Array(points.size) { index ->
            MotionEvent.PointerProperties().apply { id = index; toolType = MotionEvent.TOOL_TYPE_FINGER }
        }
        val coords = Array(points.size) { index ->
            MotionEvent.PointerCoords().apply { x = points[index].x; y = points[index].y; pressure = 1f; size = 1f }
        }
        val event = MotionEvent.obtain(down, if (action == MotionEvent.ACTION_DOWN) down else nextEventTime(),
            action, points.size, properties, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
        try {
            assertTrue(InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(event, true),
                "injectInputEvent $action")
        } finally { event.recycle() }
    }
}
