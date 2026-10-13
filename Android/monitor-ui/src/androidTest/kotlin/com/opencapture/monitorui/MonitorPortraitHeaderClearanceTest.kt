package com.opencapture.monitorui

import android.view.View
import android.view.ViewGroup
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED values through the production native shared header, never a geometry-only oracle. */
@RunWith(AndroidJUnit4::class)
class MonitorPortraitHeaderClearanceTest {
    @Test(timeout = 90_000) fun nativeTextShrinksWithinBoundsThenEllipsizesWithoutLosingItsValue() {
        val short = "123 GB"
        val long = "123456789 GB · 100%"
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            val placed = CountDownLatch(5)
            scenario.onActivity { activity ->
                activity.setContent {
                    Column {
                        MonitorBoundedReadoutText(short, Modifier.width(200.dp).onGloballyPositioned { placed.countDown() })
                        MonitorBoundedReadoutText(long, Modifier.width(120.dp).onGloballyPositioned { placed.countDown() })
                        MonitorBoundedReadoutText(long, Modifier.width(50.dp).onGloballyPositioned { placed.countDown() })
                        MonitorBoundedReadoutText(long, Modifier.width(400.dp).onGloballyPositioned { placed.countDown() }, maximumSize = 11f, minimumSize = 11f)
                        MonitorBoundedReadoutText(long, Modifier.width(400.dp).onGloballyPositioned { placed.countDown() }, maximumSize = 14f, minimumSize = 14f)
                    }
                }
            }
            assertTrue("Actual native text must lay out", placed.await(5, TimeUnit.SECONDS))
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            scenario.onActivity { activity ->
                val nodes = nativeNodes(activity.window.decorView).filter {
                    it.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action != null
                }
                assertEquals(5, nodes.size)
                val results = nodes.map { node ->
                    val result = mutableListOf<TextLayoutResult>()
                    assertTrue(node.config[SemanticsActions.GetTextLayoutResult].action!!.invoke(result))
                    result.single()
                }
                // Compose's accessibility layout input rewrites the requested style. The retained
                // native paragraph supplies actual glyph metrics, compared with native 11/14sp controls.
                val glyphWidths = results.map { it.getBoundingBox(0).width }
                val minimum = glyphWidths[3]; val maximum = glyphWidths[4]
                android.util.Log.i("B5NativeText", results.mapIndexed { index, result ->
                    "glyph=${glyphWidths[index]} width=${result.size.width} ellipsis=${result.isLineEllipsized(0)} text=${result.layoutInput.text}"
                }.joinToString())
                assertEquals(maximum, glyphWidths[0], .05f)
                assertTrue("Long storage must shrink before overflow", glyphWidths[1] < maximum - .05f)
                results.take(3).forEachIndexed { index, result ->
                    assertTrue("Readable native font bounds", glyphWidths[index] >= minimum - .05f && glyphWidths[index] <= maximum + .05f)
                    assertEquals(1, result.lineCount)
                }
                assertEquals(minimum, glyphWidths[2], .05f)
                assertTrue("Overflow after the lower bound must be ellipsized", results[2].isLineEllipsized(0))
                assertEquals(listOf(short, long, long, long, long), nodes.map { it.config[SemanticsProperties.Text].single().text })
            }
        }
    }

    @Test(timeout = 90_000) fun groupedFormatAndCodecRetainNativeActionsAndMissingDetailStaysAbsent() {
        for (detailPresent in listOf(true, false)) {
            ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                val placed = CountDownLatch(if (detailPresent) 2 else 1)
                var primaryCalls = 0; var detailCalls = 0
                var primaryFrame = Rect.Zero; var detailFrame = Rect.Zero
                scenario.onActivity { activity ->
                    activity.setContent {
                        MonitorPortraitFormatGroup(detailPresent, primary = {
                            Box(Modifier.height(48.dp).onGloballyPositioned { primaryFrame = it.boundsInRoot(); placed.countDown() }
                                .monitorChromeClickable { primaryCalls++ }.semantics { contentDescription = "Format" },
                                contentAlignment = Alignment.BottomEnd) {
                                MonitorBoundedReadoutText("[FX] 6K · 25p", maximumSize = 23f, minimumSize = 16f)
                            }
                        }, detail = {
                            Box(Modifier.height(48.dp).onGloballyPositioned { detailFrame = it.boundsInRoot(); placed.countDown() }
                                .monitorChromeClickable { detailCalls++ }.semantics { contentDescription = "Codec" },
                                contentAlignment = Alignment.TopEnd) {
                                MonitorBoundedReadoutText("R3D NE", maximumSize = 11f, minimumSize = 11f)
                            }
                        })
                    }
                }
                assertTrue("Actual native grouped targets must lay out", placed.await(5, TimeUnit.SECONDS))
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                scenario.onActivity { activity ->
                    val nodes = nativeNodes(activity.window.decorView)
                    val format = nodes.single { it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Format" }
                    val codec = nodes.singleOrNull { it.config.getOrNull(SemanticsProperties.ContentDescription)?.singleOrNull() == "Codec" }
                    assertTrue(nodes.any { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "[FX] 6K · 25p" })
                    assertTrue(format.config[SemanticsActions.OnClick].action!!.invoke())
                    assertEquals(1, primaryCalls); assertEquals(0, detailCalls)
                    if (detailPresent) {
                        requireNotNull(codec)
                        val density = activity.resources.displayMetrics.density
                        android.util.Log.i("B5NativeGroup", "drawn=$primaryFrame/$detailFrame AX=${format.boundsInRoot}/${codec.boundsInRoot}")
                        assertTrue("Detail below primary with separate target: $primaryFrame $detailFrame", detailFrame.top >= primaryFrame.bottom + 1.5f * density)
                        assertEquals("One trailing drawn column", primaryFrame.right, detailFrame.right, .5f * density)
                        assertTrue(nodes.any { it.config.getOrNull(SemanticsProperties.Text)?.singleOrNull()?.text == "R3D NE" })
                        assertTrue(codec.config[SemanticsActions.OnClick].action!!.invoke())
                        assertEquals(1, primaryCalls); assertEquals(1, detailCalls)
                    } else assertEquals(null, codec)
                }
            }
        }
    }

    @Test(timeout = 90_000) fun storageAndPerformanceStayBelowTheCutoutAndBeforePower() {
        for (width in listOf(320f, 360f, 440f)) {
            ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                val placed = CountDownLatch(3)
                var storage = Rect.Zero; var performance = Rect.Zero; var power = Rect.Zero
                var density = 1f
                var canvas = Rect.Zero
                val field = MonitorLayoutPolicy.fieldMonitor(width, 700f, safeTop = 59f, safeLeading = 20f, safeTrailing = 20f)
                scenario.onActivity { activity ->
                    density = activity.resources.displayMetrics.density
                    activity.setContent {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                        Box(Modifier.requiredSize(width.dp, 700.dp).onGloballyPositioned { canvas = it.boundsInRoot() }, contentAlignment = Alignment.TopStart) {
                            MonitorStatusChrome(field, MonitorStatusPresentation(false, timecode = "01:23:45:59"),
                                modifier = Modifier.offset(field.status.x.dp, field.status.y.dp).width(field.status.width.dp),
                                storage = { MonitorBoundedReadoutText("123456789 GB · 100%",
                                    modifier = Modifier.onGloballyPositioned { storage = it.boundsInRoot(); placed.countDown() }) },
                                format = { Text("[FX] 6K · 25p") },
                                link = { MonitorTelemetry(4, "25", emptyList(), true, showsPower = false,
                                    modifier = Modifier.onGloballyPositioned { performance = it.boundsInRoot(); placed.countDown() }) })
                            MonitorTelemetry(null, null, listOf(MonitorTelemetryPower(false, 100), MonitorTelemetryPower(true, null, bars = 5)),
                                true, showsLink = false,
                                modifier = Modifier.offset(field.telemetry.x.dp, field.telemetry.y.dp)
                                    .onGloballyPositioned { power = it.boundsInRoot(); placed.countDown() })
                        }
                        }
                    }
                }
                assertTrue("Actual native layout callbacks required", placed.await(5, TimeUnit.SECONDS))
                val top = canvas.top + 67f * density
                assertTrue("Storage enters safe top: $storage", storage.top >= top - 1)
                assertTrue("Performance enters safe top: $performance", performance.top >= top - 1)
                assertTrue("Power enters safe top: $power", power.top >= top - 1)
                assertTrue("Storage must not push performance into power: $storage $performance $power",
                    storage.right + 8 * density <= performance.left + 1 && performance.right + 8 * density <= power.left + 1)
            }
        }
    }

    private fun nativeNodes(view: View): List<SemanticsNode> {
        if (view is RootForTest) {
            fun walk(node: SemanticsNode): List<SemanticsNode> = listOf(node) + node.children.flatMap(::walk)
            return walk(view.semanticsOwner.unmergedRootSemanticsNode)
        }
        return if (view is ViewGroup) (0 until view.childCount).flatMap { nativeNodes(view.getChildAt(it)) } else emptyList()
    }
}
