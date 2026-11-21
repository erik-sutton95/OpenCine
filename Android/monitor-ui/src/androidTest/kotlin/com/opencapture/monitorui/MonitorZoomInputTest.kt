package com.opencapture.monitorui

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.round
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Native pointer delivery into the production zoom popup window.
 * Activity decor dispatch cannot reach a focusable Popup; UiAutomation must inject.
 */
@RunWith(AndroidJUnit4::class)
class MonitorZoomInputTest {
    @Test fun rulerDragStepsInTenthsWhilePopupOwnsPointer() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            val probe = ZoomNativeProbe()
            scenario.moveToState(Lifecycle.State.RESUMED)
            scenario.onActivity { activity ->
                activity.setContent {
                    val density = LocalDensity.current
                    probe.density = density.density
                    probe.touchSlop = LocalViewConfiguration.current.touchSlop
                    probe.composed = true
                    Box(Modifier.fillMaxSize().pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) {
                                val event = awaitPointerEvent(PointerEventPass.Initial)
                                probe.underEvents.addAndGet(event.changes.size)
                                if (event.changes.any { it.pressed && !it.previousPressed }) {
                                    probe.underDowns.incrementAndGet()
                                }
                            }
                        }
                    }.clickable { probe.underClicks.incrementAndGet() }) {
                        Text("underlying zoom control")
                        MonitorZoomRuler(
                            initial = 2.0,
                            maximum = 4.0,
                            onChange = { probe.changes.add(it) },
                            onDismiss = { probe.dismissals++ },
                            clearance = MonitorZoomClearance(top = 80f, bottom = 80f),
                            onStep = { probe.steps.incrementAndGet() },
                        )
                    }
                }
            }
            awaitPopup(scenario, probe)
            val ruler = checkNotNull(findZoomBounds())
            val inset = MonitorZoomRulerMetrics.INSET * probe.density
            val x = ruler.right - MonitorZoomRulerMetrics.WIDTH * probe.density / 2f
            // The scale's bottom end is the minimum, its middle half way to the maximum.
            val bottom = Offset(x, ruler.bottom - inset)
            val middle = Offset(x, ruler.exactCenterY())
            play(listOf(bottom, middle), probe.touchSlop, lift = true)
            settle()
            val after = snapshot(probe)
            assertTrue(after.values.isNotEmpty(), "Dragging the ruler must change zoom")
            assertEquals(1.0, after.values.first(), 1e-9, "Touching the bottom selects the minimum: ${after.values}")
            assertEquals(2.5, after.values.last(), 1e-9, "The middle of a 1x to 4x ruler is 2.5x: ${after.values}")
            after.values.forEach { value ->
                assertEquals(value, round(value * 10.0) / 10.0, 1e-9, "Every sent value is a tenth: ${after.values}")
            }
            after.values.zipWithNext().forEach { (a, b) ->
                assertTrue(a != b, "A value is sent once per step: ${after.values}")
            }
            assertEquals(after.values.size, probe.steps.get(), "One step tick per new value")
            assertEquals(0, after.downs, "Popup must own the ruler pointer")
            assertEquals(0, after.events)
            assertEquals(0, after.clicks)
            scenario.onActivity { assertEquals(0, probe.dismissals, "A drag on the ruler keeps it open") }
        }
    }

    private fun awaitPopup(scenario: ActivityScenario<MonitorTestActivity>, probe: ZoomNativeProbe) {
        val deadline = SystemClock.uptimeMillis() + 8_000
        var stable = 0
        var last = android.graphics.Rect()
        while (SystemClock.uptimeMillis() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            val laidOut = probe.composed && probe.density > 0f
            val bounds = findZoomBounds()
            if (laidOut && bounds != null && bounds.width() > 0 && bounds.height() > 0) {
                if (bounds == last) stable++ else { stable = 0; last = android.graphics.Rect(bounds) }
                if (stable >= 3) {
                    SystemClock.sleep(MonitorMotion.ZOOM_IN_MS.toLong() + 40L)
                    InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                    return
                }
            }
            scenario.onActivity { activity ->
                if (!activity.hasWindowFocus()) activity.window.decorView.requestFocus()
            }
            SystemClock.sleep(32)
        }
        assertTrue(probe.composed, "Fixture must compose")
        assertTrue(findZoomBounds() != null, "Zoom popup semantics never published")
        assertTrue(stable >= 3, "Zoom popup bounds must settle")
    }

    private fun findZoomBounds(): android.graphics.Rect? {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        fun search(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
            if (node == null) return null
            if (node.actionList.any { it.label?.toString() == "Close zoom" }) return node
            for (index in 0 until node.childCount) {
                search(node.getChild(index))?.let { return it }
            }
            return null
        }
        val roots = mutableListOf<AccessibilityNodeInfo>()
        automation.rootInActiveWindow?.let(roots::add)
        automation.windows.orEmpty().mapNotNull(AccessibilityWindowInfo::getRoot).forEach(roots::add)
        for (root in roots) {
            val found = search(root) ?: continue
            val bounds = android.graphics.Rect()
            found.getBoundsInScreen(bounds)
            if (bounds.width() > 0 && bounds.height() > 0) return bounds
        }
        return null
    }

    private var lastEventTime = 0L

    private fun nextEventTime(): Long {
        val now = SystemClock.uptimeMillis()
        val time = if (now > lastEventTime) now else lastEventTime + 1L
        lastEventTime = time
        return time
    }

    private fun play(points: List<Offset>, touchSlop: Float, lift: Boolean, downTime: Long? = null): Long {
        val path = interpolate(points, max(8f, touchSlop / 2f))
        val down = downTime ?: nextEventTime()
        var index = 0
        if (downTime == null) {
            inject(MotionEvent.ACTION_DOWN, path.first(), down, down)
            index = 1
        }
        for (sample in index until path.size) {
            inject(MotionEvent.ACTION_MOVE, path[sample], down, nextEventTime())
        }
        if (lift) lift(path.last(), down)
        return down
    }

    private fun lift(point: Offset, down: Long) {
        inject(MotionEvent.ACTION_UP, point, down, nextEventTime())
    }

    private fun interpolate(points: List<Offset>, step: Float): List<Offset> {
        require(points.size >= 2)
        val out = mutableListOf(points.first())
        for (index in 1 until points.size) {
            val from = out.last()
            val to = points[index]
            val distance = hypot((to.x - from.x).toDouble(), (to.y - from.y).toDouble()).toFloat()
            val count = max(1, (distance / step).toInt())
            for (sample in 1..count) {
                val t = sample / count.toFloat()
                out += Offset(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t)
            }
        }
        return out
    }

    private fun inject(action: Int, point: Offset, down: Long, eventTime: Long) {
        val properties = arrayOf(MotionEvent.PointerProperties().apply {
            id = 0
            toolType = MotionEvent.TOOL_TYPE_FINGER
        })
        val coords = arrayOf(MotionEvent.PointerCoords().apply {
            x = point.x
            y = point.y
            pressure = 1f
            size = 1f
        })
        val event = MotionEvent.obtain(down, eventTime, action, 1, properties, coords,
            0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
        try {
            assertTrue(
                InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(event, true),
                "injectInputEvent $action at ${point.x},${point.y}",
            )
        } finally { event.recycle() }
    }

    private fun snapshot(probe: ZoomNativeProbe) = ZoomSnapshot(
        values = probe.changes.toList(),
        downs = probe.underDowns.get(),
        events = probe.underEvents.get(),
        clicks = probe.underClicks.get(),
    )

    private fun settle() {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        SystemClock.sleep(48)
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }
}

private class ZoomNativeProbe {
    var density = 0f
    var touchSlop = 18f
    val changes = Collections.synchronizedList(mutableListOf<Double>())
    val steps = AtomicInteger()
    val underEvents = AtomicInteger()
    val underDowns = AtomicInteger()
    val underClicks = AtomicInteger()
    var dismissals = 0
    var composed = false
}

private data class ZoomSnapshot(
    val values: List<Double>,
    val downs: Int,
    val events: Int,
    val clicks: Int,
)
