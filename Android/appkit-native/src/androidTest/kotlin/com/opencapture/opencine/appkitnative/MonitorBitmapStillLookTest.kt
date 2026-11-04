package com.opencapture.opencine.appkitnative

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.os.Build
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.geometry.Offset
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.cameracontrols.MonitorOperatorPhotoScreen
import com.opencapture.opencine.media.*
import java.io.File
import java.nio.file.Files
import kotlin.math.abs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The still viewer's picture assists on the phone's own AGSL chain (owner findings 2026-10-31).
 * A SIMULATED still with one sharp edge goes through the real [MonitorBitmapStillLook] with the
 * plan the shared photo page builds; the rendered pixels say where peaking painted. The tour hosts
 * the real shared photo page over a SIMULATED landscape still and saves the owner's review shots
 * (`photo-<toolbar|inspector|zoom>-<orientation>.png` in the app's external files).
 */
@RunWith(AndroidJUnit4::class)
class MonitorBitmapStillLookTest {
    @Test fun peakingPaintsTheSharpEdgeOfAStillAndLeavesItsFlatFieldAlone() {
        assumeTrue("AGSL needs API 33", Build.VERSION.SDK_INT >= 33)
        val still = Bitmap.createBitmap(400, 300, Bitmap.Config.ARGB_8888).also { bitmap ->
            Canvas(bitmap).apply {
                drawColor(android.graphics.Color.rgb(30, 30, 30))
                drawRect(200f, 0f, 400f, 300f, Paint().apply { color = android.graphics.Color.rgb(220, 220, 220) })
            }
        }
        val assist = MonitorAssistState().apply { togglePlayback(MonitorAssistTool.PEAK) }
        val plan = assist.renderPlan(MonitorTransfer.REC709, playback = true, isPhoto = true)
        val plain = assist.apply { togglePlayback(MonitorAssistTool.PEAK) }
            .renderPlan(MonitorTransfer.REC709, playback = true, isPhoto = true)
        val look = MonitorBitmapStillLook()
        val painted = assertNotNull(look.render(still, plan))
        val untouched = assertNotNull(look.render(still, plain))
        assertEquals(still.width, painted.width)
        val (r, g, b) = plan.peakingColor.map { (it * 255).toInt() }
        fun near(color: Int) = abs(android.graphics.Color.red(color) - r) < 60 &&
            abs(android.graphics.Color.green(color) - g) < 60 && abs(android.graphics.Color.blue(color) - b) < 60
        assertTrue((196..204).any { x -> near(painted.getPixel(x, 150)) }, "Peaking paints the in-focus edge")
        assertEquals(untouched.getPixel(60, 150), painted.getPixel(60, 150), "The flat field keeps its own pixels")
        assertTrue((196..204).none { x -> near(untouched.getPixel(x, 150)) }, "Without peaking the edge is the still's")
    }

    @Test(timeout = 180_000) fun reviewTourPortrait() = tour(landscape = false)

    @Test(timeout = 180_000) fun reviewTourLandscape() = tour(landscape = true)

    private fun tour(landscape: Boolean) {
        assumeTrue("AGSL needs API 33", Build.VERSION.SDK_INT >= 33)
        val orientation = if (landscape) "landscape" else "portrait"
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val root = Files.createTempDirectory("SIMULATED-still-tour-").toFile()
        val record = MonitorMediaRecord(
            MediaAsset(MediaAssetID("SIMULATED-vertical"), filename = "SIMULATED-vertical.jpg",
                kind = MediaAssetKind.PHOTO, representations = emptyList()),
            "vertical", MonitorMediaCacheAddress("vertical-thumb", emptyMap(), "vertical-cache"))
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
        library.begin(); library.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS)
        val assist = MonitorAssistState()
        val still = verticalStill()
        try {
            ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
                scenario.moveToState(Lifecycle.State.RESUMED)
                val wanted = if (landscape) Configuration.ORIENTATION_LANDSCAPE else Configuration.ORIENTATION_PORTRAIT
                scenario.onActivity {
                    it.requestedOrientation = if (landscape) ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                        else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                }
                await { var turned = false; scenario.onActivity { turned = it.resources.configuration.orientation == wanted && it.hasWindowFocus() }; turned }
                scenario.onActivity { activity ->
                    activity.setContent {
                        MonitorOperatorPhotoScreen(library, record, assist, MonitorMediaPictureLoaders<String, Bitmap>(cached = { still }),
                            MonitorMediaGalleryOperations(), close = {}, stillLook = MonitorBitmapStillLook())
                    }
                }
                await { node { it.contentDescription?.toString()?.startsWith("Photo preview for") == true } != null }
                scenario.onActivity { assist.togglePlayback(MonitorAssistTool.PEAK); assist.togglePlayback(MonitorAssistTool.GRID) }
                node { it.contentDescription?.toString() == "Show view assists" }?.let { tap(it) }
                await { node { it.contentDescription?.toString()?.startsWith("Guides,") == true } != null }
                evidence("photo-toolbar-$orientation")
                scenario.onActivity { assist.configureTool = MonitorAssistTool.PEAK }
                await { node { it.contentDescription?.toString() == "Close PEAK" } != null }
                evidence("photo-inspector-$orientation")
                scenario.onActivity { assist.configureTool = null; assist.togglePlayback(MonitorAssistTool.GRID) }
                await { node { it.contentDescription?.toString() == "Close PEAK" } == null }
                var center = Offset.Zero
                scenario.onActivity { val decor = it.window.decorView; val at = IntArray(2); decor.getLocationOnScreen(at)
                    center = Offset(at[0] + decor.width / 2f, at[1] + decor.height / 2f) }
                pinch(center, 160f, 640f)
                SystemClock.sleep(600)
                evidence("photo-zoom-$orientation")
            }
        } finally { scope.cancel(); root.deleteRecursively() }
    }

    /** A SIMULATED 9:16 still: sky, sun, a dark tower with sharp edges and fine lines, and ground. */
    private fun verticalStill(): Bitmap = Bitmap.createBitmap(1080, 1920, Bitmap.Config.ARGB_8888).also { bitmap ->
        Canvas(bitmap).apply {
            drawRect(0f, 0f, 1080f, 1300f, Paint().apply {
                shader = LinearGradient(0f, 0f, 0f, 1300f, android.graphics.Color.rgb(40, 90, 170),
                    android.graphics.Color.rgb(235, 170, 120), Shader.TileMode.CLAMP)
            })
            drawCircle(760f, 520f, 120f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.rgb(255, 250, 235) })
            drawRect(0f, 1300f, 1080f, 1920f, Paint().apply {
                shader = LinearGradient(0f, 1300f, 0f, 1920f, android.graphics.Color.rgb(60, 70, 40),
                    android.graphics.Color.rgb(20, 24, 16), Shader.TileMode.CLAMP)
            })
            val tower = Paint().apply { color = android.graphics.Color.rgb(28, 30, 36) }
            drawRect(300f, 620f, 520f, 1500f, tower)
            drawRect(360f, 520f, 460f, 620f, tower)
            val window = Paint().apply { color = android.graphics.Color.rgb(250, 210, 120) }
            for (row in 0 until 8) for (column in 0 until 3)
                drawRect(320f + column * 66f, 660f + row * 100f, 360f + column * 66f, 710f + row * 100f, window)
            val line = Paint().apply { color = android.graphics.Color.WHITE; strokeWidth = 3f }
            for (i in 0 until 12) drawLine(600f + i * 30f, 1360f, 600f + i * 30f, 1800f, line)
        }
    }

    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 15_000
        while (SystemClock.uptimeMillis() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            if (condition()) return
            SystemClock.sleep(50)
        }
        assertTrue(condition(), "timed out")
    }

    private fun node(matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        val pending = ArrayDeque<AccessibilityNodeInfo>()
        automation.windows.mapNotNull { it.root }.forEach(pending::add)
        automation.rootInActiveWindow?.let(pending::add)
        var walked = 0
        while (pending.isNotEmpty() && walked++ < 8_000) {
            val next = pending.removeFirst()
            if (matches(next)) return next
            for (i in 0 until next.childCount) next.getChild(i)?.let(pending::add)
        }
        return null
    }

    private fun evidence(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.uptimeMillis() + 8_000
        var previous: Bitmap? = null
        var shot = instrumentation.uiAutomation.takeScreenshot() ?: return
        while (SystemClock.uptimeMillis() < deadline && previous?.sameAs(shot) != true) {
            SystemClock.sleep(200)
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

    private fun tap(node: AccessibilityNodeInfo) {
        val bounds = android.graphics.Rect().also(node::getBoundsInScreen)
        val point = Offset(bounds.exactCenterX(), bounds.exactCenterY())
        val down = nextEventTime()
        inject(MotionEvent.ACTION_DOWN, listOf(point), down)
        inject(MotionEvent.ACTION_UP, listOf(point), down)
    }

    private fun pinch(center: Offset, fromSpan: Float, toSpan: Float, steps: Int = 16) {
        fun pair(span: Float) = listOf(center - Offset(span / 2f, 0f), center + Offset(span / 2f, 0f))
        val down = nextEventTime()
        inject(MotionEvent.ACTION_DOWN, pair(fromSpan).take(1), down)
        inject(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), pair(fromSpan), down)
        for (step in 1..steps) inject(MotionEvent.ACTION_MOVE, pair(fromSpan + (toSpan - fromSpan) * step / steps), down)
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
        try { InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(event, true) }
        finally { event.recycle() }
    }
}
