package com.opencapture.monitorui

import android.os.SystemClock
import android.view.MotionEvent
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredHeight
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.staggeredgrid.rememberLazyStaggeredGridState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The media grid's staggered (masonry) placement through the production grid, card and selection
 * host: each card goes into the shortest column in display order, a column stacks its cards with
 * no row gaps, a loading thumbnail never moves a card, and a drag follows the staggered frames.
 */
@RunWith(AndroidJUnit4::class)
class MonitorCatalogMasonryTest {
    private val portrait = 2.0 / 3.0
    private val landscape = 16.0 / 9.0

    @Test fun eachCardGoesIntoTheShortestColumnAndColumnsStackWithoutGaps() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            val probe = Probe()
            setGrid(scenario, probe, listOf(portrait, landscape, landscape, landscape))
            scenario.onActivity {
                val (a, b, c, d) = listOf("0", "1", "2", "3").map(probe.bounds::getValue)
                // The tall portrait holds the left column; the short cards stack on the right.
                assertTrue(a.left < b.left)
                assertEquals(b.left, c.left, 1f)
                assertEquals(b.left, d.left, 1f)
                val spacing = 8 * it.resources.displayMetrics.density
                assertEquals(b.bottom + spacing, c.top, 2f)
                assertEquals(c.bottom + spacing, d.top, 2f)
                assertTrue(a.height > b.height * 1.5f, "a portrait card is taller than a clip card")
                // Uniform rows would have pushed the second short card under the portrait.
                assertTrue(c.top < a.bottom)
            }
        }
    }

    @Test fun aLoadingThumbnailNeverMovesACard() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            val probe = Probe()
            setGrid(scenario, probe, listOf(landscape, portrait, null, landscape))
            val before = scenario.withActivity { probe.bounds.toMap() }
            // Thumbnails arrive with their own (wrong) intrinsic shapes.
            scenario.onActivity { probe.loaded.value = true }
            repeat(4) { settle() }
            scenario.onActivity {
                before.forEach { (id, rect) ->
                    val after = probe.bounds.getValue(id)
                    assertTrue(abs(after.top - rect.top) < 1f && abs(after.height - rect.height) < 1f,
                        "card $id moved: $rect -> $after")
                }
            }
        }
    }

    @Test fun aHoldDragAcrossStaggeredCardsSelectsTheDisplayedRange() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            val probe = Probe()
            setGrid(scenario, probe, listOf(portrait, landscape, landscape, landscape))
            val origin = scenario.withActivity { probe.bounds.getValue("0").center }
            // The third card of the other column, beside the tall portrait.
            val target = scenario.withActivity { probe.bounds.getValue("2").center }
            val down = SystemClock.uptimeMillis()
            event(scenario, MotionEvent.ACTION_DOWN, origin, down)
            SystemClock.sleep(400)
            settle()
            event(scenario, MotionEvent.ACTION_MOVE, target, down)
            settle()
            event(scenario, MotionEvent.ACTION_UP, target, down)
            settle()
            scenario.onActivity {
                assertTrue(probe.selecting)
                assertEquals(setOf("0", "1", "2"), probe.selected)
                assertTrue(probe.opened.isEmpty())
            }
        }
    }

    private fun setGrid(scenario: ActivityScenario<MonitorTestActivity>, probe: Probe, aspects: List<Double?>) {
        val ids = aspects.indices.map { it.toString() }
        scenario.onActivity { activity ->
            activity.setContent {
                val state = rememberLazyStaggeredGridState()
                var selecting by remember { mutableStateOf(false) }
                var selected by remember { mutableStateOf(setOf<String>()) }
                val loaded by probe.loaded
                Box(Modifier.width(360.dp).fillMaxSize().background(MonitorPalette.background)) {
                    MonitorMediaSelectionHost(
                        ids = ids, selecting = selecting, selected = selected, scroll = state,
                        onOpen = { probe.opened = probe.opened + it },
                        onSelectionChange = { nextSelecting, nextIds ->
                            selecting = nextSelecting
                            selected = nextIds
                            probe.selecting = nextSelecting
                            probe.selected = nextIds
                        },
                        modifier = Modifier.fillMaxSize(),
                        sessionKey = "fixture/grid/medium/newest",
                    ) { registry ->
                        MonitorCatalogGrid(ids, columns = 2, key = { it }, modifier = Modifier.fillMaxSize(),
                            state = state) { id ->
                            MonitorMediaHitTarget(registry, id,
                                Modifier.onGloballyPositioned { probe.bounds[id] = it.boundsInWindow() }) {
                                MonitorClipCard(
                                    MonitorClipValue(id, "Clip-$id", "4K", null, "ON PHONE", false),
                                    list = false, selecting = selecting, selected = id in selected,
                                    onOpen = { probe.opened = probe.opened + id }, onSelect = {},
                                    clicks = false, artworkAspect = MonitorMediaMasonry.aspect(aspects[id.toInt()]),
                                ) {
                                    if (loaded) Box(Modifier.requiredHeight(900.dp).width(40.dp).background(Color.Red))
                                }
                            }
                        }
                    }
                }
            }
        }
        repeat(8) { settle() }
        scenario.onActivity { assertEquals(ids.toSet(), probe.bounds.keys) }
    }

    private fun <T> ActivityScenario<MonitorTestActivity>.withActivity(read: () -> T): T {
        var value: T? = null
        onActivity { value = read() }
        @Suppress("UNCHECKED_CAST") return value as T
    }

    private fun event(scenario: ActivityScenario<MonitorTestActivity>, action: Int, point: Offset, down: Long) {
        scenario.onActivity { activity ->
            val decor = activity.window.decorView
            val location = IntArray(2)
            decor.getLocationInWindow(location)
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                point.x - location[0], point.y - location[1], 0)
            event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            try { decor.dispatchTouchEvent(event) } finally { event.recycle() }
        }
    }

    private fun settle() {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        SystemClock.sleep(32)
    }

    private class Probe {
        var selecting = false
        var selected = emptySet<String>()
        var opened = emptyList<String>()
        val loaded = mutableStateOf(false)
        val bounds = mutableMapOf<String, Rect>()
    }
}
